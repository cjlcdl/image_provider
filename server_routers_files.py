"""
文件管理路由模块 v3.0
====================
处理文件列表、下载、重命名、删除、移动等请求：
  - GET    /api/files              文件列表（分页、筛选）
  - GET    /p/{base64url}          文件访问/下载（支持 Range）
  - PATCH  /api/files              重命名文件
  - DELETE /api/files              删除文件（单个/批量，软删除）
  - POST   /api/files/move         切换临时/永久存储
  - POST   /api/files/folder       调整文件所属文件夹
"""

import mimetypes
from http import HTTPStatus
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse, StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from config import PERMANENT_TOKEN_HEADER
from server_auth import verify_management_token
from server_database import get_db
from server_storage import (
    build_file_response,
    get_file_by_id,
    get_file_by_url,
    is_rate_limited,
    list_files_query,
    move_file_storage,
    permanent_delete_file,
    record_file_access,
    rename_file,
    restore_file,
    set_file_folder,
    soft_delete_file,
    write_audit_log,
)
from server_utils import (
    APP_CHANNEL_HEADER,
    USER_HEADER,
    DOWNLOAD_TOKEN_QUERY_PARAM,
    FOLDER_PASSWORD_TOKEN_HEADER,
    build_cas_path,
    build_content_disposition,
    extract_extension,
    get_file_url,
    is_inline_mime_type,
    normalize_folder_id,
    now_utc,
    parse_file_url,
    sanitize_index_name,
)

router = APIRouter(tags=["文件管理"])


# ===================================================================
# GET /api/files — 文件列表
# ===================================================================

@router.get("/api/files")
async def handle_list_files(
    request: Request,
    storage: Optional[str] = Query(None),
    keyword: Optional[str] = Query(None),
    mimeType: Optional[str] = Query(None),
    extension: Optional[str] = Query(None),
    folderId: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    pageSize: int = Query(50, ge=1, le=200),
    includeDeleted: bool = Query(False),
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    folder_password_token: str = Header("", alias=FOLDER_PASSWORD_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """分页查询文件列表（需要管理令牌）

    支持按 storage、keyword、mimeType、extension、folderId 筛选。
    folderId=root 表示查看根目录文件。
    """
    # 验证管理令牌
    await verify_management_token(db, courage_token)

    # 验证 storage 参数
    if storage and storage not in ("temporary", "permanent"):
        raise HTTPException(status_code=400, detail="invalid storage filter")

    # 验证并检查文件夹访问权限
    normalized_folder = None
    if folderId is not None:
        if folderId.lower() == "root":
            normalized_folder = ""  # 空字符串 = 根目录
        else:
            normalized_folder = normalize_folder_id(folderId)
            if not normalized_folder:
                raise HTTPException(status_code=400, detail="missing folder id")
            # 检查加密文件夹访问
            from server_models import Folder
            from sqlalchemy import select
            result = await db.execute(select(Folder).where(Folder.id == normalized_folder))
            folder_record = result.scalar_one_or_none()
            if folder_record is None:
                raise HTTPException(status_code=404, detail="folder not found")
            if folder_record.encrypted:
                from server_auth import check_folder_password_token
                await check_folder_password_token(db, normalized_folder, folder_password_token)

    # 查询
    files, total = await list_files_query(
        db,
        storage_filter=storage,
        keyword=keyword,
        mime_type=mimeType,
        extension=extension,
        folder_id=normalized_folder,
        page=page,
        page_size=pageSize,
        include_deleted=includeDeleted,
    )

    total_pages = (total + pageSize - 1) // pageSize if total else 0
    file_responses = [build_file_response(f) for f in files]

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "ok",
            "data": {
                "total": total,
                "page": page,
                "pageSize": pageSize,
                "returned": len(file_responses),
                "totalPages": total_pages,
                "filters": {
                    "storage": storage,
                    "keyword": keyword,
                    "mimeType": mimeType,
                    "extension": extension.lower().lstrip(".") if extension else None,
                    "folderId": normalized_folder,
                },
                "files": file_responses,
            },
        },
    )


