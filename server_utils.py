"""
工具函数模块 v3.0
================
包含：
  - Base64URL 编解码（新链接格式 /p/{base64url}）
  - SHA-256 哈希计算（内容寻址 + 去重）
  - 文件名清洗、MIME 判断、Content-Disposition 构建
  - 续传分片路径管理
  - 请求头常量
"""

import base64
import hashlib
import json
import mimetypes
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Optional, Tuple
from urllib.parse import quote

from config import CHUNK_STORAGE_ROOT, FILE_ROUTE_PREFIX, MAX_UPLOAD_BYTES

# ---------------------------------------------------------------------------
# 请求头常量
# ---------------------------------------------------------------------------

APP_CHANNEL_HEADER = "APP_CHANNEL"             # 客户端渠道标识
USER_HEADER = "USER"                           # 用户标识
UPLOAD_SESSION_TOKEN_HEADER = "Upload-Token"   # 续传会话令牌
UPLOAD_OFFSET_HEADER = "Upload-Offset"         # 续传偏移量
FOLDER_PASSWORD_TOKEN_HEADER = "Folder-Password-Token"            # 文件夹密码证明
TARGET_FOLDER_PASSWORD_TOKEN_HEADER = "Target-Folder-Password-Token"  # 目标文件夹密码证明
FOLDER_PASSWORDS_TOKEN_HEADER = "Folder-Passwords-Token"          # 批量文件夹密码证明
DOWNLOAD_TOKEN_QUERY_PARAM = "downloadToken"   # 下载令牌查询参数名

# 正则：续传会话 ID（32 位 hex）
UPLOAD_SESSION_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
# 上传分块大小
UPLOAD_CHUNK_SIZE = 64 * 1024

# ---------------------------------------------------------------------------
# 时间工具
# ---------------------------------------------------------------------------

# 中国时区（UTC+8）
CHINA_TZ = timezone(timedelta(hours=8))


def now_local() -> datetime:
    """获取当前本地时间（中国时区）"""
    return datetime.now(CHINA_TZ)


def now_utc() -> datetime:
    """获取当前 UTC 时间（naive datetime，与 SQLAlchemy/SQLite DateTime 存储一致）"""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def format_utc_iso(dt: Optional[datetime]) -> Optional[str]:
    """将 naive UTC datetime 格式化为 ISO 8601 带时区字符串（如 2026-07-10T18:26:46Z）"""
    if dt is None:
        return None
    return dt.isoformat() + "Z"


# ---------------------------------------------------------------------------
# Base64URL 编解码（URL 安全，用于 /p/{base64url} 链接）
# ---------------------------------------------------------------------------

def base64url_encode(data: str) -> str:
    """将字符串编码为 Base64URL 格式（无填充，- 替代 +，_ 替代 /）

    用于生成新版文件访问链接：/p/{base64url(systemName)}
    """
    return base64.urlsafe_b64encode(data.encode("utf-8")).decode("ascii").rstrip("=")


def base64url_decode(encoded: str) -> str:
    """将 Base64URL 字符串解码为原始字符串

    自动补齐缺失的填充符 =。
    """
    # 补齐填充符（Base64 要求长度是 4 的倍数）
    padding = 4 - len(encoded) % 4
    if padding != 4:
        encoded += "=" * padding
    return base64.urlsafe_b64decode(encoded.encode("ascii")).decode("utf-8")


# ---------------------------------------------------------------------------
# SHA-256 哈希计算（内容寻址存储与去重）
# ---------------------------------------------------------------------------

def compute_sha256_hex(file_path: Path) -> str:
    """计算文件的 SHA-256 哈希值（返回 hex 字符串）

    用于内容寻址存储（CAS）和文件去重检测。
    采用 64KB 分块读取方式，避免大文件占用过多内存。
    """
    sha256_hash = hashlib.sha256()
    with file_path.open("rb") as f:
        while chunk := f.read(64 * 1024):
            sha256_hash.update(chunk)
    return sha256_hash.hexdigest()


# ---------------------------------------------------------------------------
# 内容寻址存储（CAS）路径工具
# ---------------------------------------------------------------------------

def build_cas_path(sha256_hex: str, extension: str) -> Tuple[Path, str]:
    """根据 SHA-256 哈希和扩展名构建内容寻址存储路径

    Args:
        sha256_hex: 文件的 SHA-256 哈希值（64 字符 hex）
        extension: 文件扩展名（含点号，如 ".apk"）

    Returns:
        (target_path, system_name) 元组
          - target_path: 完整物理路径（如 storage/files/ab/abc...ff.apk）
          - system_name: 系统文件名（如 "abc...ff.apk"）
    """
    from config import FILES_STORAGE_ROOT

    normalized_ext = extension
    if normalized_ext and not normalized_ext.startswith("."):
        normalized_ext = "." + normalized_ext

    system_name = f"{sha256_hex}{normalized_ext}"
    # 按哈希前 2 位分子目录，避免单目录文件数过多导致文件系统性能下降
    shard_dir = FILES_STORAGE_ROOT / sha256_hex[:2]
    target_path = shard_dir / system_name

    return target_path, system_name


