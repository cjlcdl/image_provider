"""
存储层 v3.0 — 异步数据库操作 + 文件系统操作
==========================================
所有元数据操作通过 SQLAlchemy 异步会话执行，物理文件操作直接访问文件系统。
包含：
  - 文件元数据 CRUD（含软删除、去重、同文件夹同扩展名唯一性约束）
  - 虚拟文件夹 CRUD（多级嵌套、密码加密、后代收集）
  - 下载令牌管理
  - 上传会话管理（断点续传）
  - 审计日志写入
  - 临时文件定时清理
  - 频率限制与 IP 黑名单
  - 磁盘容量查询
"""

import json
import shutil
import time as unix_time
from datetime import datetime, time, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import server_state as state
from config import (
    CLEANUP_HOUR,
    DOWNLOAD_TOKEN_MAX_DAYS,
    IP_BLACKLIST,
    RATE_LIMIT_MAX_REQUESTS,
    RATE_LIMIT_WINDOW_SECONDS,
    STORAGE_ROOT,
    UPLOAD_SESSION_MAX_AGE_SECONDS,
)
from server_utils import (
    CHINA_TZ,
    build_cas_path,
    extract_extension,
    format_utc_iso,
    get_file_url,
    now_local,
    now_utc,
    parse_file_url,
    remove_chunk_file,
)

# SQLAlchemy 异步导入
from sqlalchemy import and_, delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from server_models import AuditLog, DownloadToken, Folder, StoredFile, UploadSession


# ===================================================================
# 存储目录初始化
# ===================================================================

def ensure_storage() -> None:
    """确保所有存储目录存在"""
    from config import CHUNK_STORAGE_ROOT, FILES_STORAGE_ROOT

    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    FILES_STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    CHUNK_STORAGE_ROOT.mkdir(parents=True, exist_ok=True)


# ===================================================================
# 频率限制与 IP 黑名单（同步，内存操作）
# ===================================================================

def is_ip_blacklisted(client_ip: str) -> bool:
    """检查 IP 是否在黑名单中"""
    return client_ip in IP_BLACKLIST


def is_rate_limited(client_ip: str) -> bool:
    """检查客户端 IP 是否超过上传频率限制（滑动时间窗口）"""
    current_window = int(unix_time.time()) // RATE_LIMIT_WINDOW_SECONDS
    with state.rate_limit_lock:
        stale_ips = [
            ip
            for ip, bucket in state.upload_rate_windows.items()
            if bucket["window"] != current_window
        ]
        for ip in stale_ips:
            state.upload_rate_windows.pop(ip, None)

        bucket = state.upload_rate_windows.get(client_ip)
        if bucket is None:
            state.upload_rate_windows[client_ip] = {"window": current_window, "count": 1}
            return False
        if bucket["count"] >= RATE_LIMIT_MAX_REQUESTS:
            return True
        bucket["count"] += 1
        return False


# ===================================================================
# 磁盘容量
# ===================================================================

def get_disk_capacity() -> Dict[str, int]:
    """获取存储磁盘的总量、已用量、可用量（字节）"""
    total, used, free = shutil.disk_usage(str(STORAGE_ROOT.resolve()))
    return {
        "diskTotalBytes": int(total),
        "diskUsedBytes": int(used),
        "diskFreeBytes": int(free),
    }


# ===================================================================
# 清理日期状态管理
# ===================================================================

def read_last_cleanup_date() -> Optional[str]:
    """读取上次清理日期"""
    if not state.STATE_FILE.exists():
        return None
    return state.STATE_FILE.read_text(encoding="utf-8").strip() or None


def write_last_cleanup_date(cleanup_date: str) -> None:
    """写入清理日期"""
    state.STATE_FILE.write_text(cleanup_date, encoding="utf-8")


# ===================================================================
# 文件元数据 CRUD（异步）
# ===================================================================

