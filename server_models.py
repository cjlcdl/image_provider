"""
数据模型定义 — SQLAlchemy ORM 模型
===================================
包含五个核心表：
  - StoredFile    : 文件元数据（核心表）
  - Folder        : 虚拟文件夹树
  - DownloadToken : 受保护文件的临时下载直链令牌
  - UploadSession : 断点续传上传会话
  - AuditLog      : 审计日志

架构原则：
  - 元数据与数据分离：文件属性全部入库，文件内容存于文件系统（CAS 内容寻址）
  - 软删除机制：deleted_at 标记删除，回收站功能由客户端实现
  - 12 位短字符串 file_id，由自增整数 base62 编码生成
"""

import string
from datetime import datetime
from typing import List, Optional

from sqlalchemy import (
    BigInteger,
    Boolean,
    Column,
    DateTime,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    event,
)
from sqlalchemy.orm import declarative_base

# ---------------------------------------------------------------------------
# Base62 编码工具（用于生成短文件 ID）
# ---------------------------------------------------------------------------

BASE62_ALPHABET = string.digits + string.ascii_lowercase + string.ascii_uppercase
"""Base62 字符集：0-9 a-z A-Z，共 62 个字符，适合 URL 安全场景"""


def base62_encode(num: int) -> str:
    """将整数编码为 Base62 字符串"""
    if num == 0:
        return BASE62_ALPHABET[0]
    chars: List[str] = []
    while num > 0:
        num, rem = divmod(num, 62)
        chars.append(BASE62_ALPHABET[rem])
    return "".join(reversed(chars))


def base62_decode(encoded: str) -> int:
    """将 Base62 字符串解码为整数"""
    num = 0
    for char in encoded:
        num = num * 62 + BASE62_ALPHABET.index(char)
    return num


# ---------------------------------------------------------------------------
# ORM 基类
# ---------------------------------------------------------------------------

Base = declarative_base()


# ---------------------------------------------------------------------------
# 文件元数据表 — stored_files
# ---------------------------------------------------------------------------

class StoredFile(Base):
    """文件元数据表

    存储所有文件的属性信息，与物理文件内容完全分离。
    物理文件存储在 storage/files/{sha256前2位}/{sha256}.{ext}（内容寻址存储）。
    """

    __tablename__ = "stored_files"

    # ── 主键与标识 ─────────────────────────────────────────────
    # 内部自增整数主键（用于 base62 生成 file_id）
    id = Column(Integer, primary_key=True, autoincrement=True)
    # 12 位公开短 ID，由 base62_encode(id) 零填充生成（如 "00000000000a"）
    # nullable=True: INSERT 时暂时为空，after_insert 事件立即回填；unique 保证完整性
    file_id = Column(String(12), unique=True, nullable=True, index=True)

    # ── 文件名（用户可见 vs 系统物理名）─────────────────────────
    # 用户可见的文件名（含扩展名），如 "安装包.apk"
    indexed_name = Column(String(255), nullable=False)
    # 系统文件名（SHA256 哈希.扩展名），如 "a1b2c3...ff.apk"
    system_name = Column(String(512), nullable=False)

    # ── 存储属性 ──────────────────────────────────────────────
    # 存储类型：temporary（临时）或 permanent（永久）
    storage = Column(String(16), nullable=False, default="temporary")
    # 文件大小（字节）
    size = Column(BigInteger, nullable=False, default=0)
    # MIME 类型
    mime_type = Column(String(128), nullable=False, default="application/octet-stream")
    # SHA-256 哈希值（64 位 hex 字符串），用于去重和完整性校验
    sha256 = Column(String(64), nullable=False)
    # 文件扩展名（含点号，如 ".apk"），用于同文件夹唯一性约束
    extension = Column(String(32), nullable=False, default="")

    # ── 目录归属 ──────────────────────────────────────────────
    # 所属文件夹 ID（空字符串 "" 表示根目录，不走外键以保持灵活性）
    folder_id = Column(String(36), nullable=False, default="")

    # ── 来源审计 ──────────────────────────────────────────────
    # 上传者标识（来自 USER 请求头）
    uploaded_by = Column(String(128), nullable=True)
    # 上传渠道（来自 APP_CHANNEL 请求头）
    app_channel = Column(String(64), nullable=True)

    # ── 时间戳 ────────────────────────────────────────────────
    # 创建（上传完成）时间
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # 最后访问（下载）时间
    last_accessed_at = Column(DateTime, nullable=True)

    # ── 软删除与过期 ──────────────────────────────────────────
    # 软删除标记时间（NULL 表示未删除）
    deleted_at = Column(DateTime, nullable=True)
    # 过期时间（临时文件定时清理使用，永久文件为 NULL）
    expires_at = Column(DateTime, nullable=True)

    # ── 访问统计 ──────────────────────────────────────────────
    # 累计下载/访问次数
    access_count = Column(Integer, nullable=False, default=0)

    # ── 表级约束与索引 ────────────────────────────────────────
    __table_args__ = (
        Index("idx_stored_files_storage", "storage"),
        Index("idx_stored_files_folder", "folder_id"),
        Index("idx_stored_files_sha256", "sha256"),
        Index("idx_stored_files_deleted", "deleted_at"),
        Index("idx_stored_files_expires", "expires_at"),
        # 同文件夹下同扩展名不允许重名（模拟真实文件系统行为）
        UniqueConstraint(
            "indexed_name",
            "folder_id",
            "extension",
            name="uq_name_folder_ext",
        ),
    )


