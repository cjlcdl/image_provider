"""
上传路由模块 v3.0
================
处理文件上传相关请求：
  - POST /api/upload              普通上传（multipart/form-data）
  - POST /api/upload/resumable/init  创建续传会话
  - GET  /api/upload/resumable/{id}  查询续传进度
  - PATCH /api/upload/resumable/{id}  上传分片
  - POST /api/upload/resumable/{id}/complete  完成续传
  - DELETE /api/upload/resumable/{id}  取消续传

核心变更：
  - 物理文件采用内容寻址存储（CAS）：storage/files/{sha256前2位}/{sha256}.ext
  - 文件链接格式：/p/{base64url(systemName)}
  - 上传完成后计算 SHA-256，自动去重
  - 同文件夹同扩展名不允许重名
"""

import hashlib
import mimetypes
import os
import re
import shutil
import tempfile
from datetime import timedelta
from http import HTTPStatus
from pathlib import Path
from typing import Dict, Optional, Tuple

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from config import (
    FILE_ROUTE_PREFIX,
    MAX_UPLOAD_BYTES,
    PERMANENT_TOKEN_HEADER,
    RESUMABLE_UPLOAD_CHUNK_SIZE_HINT,
    UPLOAD_SESSION_MAX_AGE_SECONDS,
)
from server_auth import check_folder_password_token, validate_rsa_token_async
from server_database import get_db
from server_storage import (
    build_file_response,
    check_duplicate_name,
    check_sha256_exists,
    cancel_upload_session,
    complete_upload_session,
    create_file_record,
    create_upload_session,
    ensure_storage,
    get_file_by_url,
    get_upload_session,
    is_ip_blacklisted,
    is_rate_limited,
    update_upload_progress,
    write_audit_log,
)
from server_utils import (
    APP_CHANNEL_HEADER,
    USER_HEADER,
    UPLOAD_OFFSET_HEADER,
    UPLOAD_SESSION_ID_PATTERN,
    UPLOAD_SESSION_TOKEN_HEADER,
    FOLDER_PASSWORD_TOKEN_HEADER,
    FOLDER_PASSWORDS_TOKEN_HEADER,
    TARGET_FOLDER_PASSWORD_TOKEN_HEADER,
    UPLOAD_CHUNK_SIZE,
    build_cas_path,
    compute_sha256_hex,
    extract_extension,
    get_file_url,
    infer_extension_from_content_type,
    is_valid_boundary,
    normalize_folder_id,
    normalize_uploaded_filename,
    now_local,
    now_utc,
    sanitize_index_name,
    upload_chunk_path,
)

router = APIRouter(prefix="/api", tags=["上传"])

# JSON 请求体最大大小（16KB）
MAX_JSON_BODY_BYTES = 16 * 1024


# ===================================================================
# 辅助函数
# ===================================================================

async def _resolve_upload_mode(
    db: AsyncSession,
    courage_token: str,
) -> Tuple[Optional[str], Optional[Dict]]:
    """根据 Courage-Token 判断上传模式（temporary / permanent）

    Returns:
        (storage_type, token_payload)
        storage_type 为 None 表示验证失败（已抛出 HTTPException）
    """
    token_value = courage_token.strip()
    if not token_value:
        return "temporary", None

    is_valid, payload, code, message = await validate_rsa_token_async(db, token_value)
    if not is_valid:
        status = 401 if code < 50000 else 500
        raise HTTPException(status_code=status, detail=message)
    if payload is None:
        raise HTTPException(status_code=401, detail="invalid token")

    return "permanent", payload


async def _check_folder_access(
    db: AsyncSession,
    folder_id: Optional[str],
    folder_password_token: str,
) -> Optional[str]:
    """检查文件夹访问权限（加密文件夹需要密码令牌）"""
    if not folder_id:
        return None
    return await check_folder_password_token(db, folder_id, folder_password_token)


async def _save_uploaded_file(
    source_stream,
    target_path,
    max_size: int,
) -> Tuple[int, str]:
    """流式保存上传文件到目标路径，同时计算 SHA-256

    Returns:
        (bytes_written, sha256_hex)
    """
    sha256_hash = hashlib.sha256()
    bytes_written = 0
    try:
        target_path.parent.mkdir(parents=True, exist_ok=True)
        with target_path.open("wb") as f:
            while True:
                chunk = await source_stream.read(UPLOAD_CHUNK_SIZE)
                if not chunk:
                    break
                bytes_written += len(chunk)
                if bytes_written > max_size:
                    raise ValueError("file too large")
                sha256_hash.update(chunk)
                f.write(chunk)
    except Exception:
        if target_path.exists():
            target_path.unlink()
        raise

    return bytes_written, sha256_hash.hexdigest()