async def create_file_record(
    db: AsyncSession,
    *,
    indexed_name: str,
    system_name: str,
    storage: str,
    size: int,
    mime_type: str,
    sha256: str,
    extension: str,
    folder_id: str = "",
    uploaded_by: Optional[str] = None,
    app_channel: Optional[str] = None,
    expires_at: Optional[datetime] = None,
) -> StoredFile:
    """创建文件元数据记录

    插入后由 after_insert 事件自动生成 12 位 base62 file_id。
    """
    record = StoredFile(
        indexed_name=indexed_name,
        system_name=system_name,
        storage=storage,
        size=size,
        mime_type=mime_type,
        sha256=sha256,
        extension=extension,
        folder_id=folder_id,
        uploaded_by=uploaded_by,
        app_channel=app_channel,
        created_at=now_utc(),
        expires_at=expires_at,
    )
    db.add(record)
    await db.flush()  # 触发 after_insert → 生成 file_id
    return record


async def get_file_by_id(db: AsyncSession, file_id: str) -> Optional[StoredFile]:
    """通过 12 位短 file_id 查询文件（排除已软删除）"""
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.file_id == file_id,
            StoredFile.deleted_at.is_(None),
        )
    )
    return result.scalar_one_or_none()


async def get_file_by_system_name(db: AsyncSession, system_name: str) -> Optional[StoredFile]:
    """通过系统文件名（sha256.ext）查询文件（排除已软删除）"""
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.system_name == system_name,
            StoredFile.deleted_at.is_(None),
        )
    )
    return result.scalar_one_or_none()


async def get_file_by_url(db: AsyncSession, url_path: str) -> Optional[StoredFile]:
    """通过 /p/{base64url} URL 路径解析并查询文件"""
    system_name = parse_file_url(url_path)
    if system_name is None:
        return None
    return await get_file_by_system_name(db, system_name)


async def check_duplicate_name(
    db: AsyncSession,
    indexed_name: str,
    folder_id: str,
    extension: str,
    exclude_file_id: Optional[str] = None,
) -> bool:
    """检查同文件夹下是否已存在同扩展名的同名文件

    用于上传/重命名前的唯一性校验（模拟真实文件系统行为）。
    """
    conditions = [
        StoredFile.indexed_name == indexed_name,
        StoredFile.folder_id == folder_id,
        StoredFile.extension == extension,
        StoredFile.deleted_at.is_(None),
    ]
    if exclude_file_id:
        conditions.append(StoredFile.file_id != exclude_file_id)

    result = await db.execute(select(StoredFile).where(and_(*conditions)))
    return result.scalar_one_or_none() is not None


async def check_sha256_exists(db: AsyncSession, sha256: str) -> Optional[StoredFile]:
    """检查相同 SHA-256 哈希的文件是否已存在（用于去重）

    返回任意一条匹配记录即可——物理文件只需存一份。
    """
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.sha256 == sha256,
            StoredFile.deleted_at.is_(None),
        ).limit(1)
    )
    return result.scalar_one_or_none()


async def list_files_query(
    db: AsyncSession,
    *,
    storage_filter: Optional[str] = None,
    keyword: Optional[str] = None,
    mime_type: Optional[str] = None,
    extension: Optional[str] = None,
    folder_id: Optional[str] = None,
    page: int = 1,
    page_size: int = 50,
    include_deleted: bool = False,
) -> Tuple[List[StoredFile], int]:
    """分页查询文件列表（支持多条件筛选）

    Args:
        storage_filter: 按存储类型筛选 (temporary/permanent)
        keyword: 按文件名模糊搜索（匹配 indexed_name、system_name、file_id）
        mime_type: 按 MIME 类型精确筛选
        extension: 按扩展名筛选（不含点号）
        folder_id: 按文件夹筛选（None=全部, ""=根目录, 具体ID=该文件夹）
        page: 页码（从 1 开始）
        page_size: 每页条数（最大 200）
        include_deleted: 仅显示已删除文件（回收站模式），默认 False 仅显示未删除文件

    Returns:
        (文件列表, 总记录数)
    """
    conditions = []
    if include_deleted:
        conditions.append(StoredFile.deleted_at.isnot(None))
    else:
        conditions.append(StoredFile.deleted_at.is_(None))
    if storage_filter:
        conditions.append(StoredFile.storage == storage_filter)
    if mime_type:
        conditions.append(StoredFile.mime_type == mime_type)
    if extension:
        normalized_ext = f".{extension.lower().lstrip('.')}"
        conditions.append(StoredFile.extension == normalized_ext)
    if folder_id is not None:
        conditions.append(StoredFile.folder_id == folder_id)
    if keyword:
        kw = f"%{keyword.lower()}%"
        conditions.append(
            or_(
                StoredFile.indexed_name.ilike(kw),
                StoredFile.system_name.ilike(kw),
                StoredFile.file_id.ilike(kw),
            )
        )

    # 总数查询
    count_q = select(func.count()).select_from(StoredFile)
    if conditions:
        count_q = count_q.where(and_(*conditions))
    total = (await db.execute(count_q)).scalar() or 0

    # 分页查询
    query = select(StoredFile).order_by(StoredFile.created_at.desc())
    if conditions:
        query = query.where(and_(*conditions))
    query = query.offset((page - 1) * page_size).limit(page_size)
    rows = (await db.execute(query)).scalars().all()

    return list(rows), total


