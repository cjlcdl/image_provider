"""
文件夹管理路由模块 v3.0
======================
处理虚拟文件夹的 CRUD、压缩下载、下载链接等请求：
  - GET    /api/folders              列出所有文件夹
  - POST   /api/folders              创建文件夹
  - PATCH  /api/folders              更新文件夹
  - DELETE /api/folders              删除文件夹（级联）
  - POST   /api/folders/archive      下载文件夹压缩包
  - POST   /api/folders/download-link  生成受保护下载链接
"""

import mimetypes
import tempfile
import zipfile
from http import HTTPStatus
from pathlib import PurePosixPath
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from config import PERMANENT_TOKEN_HEADER
from server_auth import check_folder_password_token, verify_folder_password, verify_management_token
from server_database import get_db
from server_models import Folder
from server_storage import (
    build_file_response,
    build_folder_response,
    collect_descendant_folder_ids,
    create_download_token_record,
    create_folder_record,
    delete_folder_cascade,
    get_disk_capacity,
    get_folder_record,
    list_all_folders,
    list_files_query,
    update_folder_record,
    write_audit_log,
)
from server_utils import (
    APP_CHANNEL_HEADER,
    USER_HEADER,
    FOLDER_PASSWORD_TOKEN_HEADER,
    FOLDER_PASSWORDS_TOKEN_HEADER,
    TARGET_FOLDER_PASSWORD_TOKEN_HEADER,
    DOWNLOAD_TOKEN_QUERY_PARAM,
    build_content_disposition,
    extract_extension,
    file_chunk_generator,
    normalize_folder_id,
    sanitize_index_name,
)

router = APIRouter(tags=["文件夹管理"])


# ===================================================================
# GET /api/folders — 列出所有文件夹
# ===================================================================

@router.get("/api/folders")
async def handle_list_folders(
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """列出所有虚拟文件夹（需要管理令牌）"""
    await verify_management_token(db, courage_token)

    folders = await list_all_folders(db)
    folder_map = {f.id: f for f in folders}
    from server_storage import get_folder_visibility_chain
    vis_cache: dict = {}
    folder_list = []
    for f in folders:
        fid = f.id
        if fid not in vis_cache:
            vis_cache[fid] = await get_folder_visibility_chain(db, fid) or "public"
        folder_list.append(build_folder_response(f, folder_map, effective_visibility=vis_cache[fid]))

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "ok",
            "data": {
                "folders": folder_list,
                **get_disk_capacity(),
            },
        },
    )


# ===================================================================
# POST /api/folders — 创建文件夹
# ===================================================================

