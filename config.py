import os
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
HOST = os.getenv("IMAGE_PROVIDER_HOST", "0.0.0.0")
PORT = int(os.getenv("IMAGE_PROVIDER_PORT", "8080"))
PUBLIC_BASE_URL = os.getenv("IMAGE_PROVIDER_PUBLIC_BASE_URL", "https://127.0.0.1/").strip().rstrip("/")
MAX_UPLOAD_BYTES = int(
    os.getenv("IMAGE_PROVIDER_MAX_UPLOAD_BYTES", str(4 * 1024 * 1024 * 1024))
)
FILE_ROUTE_PREFIX = os.getenv(
    "IMAGE_PROVIDER_FILE_ROUTE_PREFIX",
    os.getenv("IMAGE_PROVIDER_IMAGE_ROUTE_PREFIX", "/images"),
).rstrip("/") or "/images"
STORAGE_ROOT = Path(os.getenv("IMAGE_PROVIDER_STORAGE_ROOT", BASE_DIR / "storage"))
CLEANUP_HOUR = int(os.getenv("IMAGE_PROVIDER_CLEANUP_HOUR", "6"))
AUDIT_LOG_FILE_PATH = Path(os.getenv("IMAGE_PROVIDER_AUDIT_LOG_FILE_PATH", BASE_DIR / "logs" / "audit.log"))
FOLDER_INDEX_FILE_PATH = Path(
    os.getenv("IMAGE_PROVIDER_FOLDER_INDEX_FILE_PATH", STORAGE_ROOT / ".folder_index.json")
)
UPLOAD_SESSION_ROOT = Path(
    os.getenv("IMAGE_PROVIDER_UPLOAD_SESSION_ROOT", STORAGE_ROOT / ".upload_sessions")
)
UPLOAD_SESSION_MAX_AGE_SECONDS = int(
    os.getenv("IMAGE_PROVIDER_UPLOAD_SESSION_MAX_AGE_SECONDS", str(7 * 24 * 60 * 60))
)
RESUMABLE_UPLOAD_CHUNK_SIZE_HINT = int(
    os.getenv("IMAGE_PROVIDER_RESUMABLE_UPLOAD_CHUNK_SIZE_HINT", str(4 * 1024 * 1024))
)
DOWNLOAD_TOKEN_MAX_DAYS = int(
    os.getenv("IMAGE_PROVIDER_DOWNLOAD_TOKEN_MAX_DAYS", "30")
)

TEMPORARY_STORAGE_DIRNAME = "temporary"
PERMANENT_STORAGE_DIRNAME = "permanent"
PERMANENT_TOKEN_HEADER = "Courage-Token"
PERMANENT_TOKEN_MAX_AGE_SECONDS = 300
KEYS_ROOT = Path(os.getenv("IMAGE_PROVIDER_KEYS_ROOT", BASE_DIR / "keys"))
PERMANENT_TOKEN_PUBLIC_KEY_PATH = Path(
    os.getenv("IMAGE_PROVIDER_PUBLIC_KEY_PATH", KEYS_ROOT / "permanent_public.pem")
)
PERMANENT_TOKEN_PRIVATE_KEY_PATH = Path(
    os.getenv("IMAGE_PROVIDER_PRIVATE_KEY_PATH", KEYS_ROOT / "permanent_private.pem")
)
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("IMAGE_PROVIDER_RATE_LIMIT_WINDOW_SECONDS", "60"))
RATE_LIMIT_MAX_REQUESTS = int(os.getenv("IMAGE_PROVIDER_RATE_LIMIT_MAX_REQUESTS", "30"))
IP_BLACKLIST = {
    item.strip()
    for item in os.getenv("IMAGE_PROVIDER_IP_BLACKLIST", "").split(",")
    if item.strip()
}