async def soft_delete_file(db: AsyncSession, file_id: str) -> bool:
    """软删除文件：设置 deleted_at 时间戳，不删除物理文件"""
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.file_id == file_id,
            StoredFile.deleted_at.is_(None),
        )
    )
    record = result.scalar_one_or_none()
    if record is None:
        return False
    record.deleted_at = now_utc()
    await db.flush()
    return True


async def permanent_delete_file(db: AsyncSession, file_id: str) -> Optional[StoredFile]:
    """永久删除文件：删除元数据记录。

    物理文件仅在没有其他记录引用同一 SHA-256 时才删除（去重保护）。
    """
    result = await db.execute(
        select(StoredFile).where(StoredFile.file_id == file_id)
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None

    sha256 = record.sha256
    system_name = record.system_name

    await db.delete(record)
    await db.flush()

    # 无其他引用才删物理文件
    ref_result = await db.execute(
        select(func.count()).select_from(StoredFile).where(
            StoredFile.sha256 == sha256,
            StoredFile.deleted_at.is_(None),
        )
    )
    if (ref_result.scalar() or 0) == 0:
        ext = extract_extension(system_name)
        target_path, _ = build_cas_path(sha256, ext)
        if target_path.exists():
            target_path.unlink()
        shard_dir = target_path.parent
        if shard_dir.exists() and not any(shard_dir.iterdir()):
            shard_dir.rmdir()

    return record


async def restore_file(db: AsyncSession, file_id: str) -> Optional[StoredFile]:
    """恢复软删除的文件：清除 deleted_at 时间戳"""
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.file_id == file_id,
            StoredFile.deleted_at.isnot(None),
        )
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None
    record.deleted_at = None
    await db.flush()
    return record


async def rename_file(db: AsyncSession, file_id: str, new_indexed_name: str) -> Optional[StoredFile]:
    """重命名文件（更新 indexed_name，检查同名冲突）"""
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.file_id == file_id,
            StoredFile.deleted_at.is_(None),
        )
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None

    new_ext = extract_extension(new_indexed_name) or record.extension
    if await check_duplicate_name(db, new_indexed_name, record.folder_id, new_ext, exclude_file_id=file_id):
        from fastapi import HTTPException
        raise HTTPException(status_code=409, detail="file name already exists in this folder")

    record.indexed_name = new_indexed_name
    if new_ext != record.extension:
        record.extension = new_ext
    await db.flush()
    return record


async def move_file_storage(db: AsyncSession, file_id: str, target_storage: str) -> Optional[StoredFile]:
    """切换文件存储类型（temporary ↔ permanent）"""
    if target_storage not in ("temporary", "permanent"):
        return None
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.file_id == file_id,
            StoredFile.deleted_at.is_(None),
        )
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None
    record.storage = target_storage
    if target_storage == "permanent":
        record.expires_at = None
    await db.flush()
    return record


async def set_file_folder(db: AsyncSession, file_id: str, folder_id: str) -> Optional[StoredFile]:
    """调整文件所属文件夹"""
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.file_id == file_id,
            StoredFile.deleted_at.is_(None),
        )
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None
    record.folder_id = folder_id
    await db.flush()
    return record


