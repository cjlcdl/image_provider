"""
全局配置 — 所有配置项通过环境变量读取，提供合理默认值
====================================================
v3.0 变更：
  - 新增数据库路径与备份相关配置
  - FILE_ROUTE_PREFIX 默认值从 /images 改为 /p
  - 废弃 AUDIT_LOG_FILE_PATH / FOLDER_INDEX_FILE_PATH / UPLOAD_SESSION_ROOT
  - 新增内容寻址存储根目录 FILES_STORAGE_ROOT
  - 新增续传分片目录 CHUNK_STORAGE_ROOT
"""

import os
from pathlib import Path


# ── 项目根目录 ─────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent

# ── 服务监听 ───────────────────────────────────────────────────
HOST = os.getenv("IMAGE_PROVIDER_HOST", "0.0.0.0")
PORT = int(os.getenv("IMAGE_PROVIDER_PORT", "8080"))
PUBLIC_BASE_URL = os.getenv("IMAGE_PROVIDER_PUBLIC_BASE_URL", "http://127.0.0.1:8080").strip().rstrip("/")

# ── 上传限制 ───────────────────────────────────────────────────
MAX_UPLOAD_BYTES = int(
    os.getenv("IMAGE_PROVIDER_MAX_UPLOAD_BYTES", str(4 * 1024 * 1024 * 1024))
)

# ── 文件访问 URL 前缀（新版默认 /p，替代旧版 /images）─────────
FILE_ROUTE_PREFIX = os.getenv(
    "IMAGE_PROVIDER_FILE_ROUTE_PREFIX",
    os.getenv("IMAGE_PROVIDER_IMAGE_ROUTE_PREFIX", "/p"),  # 兼容旧环境变量名
).rstrip("/") or "/p"

# ── 存储根目录 ─────────────────────────────────────────────────
STORAGE_ROOT = Path(os.getenv("IMAGE_PROVIDER_STORAGE_ROOT", BASE_DIR / "storage"))

# ── 内容寻址存储（CAS）：物理文件存放目录 ─────────────────────
#     文件按 sha256 前 2 位分片存储：storage/files/ab/abcdef...123.ext
FILES_STORAGE_ROOT = Path(
    os.getenv("IMAGE_PROVIDER_FILES_STORAGE_ROOT", STORAGE_ROOT / "files")
)

# ── 续传分片临时目录 ───────────────────────────────────────────
#     替代旧版 .upload_sessions/ 目录
CHUNK_STORAGE_ROOT = Path(
    os.getenv("IMAGE_PROVIDER_CHUNK_STORAGE_ROOT", STORAGE_ROOT / ".chunks")
)

# ── 数据库 ─────────────────────────────────────────────────────
#     SQLite 数据库固定路径（不可通过环境变量修改）
DB_PATH = str(STORAGE_ROOT / "metadata.db")

# ── 数据库自动备份 ─────────────────────────────────────────────
#     备份存放目录
DB_BACKUP_DIR = os.getenv(
    "IMAGE_PROVIDER_DB_BACKUP_DIR", str(STORAGE_ROOT / ".db_backups")
)
#     最大保留备份份数
DB_BACKUP_MAX_COUNT = int(os.getenv("IMAGE_PROVIDER_DB_BACKUP_MAX_COUNT", "48"))
#     备份间隔（分钟）
DB_BACKUP_INTERVAL_MINUTES = int(
    os.getenv("IMAGE_PROVIDER_DB_BACKUP_INTERVAL_MINUTES", "60")
)

# ── 临时文件每日清理时间 ───────────────────────────────────────
CLEANUP_HOUR = int(os.getenv("IMAGE_PROVIDER_CLEANUP_HOUR", "6"))

# ── 续传会话过期时间（秒）──────────────────────────────────────
UPLOAD_SESSION_MAX_AGE_SECONDS = int(
    os.getenv("IMAGE_PROVIDER_UPLOAD_SESSION_MAX_AGE_SECONDS", str(7 * 24 * 60 * 60))
)
#     续传建议分片大小（供客户端参考）
RESUMABLE_UPLOAD_CHUNK_SIZE_HINT = int(
    os.getenv("IMAGE_PROVIDER_RESUMABLE_UPLOAD_CHUNK_SIZE_HINT", str(4 * 1024 * 1024))
)

# ── 下载令牌最大有效天数 ───────────────────────────────────────
DOWNLOAD_TOKEN_MAX_DAYS = int(
    os.getenv("IMAGE_PROVIDER_DOWNLOAD_TOKEN_MAX_DAYS", "30")
)

# ── 管理鉴权 ───────────────────────────────────────────────────
PERMANENT_TOKEN_HEADER = "Courage-Token"
PERMANENT_TOKEN_MAX_AGE_SECONDS = 300  # 令牌有效期 5 分钟

# ── RSA 密钥路径 ───────────────────────────────────────────────
KEYS_ROOT = Path(os.getenv("IMAGE_PROVIDER_KEYS_ROOT", BASE_DIR / "keys"))
PERMANENT_TOKEN_PUBLIC_KEY_PATH = Path(
    os.getenv("IMAGE_PROVIDER_PUBLIC_KEY_PATH", KEYS_ROOT / "permanent_public.pem")
)
PERMANENT_TOKEN_PRIVATE_KEY_PATH = Path(
    os.getenv("IMAGE_PROVIDER_PRIVATE_KEY_PATH", KEYS_ROOT / "permanent_private.pem")
)

# ── 频率限制 ───────────────────────────────────────────────────
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("IMAGE_PROVIDER_RATE_LIMIT_WINDOW_SECONDS", "60"))
RATE_LIMIT_MAX_REQUESTS = int(os.getenv("IMAGE_PROVIDER_RATE_LIMIT_MAX_REQUESTS", "30"))
IP_BLACKLIST = {
    item.strip()
    for item in os.getenv("IMAGE_PROVIDER_IP_BLACKLIST", "").split(",")
    if item.strip()
}