def get_file_url(system_name: str) -> str:
    """根据系统文件名生成对外访问 URL（/p/{base64url} 格式）

    Args:
        system_name: 系统文件名（如 "abc...ff.apk"）

    Returns:
        对外 URL 路径（如 "/p/YWJjZGVmLi4uZmYK"）
    """
    return f"{FILE_ROUTE_PREFIX}/{base64url_encode(system_name)}"


def parse_file_url(url_path: str) -> Optional[str]:
    """从 /p/{base64url} 格式的 URL 中解析出系统文件名

    Args:
        url_path: 请求路径（如 "/p/YWJjZGVmLi4uZmYK"）

    Returns:
        系统文件名，解析失败返回 None
    """
    prefix = FILE_ROUTE_PREFIX + "/"
    if not url_path.startswith(prefix):
        return None

    encoded = url_path[len(prefix):]
    if not encoded:
        return None

    try:
        return base64url_decode(encoded)
    except (ValueError, UnicodeDecodeError):
        return None


# ---------------------------------------------------------------------------
# 续传分片路径管理
# ---------------------------------------------------------------------------

def upload_chunk_path(upload_id: str) -> Path:
    """获取续传分片的临时文件路径"""
    CHUNK_STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    return CHUNK_STORAGE_ROOT / f"{upload_id}.part"


def remove_chunk_file(upload_id: str) -> None:
    """删除续传分片临时文件"""
    chunk_file = upload_chunk_path(upload_id)
    chunk_file.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# 文件名清洗与扩展名提取
# ---------------------------------------------------------------------------

FALLBACK_UPLOAD_FILENAME_PLACEHOLDERS = {"upload"}
"""无文件名时的占位值集合"""

# Content-Type → 扩展名映射表（覆盖 mimetypes 的默认推断）
CONTENT_TYPE_EXTENSION_OVERRIDES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/gif": ".gif",
    "image/bmp": ".bmp",
    "image/webp": ".webp",
    "image/tiff": ".tiff",
    "application/zip": ".zip",
    "application/x-7z-compressed": ".7z",
    "application/vnd.rar": ".rar",
    "application/x-rar-compressed": ".rar",
    "application/x-iso9660-image": ".iso",
    "application/x-msdownload": ".exe",
    "application/x-msdos-program": ".exe",
    "application/vnd.android.package-archive": ".apk",
    "application/octet-stream": None,   # 无法推断，不分配扩展名
    "video/mp4": ".mp4",
    "video/x-matroska": ".mkv",
    "video/x-msvideo": ".avi",
    "audio/mpeg": ".mp3",
    "audio/ogg": ".ogg",
    "audio/flac": ".flac",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
}


def sanitize_index_name(file_name: str) -> Optional[str]:
    """清洗用户可见文件名：去首尾空格、去路径分隔符、截断到 255 字符

    Args:
        file_name: 原始文件名

    Returns:
        清洗后的文件名，无效时返回 None
    """
    safe_name = Path(file_name).name.strip()
    if not safe_name or safe_name in (".", ".."):
        return None
    return safe_name[:255]


def extract_extension(filename: str) -> str:
    """从文件名中提取扩展名（小写，含点号）

    Args:
        filename: 文件名

    Returns:
        扩展名（如 ".apk"），无扩展名时返回空字符串
    """
    safe_name = Path(filename).name
    if not safe_name:
        return ""
    suffix = Path(safe_name).suffix.lower()
    return suffix


def infer_extension_from_content_type(content_type: str) -> str:
    """根据 Content-Type 推断文件扩展名

    Args:
        content_type: MIME 类型字符串

    Returns:
        扩展名（如 ".apk"），无法推断时返回空字符串
    """
    normalized_type = content_type.split(";", 1)[0].strip().lower()
    if not normalized_type:
        return ""

    # 优先使用自定义映射表
    if normalized_type in CONTENT_TYPE_EXTENSION_OVERRIDES:
        ext = CONTENT_TYPE_EXTENSION_OVERRIDES[normalized_type]
        return ext if ext else ""

    # 回退到 mimetypes 库推断
    ext = mimetypes.guess_extension(normalized_type, strict=False)
    if ext == ".jpe":
        ext = ".jpg"
    return ext or ""


def normalize_uploaded_filename(filename: Optional[str], content_type: str) -> str:
    """标准化上传文件名：处理空文件名、占位名、回退生成文件名

    Args:
        filename: 客户端提供的原始文件名
        content_type: 文件的 Content-Type

    Returns:
        标准化后的文件名
    """
    safe_name = Path((filename or "").strip()).name
    # 有有效文件名（且不是占位名 "upload"），直接使用
    if safe_name and safe_name not in (".", ".."):
        stem = Path(safe_name).stem.lower()
        suffix = Path(safe_name).suffix
        if stem not in FALLBACK_UPLOAD_FILENAME_PLACEHOLDERS or suffix:
            return safe_name

    # 无有效文件名：根据 Content-Type 推断扩展名，使用时间戳生成回退名
    fallback_ext = infer_extension_from_content_type(content_type) or ""
    return f"{int(now_local().timestamp() * 1000)}{fallback_ext}"