# ===================================================================
# POST /api/upload — 普通上传
# ===================================================================

@router.post("/upload")
async def handle_upload(
    request: Request,
    file: UploadFile = File(...),
    folder_id: Optional[str] = Form(None),
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    folder_password_token: str = Header("", alias=FOLDER_PASSWORD_TOKEN_HEADER),
    app_channel: str = Header("", alias=APP_CHANNEL_HEADER),
    user: str = Header("", alias=USER_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """上传文件（multipart/form-data）

    自动判断临时/永久：
      - 不带 Courage-Token → temporary
      - 带有效 Courage-Token → permanent
    """
    client_ip = request.client.host if request.client else "unknown"

    # 安全检查
    if is_ip_blacklisted(client_ip):
        raise HTTPException(status_code=403, detail="ip is blocked")
    if is_rate_limited(client_ip):
        raise HTTPException(status_code=429, detail="too many upload requests")

    # 判断上传模式
    upload_mode, token_payload = await _resolve_upload_mode(db, courage_token)

    # 检查文件夹访问权限
    normalized_folder = normalize_folder_id(folder_id) if folder_id else ""
    if normalized_folder:
        await _check_folder_access(db, normalized_folder, folder_password_token)

    # 标准化文件名
    content_type = file.content_type or "application/octet-stream"
    normalized_filename = normalize_uploaded_filename(file.filename, content_type)
    indexed_name = sanitize_index_name(normalized_filename)
    if indexed_name is None:
        raise HTTPException(status_code=400, detail="invalid indexed name")

    extension = extract_extension(normalized_filename)

    # 临时上传：先写入临时路径以计算 SHA-256
    # 使用 STORAGE_ROOT 确保临时文件与最终存储在同一分区（避免跨设备 move 失败）
    from config import STORAGE_ROOT
    temp_fd, temp_path_str = tempfile.mkstemp(dir=str(STORAGE_ROOT))
    os.close(temp_fd)
    temp_path = Path(temp_path_str)

    try:
        bytes_written, sha256_hex = await _save_uploaded_file(
            file, temp_path, MAX_UPLOAD_BYTES
        )
    except ValueError:
        temp_path.unlink(missing_ok=True)
        raise HTTPException(status_code=413, detail="file too large")
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail="internal server error")

    mime_type = mimetypes.guess_type(indexed_name)[0] or content_type

    # 去重：相同 hash 的文件已存在则复用物理文件
    existing = await check_sha256_exists(db, sha256_hex)
    if existing is not None:
        # 复用已有物理文件，删除临时文件
        system_name = existing.system_name
        temp_path.unlink(missing_ok=True)
    else:
        # 新文件：移动到 CAS 存储位置（去重保护：若目标已存在则复用）
        target_path, system_name = build_cas_path(sha256_hex, extension)
        target_path.parent.mkdir(parents=True, exist_ok=True)
        if target_path.exists():
            # 并发上传相同内容时，目标可能已被其他请求创建（SHA-256 一致）
            temp_path.unlink(missing_ok=True)
        else:
            shutil.move(str(temp_path), str(target_path))

    # 检查同文件夹同名冲突
    if await check_duplicate_name(db, indexed_name, normalized_folder, extension):
        raise HTTPException(status_code=409, detail="file name already exists in this folder")

    # 设置过期时间（通过环境变量可配置，默认24小时）
    temp_file_hours = int(os.getenv("IMAGE_PROVIDER_TEMP_FILE_HOURS", "24"))
    expires_at = None
    if upload_mode == "temporary":
        expires_at = now_utc() + timedelta(hours=temp_file_hours)

    # 写入元数据
    record = await create_file_record(
        db=db,
        indexed_name=indexed_name,
        system_name=system_name,
        storage=upload_mode,
        size=bytes_written,
        mime_type=mime_type,
        sha256=sha256_hex,
        extension=extension,
        folder_id=normalized_folder,
        uploaded_by=user.strip() or None,
        app_channel=app_channel.strip() or None,
        expires_at=expires_at,
    )

    # 审计日志
    await write_audit_log(
        db=db,
        action_type="upload_file",
        user=user.strip(),
        app_channel=app_channel.strip(),
        indexed_name=indexed_name,
        file_path=get_file_url(system_name),
        client_ip=client_ip,
        extra={"storage": upload_mode, "size": bytes_written},
    )

    response_data = build_file_response(record)
    return JSONResponse(
        status_code=200,
        content={"code": 0, "message": "upload succeeded", "data": response_data},
    )


# ===================================================================
# POST /api/upload/resumable/init — 创建续传会话
# ===================================================================

@router.post("/upload/resumable/init")
async def handle_resumable_init(
    request: Request,
    courage_token: str = Header("", alias=PERMANENT_TOKEN_HEADER),
    folder_password_token: str = Header("", alias=FOLDER_PASSWORD_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """创建断点续传上传会话"""
    client_ip = request.client.host if request.client else "unknown"

    if is_ip_blacklisted(client_ip):
        raise HTTPException(status_code=403, detail="ip is blocked")
    if is_rate_limited(client_ip):
        raise HTTPException(status_code=429, detail="too many upload requests")

    # 读取 JSON 请求体
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="invalid json body")

    # 验证文件大小
    total_size = body.get("size")
    if isinstance(total_size, str) and total_size.isdigit():
        total_size = int(total_size)
    if not isinstance(total_size, int) or total_size < 0:
        raise HTTPException(status_code=400, detail="invalid upload size")
    if total_size > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="file too large")

    raw_filename = body.get("filename")
    raw_mime = body.get("mimeType")
    requested_folder_id = normalize_folder_id(body.get("folderId"))
    provided_filename = raw_filename if isinstance(raw_filename, str) else ""
    provided_mime = raw_mime if isinstance(raw_mime, str) else ""

    # 检查文件夹
    if requested_folder_id:
        await _check_folder_access(db, requested_folder_id, folder_password_token)

    # 判断上传模式
    upload_mode, token_payload = await _resolve_upload_mode(db, courage_token)

    # 标准化文件名
    normalized_upload_name = normalize_uploaded_filename(provided_filename, provided_mime)
    indexed_name = sanitize_index_name(normalized_upload_name)
    if indexed_name is None:
        raise HTTPException(status_code=400, detail="invalid indexed name")

    extension = extract_extension(normalized_upload_name) or ""
    mime_type = provided_mime.strip() or mimetypes.guess_type(normalized_upload_name)[0] or "application/octet-stream"

    # 使用占位 SHA-256（续传完成时才计算真实哈希）
    placeholder_sha256 = "0" * 64
    _, system_name = build_cas_path(placeholder_sha256, extension)
    url_path = get_file_url(system_name)

    # 创建上传会话
    session = await create_upload_session(
        db=db,
        storage=upload_mode,
        indexed_name=indexed_name,
        system_name=system_name,
        relative_path=url_path,
        total_size=total_size,
        mime_type=mime_type,
        folder_id=requested_folder_id,
    )

    await write_audit_log(
        db=db,
        action_type="resumable_init",
        indexed_name=indexed_name,
        file_path=url_path,
        client_ip=client_ip,
        extra={"storage": upload_mode, "totalSize": total_size},
    )

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "upload session created",
            "data": {
                "uploadId": session.upload_id,
                "uploadToken": session.upload_token,
                "storage": upload_mode,
                "path": url_path,
                "url": url_path,
                "name": system_name,
                "indexedName": indexed_name,
                "mimeType": mime_type,
                "folderId": requested_folder_id,
                "totalSize": total_size,
                "uploadedBytes": 0,
                "chunkSizeHint": RESUMABLE_UPLOAD_CHUNK_SIZE_HINT,
                "expiresIn": UPLOAD_SESSION_MAX_AGE_SECONDS,
            },
        },
    )