# ===================================================================
# GET /p/{base64url} — 文件访问/下载（支持 Range 请求）
# ===================================================================

@router.api_route("/p/{path:path}", methods=["GET", "HEAD"])
async def serve_file(
    request: Request,
    path: str,
    downloadToken: Optional[str] = Query(None, alias=DOWNLOAD_TOKEN_QUERY_PARAM),
    db: AsyncSession = Depends(get_db),
):
    """访问/下载文件（支持 HTTP Range 请求用于断点续传和视频拖动）

    URL 格式：/p/{base64url(systemName)}
    根据 MIME 类型自动判断浏览器内预览（inline）或强制下载（attachment）。
    加密文件夹中不允许直接下载的文件需要 downloadToken 参数。
    """
    client_ip = request.client.host if request.client else "unknown"
    # 下载端点频率限制（按客户端 IP，防止带宽滥用）
    if is_rate_limited(f"dl:{client_ip}"):
        raise HTTPException(status_code=429, detail="too many download requests")

    full_path = f"/p/{path}"
    system_name = parse_file_url(full_path)
    if system_name is None:
        raise HTTPException(status_code=404, detail="file not found")

    # 查询文件
    record = await get_file_by_url(db, full_path)
    if record is None:
        raise HTTPException(status_code=404, detail="file not found")

    # 检查物理文件
    target_path, _ = build_cas_path(record.sha256, record.extension)
    if not target_path.exists() or not target_path.is_file():
        # 检查是否临时文件已过期清理（过期返回 410 Gone）
        if record.storage == "temporary" and record.expires_at and record.expires_at <= now_utc():
            raise HTTPException(status_code=410, detail="file expired")
        raise HTTPException(status_code=404, detail="file not found")

    # 检查文件夹下载权限
    if record.folder_id:
        from server_models import Folder
        from sqlalchemy import select
        result = await db.execute(select(Folder).where(Folder.id == record.folder_id))
        folder_record = result.scalar_one_or_none()
        if folder_record and folder_record.encrypted and not folder_record.allow_direct_download:
            if not downloadToken:
                raise HTTPException(status_code=401, detail="invalid download token")
            from server_storage import validate_download_token
            if not await validate_download_token(db, downloadToken.strip(), full_path):
                raise HTTPException(status_code=401, detail="invalid download token")

    # 记录访问
    await record_file_access(db, record.file_id)

    # 确定 Content-Disposition
    mime_type = record.mime_type
    disposition_mode = "inline" if is_inline_mime_type(mime_type) else "attachment"
    download_name = sanitize_index_name(record.indexed_name) or record.system_name
    content_disposition = build_content_disposition(disposition_mode, download_name)

    file_size = target_path.stat().st_size

    # 支持 Range 请求
    range_header = request.headers.get("range")
    if range_header:
        return _serve_range_response(target_path, file_size, mime_type, content_disposition, range_header)

    # HEAD 请求只返回头
    if request.method == "HEAD":
        from fastapi.responses import Response
        return Response(
            status_code=200,
            headers={
                "Content-Type": mime_type,
                "Content-Length": str(file_size),
                "Content-Disposition": content_disposition,
                "Accept-Ranges": "bytes",
                "X-Content-Type-Options": "nosniff",
            },
        )

    # 流式返回文件内容（异步生成器，通过线程池避免阻塞事件循环）
    return StreamingResponse(
        _async_file_chunk_generator(target_path),
        status_code=200,
        media_type=mime_type,
        headers={
            "Content-Disposition": content_disposition,
            "Accept-Ranges": "bytes",
            "X-Content-Type-Options": "nosniff",
            "Content-Length": str(file_size),
        },
    )


async def _async_file_chunk_generator(file_path):
    """异步文件分块生成器：将同步 read 放入线程池执行，避免阻塞事件循环"""
    chunk_size = 64 * 1024
    with open(file_path, "rb") as f:
        while True:
            chunk = await run_in_threadpool(f.read, chunk_size)
            if not chunk:
                break
            yield chunk