# ---------------------------------------------------------------------------
# file_id 自动生成（after_insert 事件）
# ---------------------------------------------------------------------------

@event.listens_for(StoredFile, "after_insert")
def _generate_stored_file_id(mapper, connection, target: StoredFile) -> None:
    """在 StoredFile 插入后，根据自增 id 生成 12 位 base62 file_id

    使用 after_insert 而非 before_insert 是因为 SQLite 的自增 id
    只有在实际 INSERT 之后才可用。生成后回写 file_id 列。
    """
    if not target.file_id:
        # 将自增 id 转为 12 位零填充的 base62 字符串
        file_id = base62_encode(target.id).rjust(12, "0")
        connection.execute(
            StoredFile.__table__.update()
            .where(StoredFile.__table__.c.id == target.id)
            .values(file_id=file_id)
        )
        target.file_id = file_id


# ---------------------------------------------------------------------------
# 虚拟文件夹表 — folders
# ---------------------------------------------------------------------------

class Folder(Base):
    """虚拟文件夹表

    支持多级嵌套（通过 parent_id 自引用）、密码加密保护。
    visibility: public=公开下载 / private=需Courage-Token / encrypted=Token+密码
    """

    __tablename__ = "folders"

    # 文件夹 UUID（hex 格式，36 字符）
    id = Column(String(36), primary_key=True)
    # 文件夹名称（最多 120 字符，不含 / \\）
    name = Column(String(120), nullable=False)
    # 父文件夹 ID（NULL 表示根级文件夹）
    parent_id = Column(String(36), nullable=True)
    # 可见性：public / private / encrypted（新增，优先于 encrypted 字段）
    visibility = Column(String(16), nullable=False, default="public")
    # 是否加密（兼容旧逻辑，visibility=encrypted 时生效）
    encrypted = Column(Boolean, nullable=False, default=False)
    # PBKDF2 密码盐值（Base64 编码，仅加密文件夹使用）
    password_salt = Column(String(32), nullable=True)
    # PBKDF2 密码哈希（Base64 编码，仅加密文件夹使用）
    password_hash = Column(String(128), nullable=True)
    # 是否允许直接下载（兼容旧逻辑）
    allow_direct_download = Column(Boolean, nullable=False, default=True)
    # 创建时间
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # 最后更新时间
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        Index("idx_folders_parent", "parent_id"),
    )


# ---------------------------------------------------------------------------
# 下载令牌表 — download_tokens
# ---------------------------------------------------------------------------

class DownloadToken(Base):
    """下载令牌表

    用于受保护文件（加密文件夹内且不允许直接下载）的临时下载直链。
    令牌有过期时间，过期后自动失效。
    """

    __tablename__ = "download_tokens"

    # 令牌值（secrets.token_urlsafe(32)，约 43 字符）
    token = Column(String(64), primary_key=True)
    # 关联的文件 URL 路径（如 /p/xxx）
    file_path = Column(String(512), nullable=False)
    # 关联的文件夹 ID
    folder_id = Column(String(36), nullable=False, default="")
    # 过期时间
    expires_at = Column(DateTime, nullable=False)
    # 创建时间
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # 使用时间（NULL=未使用，一次性令牌：使用后标记时间戳）
    used_at = Column(DateTime, nullable=True)

    __table_args__ = (
        Index("idx_download_tokens_expires", "expires_at"),
    )


# ---------------------------------------------------------------------------
# 分享链接表 — share_links
# ---------------------------------------------------------------------------