@router.post("/api/folders")
async def handle_create_folder(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    target_folder_password_token: str = Header("", alias=TARGET_FOLDER_PASSWORD_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """创建虚拟文件夹

    请求体：
    {
      "name": "文件夹名",
      "parentId": "父文件夹ID（可选）",
      "visibility": "public|private|encrypted（默认 public）",
      "password": "加密密码（visibility=encrypted时必填）"
    }
    """
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    name = body.get("name")
    parent_id = normalize_folder_id(body.get("parentId"))
    visibility_value = body.get("visibility")
    if visibility_value not in ("public", "private", "encrypted", None):
        raise HTTPException(status_code=400, detail="invalid visibility")
    if visibility_value is None:
        # 兼容旧版的 encrypted + allowDirectDownload
        encrypted = body.get("encrypted") is True
        visibility_value = "encrypted" if encrypted else "public"
    password = body.get("password") if isinstance(body.get("password"), str) else None

    if not isinstance(name, str) or sanitize_index_name(name) is None:
        raise HTTPException(status_code=400, detail="invalid folder name")

    # 检查父目录访问权限
    if parent_id:
        parent = await get_folder_record(db, parent_id)
        if parent is None:
            raise HTTPException(status_code=404, detail="folder not found")
        if parent.encrypted or parent.visibility == "encrypted":
            await check_folder_password_token(db, parent_id, target_folder_password_token)

    try:
        record = await create_folder_record(
            db=db,
            name=name,
            parent_id=parent_id or None,
            visibility=visibility_value,
            password=password,
        )
    except PermissionError:
        raise HTTPException(status_code=400, detail="missing folder password")
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid folder name")

    folders = await list_all_folders(db)
    folder_map = {f.id: f for f in folders}
    response_data = build_folder_response(record, folder_map)

    await write_audit_log(
        db=db,
        action_type="create_folder",
        indexed_name=name,
        file_path=response_data["path"],
        client_ip=request.client.host if request.client else "",
        extra={
            "resourceType": "folder",
            "folderId": record.id,
            "parentId": record.parent_id,
            "visibility": visibility_value,
        },
    )

    return JSONResponse(
        status_code=200,
        content={"code": 0, "message": "folder created", "data": response_data},
    )


# ===================================================================
# PATCH /api/folders — 更新文件夹
# ===================================================================

@router.patch("/api/folders")
async def handle_update_folder(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    folder_password_token: str = Header("", alias=FOLDER_PASSWORD_TOKEN_HEADER),
    target_folder_password_token: str = Header("", alias=TARGET_FOLDER_PASSWORD_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """更新文件夹属性（名称、父目录、加密状态、密码等）"""
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    folder_id = normalize_folder_id(body.get("folderId"))
    if not folder_id:
        raise HTTPException(status_code=400, detail="missing folder id")

    # 获取当前记录（用于审计对比）
    current = await get_folder_record(db, folder_id)
    if current is None:
        raise HTTPException(status_code=404, detail="folder not found")

    # 加密文件夹需要密码证明
    if current.encrypted:
        await check_folder_password_token(db, folder_id, folder_password_token)

    name = body.get("name") if isinstance(body.get("name"), str) else None
    parent_provided = "parentId" in body
    parent_id = normalize_folder_id(body.get("parentId")) if parent_provided else None
    encrypted_provided = isinstance(body.get("encrypted"), bool)
    encrypted = body.get("encrypted") if encrypted_provided else None
    allow_direct = body.get("allowDirectDownload") if isinstance(body.get("allowDirectDownload"), bool) else None
    new_password = body.get("newPassword") if isinstance(body.get("newPassword"), str) else None

    # 检查目标父目录访问权限
    if parent_provided and parent_id:
        target_parent = await get_folder_record(db, parent_id)
        if target_parent is None:
            raise HTTPException(status_code=404, detail="folder not found")
        if target_parent.encrypted:
            await check_folder_password_token(db, parent_id, target_folder_password_token)

    try:
        record = await update_folder_record(
            db=db,
            folder_id=folder_id,
            name=name,
            parent_id=parent_id,
            parent_id_provided=parent_provided,
            encrypted=encrypted,
            allow_direct_download=allow_direct,
            password=new_password,
        )
    except PermissionError:
        raise HTTPException(status_code=400, detail="missing folder password")
    except ValueError as e:
        msg = str(e)
        if "invalid target parent" in msg:
            raise HTTPException(status_code=400, detail="invalid target parent")
        if "not encrypted" in msg:
            raise HTTPException(status_code=400, detail="folder is not encrypted")
        raise HTTPException(status_code=400, detail="invalid folder name")
    except KeyError:
        raise HTTPException(status_code=404, detail="folder not found")

    if record is None:
        raise HTTPException(status_code=404, detail="folder not found")

    folders = await list_all_folders(db)
    folder_map = {f.id: f for f in folders}
    response_data = build_folder_response(record, folder_map)

    await write_audit_log(
        db=db,
        action_type="update_folder",
        indexed_name=record.name,
        file_path=response_data["path"],
        client_ip=request.client.host if request.client else "",
        extra={
            "resourceType": "folder",
            "folderId": record.id,
            "oldName": current.name,
            "newName": record.name,
            "passwordChanged": bool(new_password),
        },
    )

    return JSONResponse(
        status_code=200,
        content={"code": 0, "message": "folder updated", "data": response_data},
    )


# ===================================================================
# DELETE /api/folders — 删除文件夹（级联）
# ===================================================================

@router.delete("/api/folders")
async def handle_delete_folder(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    folder_password_token: str = Header("", alias=FOLDER_PASSWORD_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """删除文件夹（级联删除子文件夹，文件移回根目录）

    请求方式：folderId=xxx  或  请求体 {"folderId": "xxx"}
    """
    await verify_management_token(db, courage_token)

    # 获取 folderId
    folder_id = normalize_folder_id(request.query_params.get("folderId"))
    if not folder_id:
        try:
            body = await request.json()
        except Exception:
            body = None
        if isinstance(body, dict):
            folder_id = normalize_folder_id(body.get("folderId"))
    if not folder_id:
        raise HTTPException(status_code=400, detail="missing folder id")

    folder_record = await get_folder_record(db, folder_id)
    if folder_record is None:
        raise HTTPException(status_code=404, detail="folder not found")

    # 加密文件夹需要密码
    if folder_record.encrypted:
        await check_folder_password_token(db, folder_id, folder_password_token)

    # 收集将删除的文件夹（用于日志）
    descendant_ids = await collect_descendant_folder_ids(db, folder_id)
    all_ids = [folder_id] + descendant_ids
    folders_map_before = {}
    for fid in all_ids:
        rec = await get_folder_record(db, fid)
        if rec:
            folders_map_before[fid] = rec

    # 执行级联删除
    removed_ids = await delete_folder_cascade(db, folder_id)

    await write_audit_log(
        db=db,
        action_type="delete_folder",
        indexed_name=folder_record.name,
        client_ip=request.client.host if request.client else "",
        extra={
            "resourceType": "folder",
            "folderId": folder_id,
            "deletedFolderCount": len(removed_ids),
            "cascade": True,
        },
    )

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "folder deleted",
            "data": {
                "folderId": folder_id,
                "deletedFolderCount": len(removed_ids),
                "deletedFolders": removed_ids,
            },
        },
    )


# ===================================================================
# POST /api/folders/download-link — 生成受保护下载链接
# ===================================================================

@router.post("/api/folders/download-link")
async def handle_create_download_link(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    folder_password_token: str = Header("", alias=FOLDER_PASSWORD_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """为加密文件夹中不允许直接下载的文件生成临时下载链接

    请求体：{"path": "/p/xxx", "expiresInDays": 7}
    """
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    file_path = body.get("path")
    expires_days = body.get("expiresInDays")

    if not isinstance(file_path, str) or not file_path:
        raise HTTPException(status_code=400, detail="missing file path")

    if isinstance(expires_days, str) and expires_days.isdigit():
        expires_days = int(expires_days)
    if not isinstance(expires_days, int) or expires_days <= 0:
        raise HTTPException(status_code=400, detail="invalid download link days")

    # 查找文件
    from server_storage import get_file_by_url
    record = await get_file_by_url(db, file_path)
    if record is None:
        raise HTTPException(status_code=404, detail="file not found")

    # 检查文件夹权限
    folder_id = record.folder_id
    if folder_id:
        folder_rec = await get_folder_record(db, folder_id)
        if folder_rec and folder_rec.encrypted and not folder_rec.allow_direct_download:
            # 需要密码令牌
            await check_folder_password_token(db, folder_id, folder_password_token)

            # 生成下载令牌
            token_record = await create_download_token_record(
                db=db,
                file_path=file_path,
                folder_id=folder_id,
                expires_days=expires_days,
            )
            url = f"{file_path}?{DOWNLOAD_TOKEN_QUERY_PARAM}={token_record.token}"
            return JSONResponse(
                status_code=200,
                content={
                    "code": 0,
                    "message": "download link created",
                    "data": {
                        "path": file_path,
                        "url": url,
                        "expiresAt": token_record.expires_at.isoformat(),
                        "expiresInDays": expires_days,
                        "passwordExempt": False,
                    },
                },
            )

    # 无需密码的文件直接返回原链接
    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "download link created",
            "data": {
                "path": file_path,
                "url": file_path,
                "expiresAt": None,
                "expiresInDays": None,
                "passwordExempt": True,
            },
        },
    )


# ===================================================================
# POST /api/folders/archive — 下载文件夹压缩包
# ===================================================================

@router.post("/api/folders/archive")
async def handle_download_folder_archive(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    folder_passwords_token: str = Header("", alias=FOLDER_PASSWORDS_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """将文件夹及其所有内容打包为 ZIP 下载

    请求体：{"folderId": "xxx"}
    加密文件夹需要 Folder-Passwords-Token 提供密码
    """
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    folder_id = normalize_folder_id(body.get("folderId"))
    if not folder_id:
        raise HTTPException(status_code=400, detail="missing folder id")

    folder_record = await get_folder_record(db, folder_id)
    if folder_record is None:
        raise HTTPException(status_code=404, detail="folder not found")

    # 收集所有后代文件夹
    descendant_ids = await collect_descendant_folder_ids(db, folder_id)
    related_ids = [folder_id] + descendant_ids

    # 检查加密文件夹密码
    encrypted_ids = []
    for fid in related_ids:
        rec = await get_folder_record(db, fid)
        if rec and rec.encrypted:
            encrypted_ids.append(fid)

    if encrypted_ids:
        from server_auth import validate_rsa_token_async
        token_value = folder_passwords_token.strip()
        if not token_value:
            raise HTTPException(status_code=401, detail="missing folder passwords token")

        is_valid, payload, code, message = await validate_rsa_token_async(db, token_value)
        if not is_valid:
            status = 401
            if code == 40302:
                status = 403
            raise HTTPException(status_code=status, detail=message)

        if payload is None:
            raise HTTPException(status_code=401, detail="invalid folder passwords token")

        raw_folders = payload.get("folders")
        if not isinstance(raw_folders, list):
            raise HTTPException(status_code=401, detail="invalid folder passwords token")

        provided = {}
        for item in raw_folders:
            if isinstance(item, dict):
                fid = item.get("folderId")
                pw = item.get("password")
                if isinstance(fid, str) and isinstance(pw, str):
                    provided[fid] = pw

        for fid in encrypted_ids:
            rec = await get_folder_record(db, fid)
            pw = provided.get(fid)
            if not pw or not verify_folder_password(rec, pw):
                raise HTTPException(status_code=403, detail="invalid folder password")

    # 构建文件夹路径映射
    def _build_folder_path(fid: str, all_folders: dict) -> str:
        """构建文件夹在 ZIP 中的相对路径"""
        names = []
        current = fid
        seen = set()
        while current and current != folder_id:
            if current in seen:
                break
            seen.add(current)
            f = all_folders.get(current)
            if f is None:
                break
            names.append(f.name)
            current = f.parent_id
        names.reverse()
        root_name = all_folders.get(folder_id)
        root_part = root_name.name if root_name else "archive"
        return str(PurePosixPath(root_part, *names))

    all_folders_map = {}
    for fid in related_ids:
        rec = await get_folder_record(db, fid)
        if rec:
            all_folders_map[fid] = rec

    folder_paths = {fid: _build_folder_path(fid, all_folders_map) for fid in related_ids}

    # 获取文件夹内所有文件
    all_files = []
    for fid in related_ids:
        files, _ = await list_files_query(db, folder_id=fid, page_size=10000)
        for f in files:
            all_files.append((f, folder_paths.get(fid, "archive")))

    # 创建 ZIP 文件
    archive_name = f"{sanitize_index_name(folder_record.name) or 'archive'}.zip"
    import os

    # 使用临时文件
    temp_fd, temp_path = tempfile.mkstemp(suffix=".zip")
    os.close(temp_fd)

    try:
        used_paths = set()
        with zipfile.ZipFile(temp_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            # 创建文件夹条目
            for fid in related_ids:
                fp = folder_paths.get(fid, "")
                if fp:
                    zf.writestr(f"{fp}/", "")

            # 添加文件
            for file_record, folder_path in all_files:
                from server_utils import build_cas_path
                target_path, _ = build_cas_path(file_record.sha256, file_record.extension)
                if not target_path.exists():
                    continue

                # 构建唯一文件名（处理重名）
                file_name = sanitize_index_name(file_record.indexed_name) or file_record.system_name
                archive_path = str(PurePosixPath(folder_path, file_name))

                # 处理重名
                counter = 1
                base = archive_path
                while archive_path in used_paths:
                    stem = PurePosixPath(base).stem
                    ext = PurePosixPath(base).suffix
                    archive_path = str(PurePosixPath(folder_path, f"{stem} ({counter}){ext}"))
                    counter += 1
                used_paths.add(archive_path)

                zf.write(str(target_path), archive_path)

        # 流式返回 ZIP
        def zip_generator():
            chunk_size = 64 * 1024
            with open(temp_path, "rb") as f:
                while chunk := f.read(chunk_size):
                    yield chunk
            # 发送完成后清理临时文件
            try:
                os.unlink(temp_path)
            except OSError:
                pass

        content_disposition = build_content_disposition("attachment", archive_name)

        await write_audit_log(
            db=db,
            action_type="download_folder_archive",
            indexed_name=folder_record.name,
            client_ip=request.client.host if request.client else "",
            extra={"folderId": folder_id, "fileCount": len(all_files)},
        )

        return StreamingResponse(
            zip_generator(),
            media_type="application/zip",
            headers={
                "Content-Disposition": content_disposition,
                "X-Content-Type-Options": "nosniff",
            },
        )

    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise HTTPException(status_code=500, detail="failed to create archive")