async def _serve_range_response(target_path, file_size: int, mime_type: str, content_disposition: str, range_header: str):
    """处理 HTTP Range 请求（异步生成器，通过线程池避免阻塞事件循环）"""
    import re

    match = re.match(r"bytes=(\d*)-(\d*)", range_header)
    if not match:
        raise HTTPException(status_code=416, detail="invalid range")

    start_str, end_str = match.groups()
    start = int(start_str) if start_str else 0
    end = int(end_str) if end_str else file_size - 1

    if start >= file_size or end >= file_size or start > end:
        raise HTTPException(status_code=416, detail="range not satisfiable")

    content_length = end - start + 1

    async def async_range_generator():
        chunk_size = 64 * 1024
        with open(target_path, "rb") as f:
            f.seek(start)
            remaining = content_length
            while remaining > 0:
                read_size = min(chunk_size, remaining)
                chunk = await run_in_threadpool(f.read, read_size)
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    return StreamingResponse(
        async_range_generator(),
        status_code=206,
        media_type=mime_type,
        headers={
            "Content-Range": f"bytes {start}-{end}/{file_size}",
            "Content-Length": str(content_length),
            "Content-Disposition": content_disposition,
            "Accept-Ranges": "bytes",
            "X-Content-Type-Options": "nosniff",
        },
    )


# ===================================================================
# PATCH /api/files — 重命名文件
# ===================================================================

@router.patch("/api/files")
async def handle_rename_file(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """重命名文件（修改 indexed_name）

    请求体：{"fileId": "...", "indexedName": "新文件名.ext"}
    """
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    file_id = body.get("fileId")
    new_name = body.get("indexedName")

    # 兼容旧版 path 参数：通过 path 查询 fileId
    if not file_id and body.get("path"):
        old_path = body["path"]
        record = await get_file_by_url(db, old_path)
        if record is None:
            raise HTTPException(status_code=404, detail="file not found")
        file_id = record.file_id

    if not isinstance(file_id, str) or not file_id:
        raise HTTPException(status_code=400, detail="missing file id")
    if not isinstance(new_name, str):
        raise HTTPException(status_code=400, detail="missing indexed name")

    normalized_name = sanitize_index_name(new_name)
    if normalized_name is None:
        raise HTTPException(status_code=400, detail="invalid indexed name")

    try:
        record = await rename_file(db, file_id, normalized_name)
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="internal server error")

    if record is None:
        raise HTTPException(status_code=404, detail="file not found")

    url = get_file_url(record.system_name)

    await write_audit_log(
        db=db,
        action_type="rename_file",
        indexed_name=normalized_name,
        file_path=url,
        client_ip=request.client.host if request.client else "",
    )

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "file renamed",
            "data": {
                "fileId": record.file_id,
                "path": url,
                "indexedName": normalized_name,
                "storage": record.storage,
            },
        },
    )


# ===================================================================
# DELETE /api/files — 删除文件（软删除，支持单个/批量）
# ===================================================================