# ===================================================================
# GET /api/upload/resumable/{upload_id} — 查询上传进度
# ===================================================================

@router.get("/upload/resumable/{upload_id}")
async def handle_resumable_status(
    upload_id: str,
    upload_token: str = Header("", alias=UPLOAD_SESSION_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """查询续传会话的上传进度"""
    if not UPLOAD_SESSION_ID_PATTERN.fullmatch(upload_id):
        raise HTTPException(status_code=400, detail="invalid resumable upload id")
    if not upload_token.strip():
        raise HTTPException(status_code=400, detail="missing upload token")

    session = await get_upload_session(db, upload_id)
    if session is None or session.upload_token != upload_token.strip():
        raise HTTPException(status_code=404, detail="upload session not found")
    if session.expires_at and session.expires_at <= now_utc():
        await cancel_upload_session(db, upload_id)
        raise HTTPException(status_code=404, detail="upload session expired")

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "ok",
            "data": {
                "uploadId": session.upload_id,
                "storage": session.storage,
                "path": session.relative_path,
                "url": session.relative_path,
                "name": session.system_name,
                "indexedName": session.indexed_name,
                "mimeType": session.mime_type,
                "folderId": session.folder_id,
                "totalSize": session.total_size,
                "uploadedBytes": session.uploaded_size,
                "complete": session.uploaded_size >= session.total_size,
            },
        },
    )