async def record_file_access(db: AsyncSession, file_id: str) -> None:
    """更新文件的最后访问时间和访问计数"""
    await db.execute(
        update(StoredFile)
        .where(StoredFile.file_id == file_id)
        .values(
            last_accessed_at=now_utc(),
            access_count=StoredFile.access_count + 1,
        )
    )
    await db.flush()


def build_file_response(record: StoredFile) -> Dict[str, Any]:
    """将 StoredFile ORM 对象转换为 API 响应字典"""
    url = get_file_url(record.system_name)
    return {
        "fileId": record.file_id,
        "indexedName": record.indexed_name,
        "systemName": record.system_name,
        "storage": record.storage,
        "size": record.size,
        "mimeType": record.mime_type,
        "sha256": record.sha256,
        "extension": record.extension,
        "path": url,
        "url": url,
        "folderId": record.folder_id or None,
        "uploadedBy": record.uploaded_by,
        "appChannel": record.app_channel,
        "createdAt": format_utc_iso(record.created_at),
        "uploadedAt": format_utc_iso(record.created_at),
        "deletedAt": format_utc_iso(record.deleted_at),
        "lastAccessedAt": format_utc_iso(record.last_accessed_at),
        "accessCount": record.access_count,
        "isDeleted": record.deleted_at is not None,
    }


# ===================================================================
# 虚拟文件夹 CRUD（异步，替代原 folder_index.py）
# ===================================================================

async def create_folder_record(
    db: AsyncSession,
    *,
    name: str,
    parent_id: Optional[str] = None,
    encrypted: bool = False,
    password: Optional[str] = None,
    allow_direct_download: bool = True,
) -> Folder:
    """创建虚拟文件夹

    Args:
        name: 文件夹名称
        parent_id: 父文件夹 ID（None 表示根级）
        encrypted: 是否加密
        password: 加密密码（encrypted=True 时必填）
        allow_direct_download: 是否允许直接下载

    Returns:
        新创建的 Folder ORM 对象

    Raises:
        PermissionError: 加密文件夹未提供密码
    """
    import uuid

    from server_auth import _generate_password_hash

    if encrypted and not password:
        raise PermissionError("missing folder password")

    folder_id = uuid.uuid4().hex
    now_ts = now_utc()

    record = Folder(
        id=folder_id,
        name=name,
        parent_id=parent_id,
        encrypted=encrypted,
        allow_direct_download=allow_direct_download if encrypted else True,
        created_at=now_ts,
        updated_at=now_ts,
    )
    if encrypted and password:
        pw_data = _generate_password_hash(password)
        record.password_salt = pw_data["passwordSalt"]
        record.password_hash = pw_data["passwordHash"]

    db.add(record)
    await db.flush()
    return record


async def get_folder_record(db: AsyncSession, folder_id: str) -> Optional[Folder]:
    """按 ID 查询文件夹"""
    result = await db.execute(select(Folder).where(Folder.id == folder_id))
    return result.scalar_one_or_none()


async def list_all_folders(db: AsyncSession) -> List[Folder]:
    """列出所有文件夹"""
    result = await db.execute(select(Folder).order_by(Folder.name))
    return list(result.scalars().all())


async def collect_descendant_folder_ids(db: AsyncSession, folder_id: str) -> List[str]:
    """广度优先收集某文件夹的所有后代文件夹 ID"""
    descendants: List[str] = []
    pending = [folder_id]
    while pending:
        current = pending.pop(0)
        result = await db.execute(select(Folder.id).where(Folder.parent_id == current))
        child_ids = [row[0] for row in result.all()]
        descendants.extend(child_ids)
        pending.extend(child_ids)
    return descendants