@router.delete("/api/files")
async def handle_delete_file(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """删除文件（软删除，支持批量）

    单文件：?fileId=xxx  或  请求体 {"fileId": "xxx"}
    批量：请求体 {"fileIds": ["xxx", "yyy"]}
    兼容旧版：?path=xxx 或 {"path": "xxx", "paths": [...]}
    """
    await verify_management_token(db, courage_token)

    # 收集 fileId 列表
    file_ids = []

    # 方式一：查询参数
    query_file_id = request.query_params.get("fileId")
    if query_file_id:
        file_ids = [query_file_id.strip()]

    # 方式二：查询参数 path（兼容旧版）
    if not file_ids:
        query_path = request.query_params.get("path")
        if query_path:
            record = await get_file_by_url(db, query_path.strip())
            if record:
                file_ids = [record.file_id]

    # 方式三：JSON 请求体
    if not file_ids:
        try:
            body = await request.json()
        except Exception:
            body = None
        if isinstance(body, dict):
            if isinstance(body.get("fileId"), str) and body["fileId"]:
                file_ids = [body["fileId"]]
            elif isinstance(body.get("fileIds"), list):
                file_ids = [fid for fid in body["fileIds"] if isinstance(fid, str) and fid]
            # 兼容旧版 path
            elif isinstance(body.get("path"), str) and body["path"]:
                record = await get_file_by_url(db, body["path"])
                if record:
                    file_ids = [record.file_id]
            elif isinstance(body.get("paths"), list):
                for p in body["paths"]:
                    if isinstance(p, str) and p:
                        record = await get_file_by_url(db, p)
                        if record:
                            file_ids.append(record.file_id)

    if not file_ids:
        raise HTTPException(status_code=400, detail="missing file id")

    # 是否永久删除
    permanent = request.query_params.get("permanent", "").lower() == "true"

    if permanent:
        # 永久删除
        permanently_deleted = []
        not_found_perm = []
        for fid in file_ids:
            record = await permanent_delete_file(db, fid)
            if record:
                permanently_deleted.append(fid)
            else:
                not_found_perm.append(fid)
        if len(file_ids) == 1 and not permanently_deleted:
            raise HTTPException(status_code=404, detail="file not found")

        for fid in permanently_deleted:
            await write_audit_log(
                db=db, action_type="permanent_delete_file", file_path=fid,
                client_ip=request.client.host if request.client else "",
            )

        result_data = {"deleted": permanently_deleted}
        if not_found_perm:
            result_data["notFound"] = not_found_perm
        return JSONResponse(status_code=200, content={
            "code": 0, "message": "file permanently deleted", "data": result_data,
        })

    # 软删除
    deleted = []
    not_found = []
    for fid in file_ids:
        success = await soft_delete_file(db, fid)
        if success:
            deleted.append(fid)
        else:
            not_found.append(fid)

    if len(file_ids) == 1 and not deleted:
        raise HTTPException(status_code=404, detail="file not found")

    # 审计日志
    for fid in deleted:
        await write_audit_log(
            db=db,
            action_type="delete_file",
            file_path=fid,
            client_ip=request.client.host if request.client else "",
            extra={"batch": len(deleted) > 1},
        )

    if len(file_ids) == 1:
        return JSONResponse(
            status_code=200,
            content={
                "code": 0,
                "message": "file deleted",
                "data": {"fileId": deleted[0] if deleted else file_ids[0]},
            },
        )

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "batch delete completed",
            "data": {
                "requested": len(file_ids),
                "deletedCount": len(deleted),
                "notFoundCount": len(not_found),
                "deleted": deleted,
                "notFound": not_found,
            },
        },
    )


# ===================================================================
# POST /api/files/restore — 恢复软删除文件
# ===================================================================