# ===================================================================
# PATCH /api/upload/resumable/{upload_id} — 上传分片
# ===================================================================

@router.patch("/upload/resumable/{upload_id}")
async def handle_resumable_chunk(
    upload_id: str,
    request: Request,
    upload_token: str = Header("", alias=UPLOAD_SESSION_TOKEN_HEADER),
    upload_offset: str = Header("", alias=UPLOAD_OFFSET_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """上传一个分片到续传会话"""
    client_ip = request.client.host if request.client else "unknown"

    if is_ip_blacklisted(client_ip):
        raise HTTPException(status_code=403, detail="ip is blocked")

    if not UPLOAD_SESSION_ID_PATTERN.fullmatch(upload_id):
        raise HTTPException(status_code=400, detail="invalid resumable upload id")
    if not upload_token.strip():
        raise HTTPException(status_code=400, detail="missing upload token")

    # 验证偏移量
    if not upload_offset.strip():
        raise HTTPException(status_code=400, detail="missing upload offset")
    try:
        offset = int(upload_offset)
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid upload offset")

    # 加载会话
    session = await get_upload_session(db, upload_id)
    if session is None or session.upload_token != upload_token.strip():
        raise HTTPException(status_code=404, detail="upload session not found")
    if session.expires_at and session.expires_at <= now_utc():
        await cancel_upload_session(db, upload_id)
        raise HTTPException(status_code=404, detail="upload session expired")

    # 验证偏移量
    uploaded = int(session.uploaded_size)
    total = int(session.total_size)
    if offset != uploaded:
        return JSONResponse(
            status_code=409,
            content={
                "code": 40901,
                "message": "upload offset mismatch",
                "data": {"uploadedBytes": uploaded, "totalSize": total},
            },
        )

    # 读取分片数据并写入磁盘
    chunk_path = upload_chunk_path(upload_id)
    chunk_path.parent.mkdir(parents=True, exist_ok=True)

    body = await request.body()
    bytes_read = len(body)

    if bytes_read + uploaded > total:
        raise HTTPException(status_code=400, detail="chunk exceeds total size")

    with chunk_path.open("ab") as f:
        f.write(body)

    # 更新进度
    new_uploaded = uploaded + bytes_read
    await update_upload_progress(db, upload_id, new_uploaded)

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "chunk accepted",
            "data": {
                "uploadId": upload_id,
                "uploadedBytes": new_uploaded,
                "totalSize": total,
                "complete": new_uploaded >= total,
            },
        },
    )


# ===================================================================
# POST /api/upload/resumable/{upload_id}/complete — 完成续传
# ===================================================================