async def update_folder_record(
    db: AsyncSession,
    folder_id: str,
    *,
    name: Optional[str] = None,
    parent_id: Optional[str] = None,
    parent_id_provided: bool = False,
    encrypted: Optional[bool] = None,
    allow_direct_download: Optional[bool] = None,
    password: Optional[str] = None,
) -> Optional[Folder]:
    """更新文件夹属性

    Returns:
        更新后的 Folder 对象，文件夹不存在时返回 None

    Raises:
        ValueError: 无效的文件夹名或循环引用
        PermissionError: 加密操作缺少密码
    """
    from server_auth import _generate_password_hash
    from server_utils import sanitize_index_name as sanitize_folder_name

    result = await db.execute(select(Folder).where(Folder.id == folder_id))
    record = result.scalar_one_or_none()
    if record is None:
        return None

    # 更新名称
    if name is not None:
        normalized = sanitize_folder_name(name)
        if normalized is None:
            raise ValueError("invalid folder name")
        record.name = normalized

    # 更新父目录（含循环引用检查）
    if parent_id_provided:
        new_parent = parent_id or None  # None 表示移到根级
        if new_parent == folder_id:
            raise ValueError("invalid target parent")
        if new_parent:
            descendants = await collect_descendant_folder_ids(db, folder_id)
            if new_parent in descendants:
                raise ValueError("invalid target parent")
            # 验证目标父目录存在
            parent_result = await db.execute(select(Folder).where(Folder.id == new_parent))
            if parent_result.scalar_one_or_none() is None:
                raise KeyError("target parent folder not found")
        record.parent_id = new_parent

    # 更新加密状态
    if encrypted is not None:
        record.encrypted = encrypted
        if encrypted:
            if not password:
                raise PermissionError("missing folder password")
            pw_data = _generate_password_hash(password)
            record.password_salt = pw_data["passwordSalt"]
            record.password_hash = pw_data["passwordHash"]
            if allow_direct_download is not None:
                record.allow_direct_download = allow_direct_download
        else:
            record.password_salt = None
            record.password_hash = None
            record.allow_direct_download = True
    elif allow_direct_download is not None:
        record.allow_direct_download = allow_direct_download

    # 单独修改密码（加密状态不变）
    if encrypted is None and password:
        if not record.encrypted:
            raise ValueError("folder is not encrypted")
        pw_data = _generate_password_hash(password)
        record.password_salt = pw_data["passwordSalt"]
        record.password_hash = pw_data["passwordHash"]

    record.updated_at = now_utc()
    await db.flush()
    return record


async def delete_folder_cascade(db: AsyncSession, folder_id: str) -> List[str]:
    """级联删除文件夹及其所有后代文件夹

    Returns:
        被删除的所有文件夹 ID 列表
    """
    descendants = await collect_descendant_folder_ids(db, folder_id)
    all_ids = [folder_id] + descendants

    # 将属于这些文件夹的文件移到根目录（而非删除文件）
    for fid in all_ids:
        await db.execute(
            update(StoredFile)
            .where(StoredFile.folder_id == fid)
            .values(folder_id="")
        )

    # 删除文件夹记录
    for fid in all_ids:
        result = await db.execute(select(Folder).where(Folder.id == fid))
        folder_record = result.scalar_one_or_none()
        if folder_record is not None:
            await db.delete(folder_record)

    await db.flush()
    return all_ids


def build_folder_response(record: Folder, all_folders: Dict[str, "Folder"]) -> Dict[str, Any]:
    """将 Folder ORM 对象转为 API 响应字典

    Args:
        record: 文件夹 ORM 对象
        all_folders: 所有文件夹的 {id: Folder} 字典，用于构建路径
    """
    # 构建路径
    names = []
    current_id = record.parent_id
    seen = set()
    while current_id:
        if current_id in seen:
            break
        seen.add(current_id)
        parent = all_folders.get(current_id)
        if parent is None:
            break
        names.append(parent.name)
        current_id = parent.parent_id
    names.reverse()
    path = "/" + "/".join(names + [record.name]) if names else "/" + record.name
    depth = len(path.strip("/").split("/"))

    return {
        "id": record.id,
        "name": record.name,
        "parentId": record.parent_id,
        "encrypted": record.encrypted,
        "allowDirectDownload": record.allow_direct_download,
        "createdAt": format_utc_iso(record.created_at),
        "updatedAt": format_utc_iso(record.updated_at),
        "path": path,
        "depth": depth,
    }


# ===================================================================
# 下载令牌管理
# ===================================================================