# ---------------------------------------------------------------------------
# 文件夹相关工具
# ---------------------------------------------------------------------------

def normalize_folder_id(folder_id_value: Any) -> Optional[str]:
    """标准化文件夹 ID：去空白、"root" 转为空字符串

    Args:
        folder_id_value: 原始文件夹 ID 值

    Returns:
        标准化后的文件夹 ID（空字符串 "" 表示根目录），无效时返回 None
    """
    if not isinstance(folder_id_value, str):
        return None
    normalized = folder_id_value.strip()
    if not normalized or normalized.lower() == "root":
        return ""  # 空字符串表示根目录
    return normalized


# ---------------------------------------------------------------------------
# HTTP 响应工具
# ---------------------------------------------------------------------------

def build_content_disposition(disposition_mode: str, file_name: str) -> str:
    """构建 Content-Disposition 响应头值（支持中文文件名）

    使用 RFC 5987 filename*=UTF-8'' 编码支持非 ASCII 字符，
    同时提供 ASCII fallback 以兼容旧客户端。

    Args:
        disposition_mode: "inline"（浏览器内预览）或 "attachment"（强制下载）
        file_name: 文件名

    Returns:
        Content-Disposition 头值
    """
    safe_name = sanitize_index_name(file_name) or "download"
    # ASCII fallback：去除非 ASCII 字符
    ascii_fallback = safe_name.encode("ascii", "ignore").decode("ascii")
    ascii_fallback = ascii_fallback.replace("\\", "_").replace('"', "_").strip()
    if not ascii_fallback:
        extension = extract_extension(safe_name) or ""
        ascii_fallback = f"download{extension}"

    # RFC 5987 编码（支持中文等非 ASCII 字符）
    encoded_name = quote(safe_name, safe="")
    return f'{disposition_mode}; filename="{ascii_fallback}"; filename*=UTF-8\'\'{encoded_name}'


def is_inline_mime_type(mime_type: str) -> bool:
    """判断 MIME 类型是否适合浏览器内预览（inline）而非强制下载"""
    return (
        mime_type.startswith("image/")
        or mime_type.startswith("audio/")
        or mime_type.startswith("video/")
        or mime_type in ("application/pdf", "text/plain", "text/html")
    )


# ---------------------------------------------------------------------------
# 密钥文件读取（兼容 UTF-8 BOM）
# ---------------------------------------------------------------------------

def read_key_file_bytes(key_path: Path) -> bytes:
    """读取密钥文件内容，自动去除 UTF-8 BOM 头

    Windows 记事本编辑 PEM 文件后可能添加 BOM，需要兼容处理。
    """
    key_bytes = key_path.read_bytes()
    if key_bytes.startswith(b"\xef\xbb\xbf"):
        return key_bytes[3:]
    return key_bytes


# ---------------------------------------------------------------------------
# multipart/form-data 工具
# ---------------------------------------------------------------------------

def is_valid_boundary(boundary: str) -> bool:
    """验证 multipart 分隔符是否合法（长度和字符集检查）"""
    MAX_MULTIPART_BOUNDARY_LENGTH = 200
    if not boundary or len(boundary) > MAX_MULTIPART_BOUNDARY_LENGTH:
        return False
    allowed_chars = set(
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ'()+_,-./:=?"
    )
    return all(char in allowed_chars for char in boundary)


# ---------------------------------------------------------------------------
# 审计日志构建
# ---------------------------------------------------------------------------

def build_audit_log_json(
    *,
    action_type: str,
    user: str = "",
    app_channel: str = "",
    indexed_name: str = "",
    file_path: str = "",
    client_ip: str = "",
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """构建审计日志字典（用于入库）

    Args:
        action_type: 操作类型标识
        user: 操作者标识
        app_channel: 客户端渠道
        indexed_name: 关联的文件索引名
        file_path: 关联的文件路径
        client_ip: 客户端 IP 地址
        extra: 额外信息字典

    Returns:
        审计日志字典
    """
    payload: Dict[str, Any] = {
        "time": now_local().isoformat(),
        "user": user,
        "appChannel": app_channel,
        "actionType": action_type,
        "indexedName": indexed_name,
        "filePath": file_path,
        "clientIp": client_ip,
    }
    if extra:
        payload.update(extra)
    return payload


# ---------------------------------------------------------------------------
# 分块文件读取生成器（用于 StreamingResponse）
# ---------------------------------------------------------------------------

def file_chunk_generator(file_path: Path, chunk_size: int = 64 * 1024):
    """生成器：分块读取文件内容，用于 FastAPI StreamingResponse

    Args:
        file_path: 文件路径
        chunk_size: 每次读取的字节数（默认 64KB）
    """
    with file_path.open("rb") as f:
        while chunk := f.read(chunk_size):
            yield chunk

