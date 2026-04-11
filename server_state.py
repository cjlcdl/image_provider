import re
import threading
from typing import Any, Dict

from config import (
    AUDIT_LOG_FILE_PATH,
    MAX_UPLOAD_BYTES,
    PERMANENT_STORAGE_DIRNAME,
    STORAGE_ROOT,
    TEMPORARY_STORAGE_DIRNAME,
)


STATE_FILE = STORAGE_ROOT / ".cleanup_state"
PERMANENT_INDEX_FILE = STORAGE_ROOT / ".permanent_file_index.json"
TEMP_UPLOAD_ROOT = STORAGE_ROOT / TEMPORARY_STORAGE_DIRNAME
PERMANENT_UPLOAD_ROOT = STORAGE_ROOT / PERMANENT_STORAGE_DIRNAME
MAX_MULTIPART_BOUNDARY_LENGTH = 200
MAX_REQUEST_BYTES = MAX_UPLOAD_BYTES + 1024 * 1024
UPLOAD_CHUNK_SIZE = 64 * 1024
NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
UPLOAD_SESSION_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
MAX_JSON_BODY_BYTES = 16 * 1024
FALLBACK_UPLOAD_FILENAME_PLACEHOLDERS = {"upload"}
APP_CHANNEL_HEADER = "APP_CHANNEL"
USER_HEADER = "USER"
UPLOAD_SESSION_TOKEN_HEADER = "Upload-Token"
UPLOAD_OFFSET_HEADER = "Upload-Offset"
FOLDER_PASSWORD_TOKEN_HEADER = "Folder-Password-Token"
TARGET_FOLDER_PASSWORD_TOKEN_HEADER = "Target-Folder-Password-Token"
FOLDER_PASSWORDS_TOKEN_HEADER = "Folder-Passwords-Token"
DOWNLOAD_TOKEN_QUERY_PARAM = "downloadToken"

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
    "application/x-msdownload;format=dll": ".dll",
    "application/vnd.android.package-archive": ".apk",
    "application/octet-stream": None,
    "video/mp4": ".mp4",
    "video/x-matroska": ".mkv",
    "video/x-msvideo": ".avi",
    "audio/mpeg": ".mp3",
    "audio/ogg": ".ogg",
    "audio/flac": ".flac",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
}

cleanup_lock = threading.Lock()
shutdown_event = threading.Event()
nonce_lock = threading.Lock()
rate_limit_lock = threading.Lock()
index_lock = threading.RLock()
audit_log_lock = threading.Lock()
upload_session_lock = threading.RLock()
permanent_private_key = None
permanent_private_key_error = None
used_nonce_expirations: Dict[str, int] = {}
upload_rate_windows: Dict[str, Dict[str, int]] = {}
temporary_file_index: Dict[str, Dict[str, Any]] = {}
permanent_file_index: Dict[str, Dict[str, Any]] = {}