async def create_download_token_record(
    db: AsyncSession,
    file_path: str,
    folder_id: str,
    expires_days: int,
) -> DownloadToken:
    """创建受保护文件的临时下载令牌"""
    import secrets

    bounded_days = max(1, min(expires_days, DOWNLOAD_TOKEN_MAX_DAYS))
    expires_at = now_utc() + timedelta(days=bounded_days)
    token = secrets.token_urlsafe(32)

    record = DownloadToken(
        token=token,
        file_path=file_path,
        folder_id=folder_id,
        expires_at=expires_at,
    )
    db.add(record)
    await db.flush()
    return record


async def validate_download_token(db: AsyncSession, token: str, file_path: str) -> bool:
    """验证下载令牌（一次性使用：验证后标记为已使用，防止重复利用）"""
    await _prune_download_tokens(db)
    result = await db.execute(
        select(DownloadToken).where(DownloadToken.token == token)
    )
    record = result.scalar_one_or_none()
    if record is None:
        return False
    # 一次性令牌：已使用过的拒绝
    if record.used_at is not None:
        return False
    if record.file_path != file_path:
        return False
    # 标记为已使用
    record.used_at = now_utc()
    await db.flush()
    return True


async def _prune_download_tokens(db: AsyncSession) -> None:
    """清理过期的下载令牌"""
    await db.execute(
        delete(DownloadToken).where(DownloadToken.expires_at <= now_utc())
    )
    await db.flush()


# ===================================================================
# 上传会话管理（断点续传）
# ===================================================================

async def create_upload_session(
    db: AsyncSession,
    *,
    storage: str,
    indexed_name: str,
    system_name: str,
    relative_path: str,
    total_size: int,
    mime_type: str,
    folder_id: Optional[str] = None,
) -> UploadSession:
    """创建断点续传上传会话"""
    import secrets
    import uuid

    upload_id = uuid.uuid4().hex
    upload_token = secrets.token_urlsafe(32)
    now_ts = now_utc()
    expires_at = now_ts + timedelta(seconds=UPLOAD_SESSION_MAX_AGE_SECONDS)

    record = UploadSession(
        upload_id=upload_id,
        upload_token=upload_token,
        status="uploading",
        storage=storage,
        indexed_name=indexed_name,
        system_name=system_name,
        relative_path=relative_path,
        total_size=total_size,
        uploaded_size=0,
        mime_type=mime_type,
        folder_id=folder_id,
        created_at=now_ts,
        updated_at=now_ts,
        expires_at=expires_at,
    )
    db.add(record)
    await db.flush()
    return record


async def get_upload_session(db: AsyncSession, upload_id: str) -> Optional[UploadSession]:
    """按 ID 查询上传会话"""
    result = await db.execute(
        select(UploadSession).where(UploadSession.upload_id == upload_id)
    )
    return result.scalar_one_or_none()