class ShareLink(Base):
    """分享链接表

    为 private/encrypted 文件夹或文件创建有时效的公开下载链接。
    """

    __tablename__ = "share_links"

    id = Column(String(36), primary_key=True)
    # URL 安全随机令牌（用于 /s/{token} 公开访问）
    token = Column(String(64), unique=True, nullable=False, index=True)
    # 资源类型：file / folder
    resource_type = Column(String(8), nullable=False)
    # 文件路径（resource_type=file 时）
    file_path = Column(String(512), nullable=True)
    # 文件夹 ID（resource_type=folder 时）
    folder_id = Column(String(36), nullable=True)
    # 创建者标识
    created_by = Column(String(128), nullable=True)
    # 过期时间
    expires_at = Column(DateTime, nullable=False)
    # 撤销时间（NULL=有效）
    revoked_at = Column(DateTime, nullable=True)
    # 创建时间
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # 访问次数
    access_count = Column(Integer, nullable=False, default=0)

    __table_args__ = (
        Index("idx_share_links_token", "token"),
        Index("idx_share_links_expires", "expires_at"),
    )


# ---------------------------------------------------------------------------
# 上传会话表 — upload_sessions
# ---------------------------------------------------------------------------

class UploadSession(Base):
    """上传会话表（断点续传）

    替代原 .upload_sessions/*.json 的磁盘文件持久化方案。
    分片数据仍写入磁盘（storage/.chunks/），元数据入库。
    """

    __tablename__ = "upload_sessions"

    # 会话 ID（UUID hex，32 字符）
    upload_id = Column(String(32), primary_key=True)
    # 会话鉴权令牌（上传分片时验证）
    upload_token = Column(String(64), nullable=False)
    # 会话状态：uploading / completed / cancelled
    status = Column(String(16), nullable=False, default="uploading")
    # 存储类型：temporary / permanent
    storage = Column(String(16), nullable=False)
    # 用户可见文件名
    indexed_name = Column(String(255), nullable=False)
    # 系统物理文件名（hash.ext）
    system_name = Column(String(512), nullable=False)
    # 相对 URL 路径（如 /p/xxx）
    relative_path = Column(String(512), nullable=False)
    # 文件总大小
    total_size = Column(BigInteger, nullable=False, default=0)
    # 已上传大小
    uploaded_size = Column(BigInteger, nullable=False, default=0)
    # MIME 类型
    mime_type = Column(String(128), nullable=False, default="application/octet-stream")
    # 目标文件夹 ID
    folder_id = Column(String(36), nullable=True)
    # 创建时间
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # 最后更新时间
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # 会话过期时间
    expires_at = Column(DateTime, nullable=False)

    __table_args__ = (
        Index("idx_upload_sessions_status", "status"),
        Index("idx_upload_sessions_expires", "expires_at"),
    )


# ---------------------------------------------------------------------------
# 审计日志表 — audit_logs
# ---------------------------------------------------------------------------

class AuditLog(Base):
    """审计日志表

    替代原 logs/audit.log 文本文件追加方案。
    支持按时间、用户、操作类型等维度查询。
    """

    __tablename__ = "audit_logs"

    # 自增主键
    id = Column(Integer, primary_key=True, autoincrement=True)
    # 操作时间
    time = Column(DateTime, nullable=False, default=datetime.utcnow)
    # 操作者标识（来自 USER 请求头）
    user = Column(String(128), nullable=False, default="")
    # 操作渠道（来自 APP_CHANNEL 请求头）
    app_channel = Column(String(64), nullable=False, default="")
    # 操作类型（upload_file / download_file / delete_file / create_folder 等）
    action_type = Column(String(32), nullable=False)
    # 关联的文件索引名
    indexed_name = Column(String(255), nullable=False, default="")
    # 关联的文件路径
    file_path = Column(String(512), nullable=False, default="")
    # 客户端 IP
    client_ip = Column(String(45), nullable=False, default="")
    # 额外信息（JSON 字符串，存储操作相关的扩展字段）
    extra_json = Column(Text, nullable=True)

    __table_args__ = (
        Index("idx_audit_logs_time", "time"),
        Index("idx_audit_logs_action", "action_type"),
        Index("idx_audit_logs_user", "user"),
    )


# ---------------------------------------------------------------------------
# Nonce 防重放表 — used_nonces
# ---------------------------------------------------------------------------

class UsedNonce(Base):
    """Nonce 防重放表

    持久化存储已使用的 nonce，解决进程重启后 nonce 丢失和多 worker 共享问题。
    每个 nonce 有过期时间，过期后由清理任务自动删除。
    """

    __tablename__ = "used_nonces"

    # nonce 值（主键）
    nonce = Column(String(64), primary_key=True)
    # 过期时间（超过此时间的 nonce 可被清理）
    expires_at = Column(DateTime, nullable=False)
    # 使用时间
    used_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        Index("idx_used_nonces_expires", "expires_at"),
    )