@router.post("/upload/resumable/{upload_id}/complete")
async def handle_resumable_complete(
    upload_id: str,
    request: Request,
    upload_token: str = Header("", alias=UPLOAD_SESSION_TOKEN_HEADER),
    app_channel: str = Header("", alias=APP_CHANNEL_HEADER),
    user: str = Header("", alias=USER_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """完成续传上传——将分片文件移入 CAS 存储并写入元数据"""
    client_ip = request.client.host if request.client else "unknown"

    if not UPLOAD_SESSION_ID_PATTERN.fullmatch(upload_id):
        raise HTTPException(status_code=400, detail="invalid resumable upload id")
    if not upload_token.strip():
        raise HTTPException(status_code=400, detail="missing upload token")

    session = await get_upload_session(db, upload_id)
    if session is None or session.upload_token != upload_token.strip():
        raise HTTPException(status_code=404, detail="upload session not found")

    total = int(session.total_size)
    uploaded = int(session.uploaded_size)
    if uploaded < total:
        return JSONResponse(
            status_code=409,
            content={
                "code": 40902,
                "message": "upload is incomplete",
                "data": {"uploadedBytes": uploaded, "totalSize": total},
            },
        )

    chunk_path = upload_chunk_path(upload_id)
    if total > 0 and (not chunk_path.exists() or chunk_path.stat().st_size < total):
        return JSONResponse(
            status_code=409,
            content={
                "code": 40902,
                "message": "upload is incomplete",
                "data": {
                    "uploadedBytes": chunk_path.stat().st_size if chunk_path.exists() else 0,
                    "totalSize": total,
                },
            },
        )

    # 计算 SHA-256 哈希
    if total > 0:
        sha256_hex = compute_sha256_hex(chunk_path)
    else:
        sha256_hex = hashlib.sha256(b"").hexdigest()

    # 提取扩展名
    extension = extract_extension(session.indexed_name) or ""

    # 去重检查（必须在确定 target_path 之前）
    existing = await check_sha256_exists(db, sha256_hex)
    if existing is not None:
        # 内容相同 → 复用已有物理文件，删除上传的分片
        system_name = existing.system_name
        file_size = existing.size
        chunk_path.unlink(missing_ok=True)
        # 根据已有记录的系统文件名重新计算 target_path（扩展名可能不同）
        existing_ext = extract_extension(existing.system_name) or ""
        target_path, _ = build_cas_path(sha256_hex, existing_ext)
    else:
        # 新文件 → 移动到 CAS 存储
        target_path, system_name = build_cas_path(sha256_hex, extension)
        target_path.parent.mkdir(parents=True, exist_ok=True)
        if total > 0:
            shutil.move(str(chunk_path), str(target_path))
        else:
            target_path.touch()
        file_size = target_path.stat().st_size

    # 更新会话中的 system_name
    session.system_name = system_name

    # 检查同名冲突
    folder_id = normalize_folder_id(session.folder_id) if session.folder_id else ""
    if await check_duplicate_name(db, session.indexed_name, folder_id, extension):
        raise HTTPException(status_code=409, detail="file name already exists in this folder")

    # 设置过期时间（通过环境变量 IMAGE_PROVIDER_TEMP_FILE_HOURS 可配置，默认24小时）
    temp_file_hours = int(os.getenv("IMAGE_PROVIDER_TEMP_FILE_HOURS", "24"))
    expires_at = None
    if session.storage == "temporary":
        expires_at = now_utc() + timedelta(hours=temp_file_hours)

    # 写入文件元数据
    record = await create_file_record(
        db=db,
        indexed_name=session.indexed_name,
        system_name=system_name,
        storage=session.storage,
        size=file_size,
        mime_type=session.mime_type,
        sha256=sha256_hex,
        extension=extension,
        folder_id=folder_id,
        uploaded_by=user.strip() or None,
        app_channel=app_channel.strip() or None,
        expires_at=expires_at,
    )

    # 标记会话完成
    await complete_upload_session(db, upload_id)

    await write_audit_log(
        db=db,
        action_type="upload_file",
        user=user.strip(),
        app_channel=app_channel.strip(),
        indexed_name=session.indexed_name,
        file_path=get_file_url(system_name),
        client_ip=client_ip,
        extra={"storage": session.storage, "size": record.size, "resumable": True},
    )

    response_data = build_file_response(record)
    return JSONResponse(
        status_code=200,
        content={"code": 0, "message": "upload succeeded", "data": response_data},
    )


# ===================================================================
# DELETE /api/upload/resumable/{upload_id} — 取消续传
# ===================================================================

@router.delete("/upload/resumable/{upload_id}")
async def handle_resumable_cancel(
    upload_id: str,
    upload_token: str = Header("", alias=UPLOAD_SESSION_TOKEN_HEADER),
    db: AsyncSession = Depends(get_db),
):
    """取消续传上传会话"""
    if not UPLOAD_SESSION_ID_PATTERN.fullmatch(upload_id):
        raise HTTPException(status_code=400, detail="invalid resumable upload id")
    if not upload_token.strip():
        raise HTTPException(status_code=400, detail="missing upload token")

    session = await get_upload_session(db, upload_id)
    if session is None or session.upload_token != upload_token.strip():
        raise HTTPException(status_code=404, detail="upload session not found")

    path = session.relative_path
    name = session.indexed_name
    await cancel_upload_session(db, upload_id)

    return JSONResponse(
        status_code=200,
        content={
            "code": 0,
            "message": "upload session canceled",
            "data": {"uploadId": upload_id, "path": path, "indexedName": name},
        },
    )