async def update_upload_progress(
    db: AsyncSession, upload_id: str, uploaded_size: int
) -> Optional[UploadSession]:
    """更新上传会话的已上传字节数"""
    result = await db.execute(
        select(UploadSession).where(UploadSession.upload_id == upload_id)
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None
    record.uploaded_size = uploaded_size
    record.updated_at = now_utc()
    await db.flush()
    return record


async def complete_upload_session(db: AsyncSession, upload_id: str) -> Optional[UploadSession]:
    """标记上传会话为已完成"""
    result = await db.execute(
        select(UploadSession).where(UploadSession.upload_id == upload_id)
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None
    record.status = "completed"
    record.updated_at = now_utc()
    await db.flush()
    return record


async def cancel_upload_session(db: AsyncSession, upload_id: str) -> None:
    """取消上传会话（删除记录 + 清理分片文件）"""
    result = await db.execute(
        select(UploadSession).where(UploadSession.upload_id == upload_id)
    )
    record = result.scalar_one_or_none()
    if record is not None:
        await db.delete(record)
        await db.flush()
    remove_chunk_file(upload_id)


async def cleanup_expired_sessions(db: AsyncSession) -> int:
    """清理所有过期的上传会话"""
    result = await db.execute(
        select(UploadSession).where(UploadSession.expires_at <= now_utc())
    )
    expired = result.scalars().all()
    count = 0
    for rec in expired:
        remove_chunk_file(rec.upload_id)
        await db.delete(rec)
        count += 1
    if count > 0:
        await db.flush()
    return count


# ===================================================================
# 审计日志
# ===================================================================

async def write_audit_log(
    db: AsyncSession,
    *,
    action_type: str,
    user: str = "",
    app_channel: str = "",
    indexed_name: str = "",
    file_path: str = "",
    client_ip: str = "",
    extra: Optional[Dict[str, Any]] = None,
) -> None:
    """写入一条审计日志到数据库"""
    record = AuditLog(
        time=now_utc(),
        user=user,
        app_channel=app_channel,
        action_type=action_type,
        indexed_name=indexed_name,
        file_path=file_path,
        client_ip=client_ip,
        extra_json=json.dumps(extra, ensure_ascii=False) if extra else None,
    )
    db.add(record)
    await db.flush()


# ===================================================================
# 临时文件定时清理
# ===================================================================

async def cleanup_expired_temp_files(db: AsyncSession) -> int:
    """软删除所有已过期的临时文件（expires_at <= now）"""
    result = await db.execute(
        select(StoredFile).where(
            StoredFile.storage == "temporary",
            StoredFile.expires_at.isnot(None),
            StoredFile.expires_at <= now_utc(),
            StoredFile.deleted_at.is_(None),
        )
    )
    expired = result.scalars().all()
    for rec in expired:
        rec.deleted_at = now_utc()
    if expired:
        await db.flush()
    return len(expired)


async def cleanup_old_audit_logs(db: AsyncSession, retention_days: int = 90) -> int:
    """清理超过保留期限的审计日志

    Args:
        db: 数据库会话
        retention_days: 保留天数（默认 90 天，可通过环境变量配置）

    Returns:
        清理的日志条数
    """
    import os as _os
    retain_days = int(_os.getenv("IMAGE_PROVIDER_AUDIT_LOG_RETENTION_DAYS", str(retention_days)))
    cutoff = now_utc() - timedelta(days=retain_days)

    result = await db.execute(
        delete(AuditLog).where(AuditLog.time <= cutoff)
    )
    count = result.rowcount
    if count > 0:
        await db.flush()
    return count


def next_cleanup_at(reference: datetime) -> datetime:
    """计算下一次清理的时间点"""
    tz = reference.tzinfo or CHINA_TZ
    target = datetime.combine(reference.date(), time(hour=CLEANUP_HOUR), tzinfo=tz)
    if reference >= target:
        target += timedelta(days=1)
    return target


async def run_cleanup_if_due(db: AsyncSession) -> None:
    """到达清理时间时执行一次清理"""
    current = now_local()
    today = current.date()
    tz = current.tzinfo or CHINA_TZ
    cleanup_time = datetime.combine(today, time(hour=CLEANUP_HOUR), tzinfo=tz)
    last_cleanup = read_last_cleanup_date()

    if current >= cleanup_time and last_cleanup != today.isoformat():
        await cleanup_expired_temp_files(db)
        await cleanup_old_audit_logs(db)
        from server_auth import clear_used_nonces_async
        await clear_used_nonces_async(db)
        write_last_cleanup_date(today.isoformat())


async def cleanup_scheduler_loop(db_session_factory) -> None:
    """清理调度循环（后台 asyncio 任务运行，每天 CLEANUP_HOUR 触发）"""
    import asyncio
    import logging
    _log = logging.getLogger("imageprovider.cleanup")

    try:
        async with db_session_factory() as db:
            await run_cleanup_if_due(db)
    except Exception as exc:
        _log.error(f"cleanup startup check failed: {exc}")

    while not state.shutdown_event.is_set():
        current = now_local()
        target = next_cleanup_at(current)
        wait_seconds = max(1, int((target - current).total_seconds()))
        if state.shutdown_event.wait(wait_seconds):
            break
        try:
            async with db_session_factory() as db:
                cleaned = await cleanup_expired_temp_files(db)
                audit_cleaned = await cleanup_old_audit_logs(db)
                from server_auth import clear_used_nonces_async
                await clear_used_nonces_async(db)
                write_last_cleanup_date(now_local().date().isoformat())
                if cleaned > 0 or audit_cleaned > 0:
                    _log.info(f"cleaned up {cleaned} temp files, {audit_cleaned} audit logs")
        except Exception as exc:
            _log.error(f"cleanup scheduler failed: {exc}")