@router.post("/api/files/restore")
async def handle_restore_file(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """恢复已软删除的文件

    请求体：{"fileId": "xxx"}  或  {"fileIds": ["xxx", "yyy"]}
    """
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    file_ids = []
    if isinstance(body.get("fileIds"), list):
        file_ids = [fid for fid in body["fileIds"] if isinstance(fid, str) and fid]
    elif isinstance(body.get("fileId"), str) and body["fileId"]:
        file_ids = [body["fileId"]]

    if not file_ids:
        raise HTTPException(status_code=400, detail="missing file id")

    restored = []
    not_found = []
    for fid in file_ids:
        record = await restore_file(db, fid)
        if record:
            restored.append(fid)
            await write_audit_log(
                db=db, action_type="restore_file",
                indexed_name=record.indexed_name,
                file_path=get_file_url(record.system_name),
                client_ip=request.client.host if request.client else "",
            )
        else:
            not_found.append(fid)

    if len(file_ids) == 1 and not restored:
        raise HTTPException(status_code=404, detail="file not found or not deleted")

    return JSONResponse(status_code=200, content={
        "code": 0, "message": "file restored",
        "data": {
            "restoredCount": len(restored),
            "restored": restored,
            "notFound": not_found if not_found else None,
        },
    })


# ===================================================================
# POST /api/files/move — 切换临时/永久存储
# ===================================================================

@router.post("/api/files/move")
async def handle_move_file(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """切换文件存储类型（temporary ↔ permanent）

    请求体：{"fileId": "xxx", "targetStorage": "permanent"}
    兼容旧版：{"path": "/images/...", "targetStorage": "permanent"}
    """
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    target_storage = body.get("targetStorage")
    if target_storage not in ("temporary", "permanent"):
        raise HTTPException(status_code=400, detail="invalid target storage")

    file_id = body.get("fileId")
    # 兼容旧版 path
    if not file_id and body.get("path"):
        record = await get_file_by_url(db, body["path"])
        if record:
            file_id = record.file_id

    if not isinstance(file_id, str) or not file_id:
        raise HTTPException(status_code=400, detail="missing file id")

    record = await move_file_storage(db, file_id, target_storage)
    if record is None:
        raise HTTPException(status_code=404, detail="file not found")

    response_data = build_file_response(record)

    await write_audit_log(
        db=db,
        action_type="move_file",
        indexed_name=record.indexed_name,
        file_path=get_file_url(record.system_name),
        client_ip=request.client.host if request.client else "",
        extra={"targetStorage": target_storage},
    )

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "file moved",
            "data": {
                **response_data,
                "sourceStorage": record.storage,
                "targetStorage": target_storage,
            },
        },
    )


# ===================================================================
# POST /api/files/folder — 调整文件所属文件夹
# ===================================================================

@router.post("/api/files/folder")
async def handle_assign_files_to_folder(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    target_folder_password_token: str = Header("", alias="Target-Folder-Password-Token"),
    db: AsyncSession = Depends(get_db),
):
    """将文件移动到指定文件夹（或移回根目录）

    请求体：{"fileIds": ["xxx"], "folderId": "folder-uuid"}  // folderId 为空=根目录
    兼容旧版：{"paths": ["/p/..."], "folderId": "..."}
    """
    await verify_management_token(db, courage_token)

    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    target_folder_id = normalize_folder_id(body.get("folderId"))

    # 检查目标文件夹访问权限
    if target_folder_id:
        from server_models import Folder
        from sqlalchemy import select
        result = await db.execute(select(Folder).where(Folder.id == target_folder_id))
        folder_record = result.scalar_one_or_none()
        if folder_record is None:
            raise HTTPException(status_code=404, detail="folder not found")
        if folder_record.encrypted:
            from server_auth import check_folder_password_token
            await check_folder_password_token(db, target_folder_id, target_folder_password_token)

    # 收集 fileId 列表
    file_ids = []
    if isinstance(body.get("fileIds"), list):
        file_ids = [fid for fid in body["fileIds"] if isinstance(fid, str) and fid]
    # 兼容旧版
    if not file_ids:
        paths = []
        if isinstance(body.get("path"), str) and body["path"]:
            paths = [body["path"]]
        elif isinstance(body.get("paths"), list):
            paths = [p for p in body["paths"] if isinstance(p, str) and p]
        for p in paths:
            record = await get_file_by_url(db, p)
            if record:
                file_ids.append(record.file_id)

    if not file_ids:
        raise HTTPException(status_code=400, detail="missing file id")

    updated = []
    missing = []
    for fid in file_ids:
        record = await set_file_folder(db, fid, target_folder_id or "")
        if record:
            updated.append(build_file_response(record))
        else:
            missing.append(fid)

    if not updated:
        raise HTTPException(status_code=404, detail="file not found")

    for item in updated:
        await write_audit_log(
            db=db,
            action_type="move_file_to_folder",
            indexed_name=item["indexedName"],
            file_path=item["url"],
            client_ip=request.client.host if request.client else "",
            extra={"folderId": target_folder_id, "batch": len(updated) > 1},
        )

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "file folder updated",
            "data": {"updated": updated, "missing": missing},
        },
    )
