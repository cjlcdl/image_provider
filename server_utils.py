import json
import mimetypes
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Optional
from urllib.parse import quote

import server_state as state
from config import FILE_ROUTE_PREFIX
from folder_index import folder_requires_password, get_folder


def sanitize_index_name(file_name: str) -> Optional[str]:
    safe_name = Path(file_name).name.strip()
    if not safe_name or safe_name in (".", ".."):
        return None
    return safe_name[:255]


def normalize_folder_id(folder_id_value: Any) -> Optional[str]:
    if not isinstance(folder_id_value, str):
        return None
    normalized = folder_id_value.strip()
    if not normalized or normalized.lower() == "root":
        return None
    return normalized


def folder_allows_direct_download(folder_id: Optional[str]) -> bool:
    if not folder_id:
        return True
    folder_record = get_folder(folder_id)
    if folder_record is None:
        return True
    if not folder_requires_password(folder_record):
        return True
    return bool(folder_record.get("allowDirectDownload"))


def build_content_disposition(disposition_mode: str, file_name: str) -> str:
    safe_name = sanitize_index_name(file_name) or "download"
    ascii_fallback = safe_name.encode("ascii", "ignore").decode("ascii")
    ascii_fallback = ascii_fallback.replace("\\", "_").replace('"', "_").strip()
    if not ascii_fallback:
        extension = extract_allowed_extension(safe_name) or ""
        ascii_fallback = "download{}".format(extension)

    encoded_name = quote(safe_name, safe="")
    return '{}; filename="{}"; filename*=UTF-8\'\'{}'.format(
        disposition_mode,
        ascii_fallback,
        encoded_name,
    )


def read_key_file_bytes(key_path: Path) -> bytes:
    key_bytes = key_path.read_bytes()
    if key_bytes.startswith(b"\xef\xbb\xbf"):
        return key_bytes[3:]
    return key_bytes


def now_local() -> datetime:
    return datetime.now().astimezone()


def is_valid_boundary(boundary: str) -> bool:
    if not boundary or len(boundary) > state.MAX_MULTIPART_BOUNDARY_LENGTH:
        return False
    allowed_chars = set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'()+_,-./:=?")
    return all(char in allowed_chars for char in boundary)


def safe_storage_path(root_path: Path, relative_path: str) -> Optional[Path]:
    pure_path = PurePosixPath(relative_path.strip("/"))
    if not pure_path.parts or ".." in pure_path.parts:
        return None

    base_path = root_path.resolve()
    target_path = (base_path / Path(*pure_path.parts)).resolve()
    try:
        target_path.relative_to(base_path)
    except ValueError:
        return None
    return target_path


def extract_allowed_extension(filename: str) -> Optional[str]:
    safe_name = Path(filename).name
    if not safe_name:
        return None

    extension = Path(safe_name).suffix.lower()
    if not extension:
        return None

    return extension


def infer_allowed_extension_from_content_type(content_type: str) -> Optional[str]:
    normalized_type = content_type.split(";", 1)[0].strip().lower()
    if not normalized_type:
        return None

    extension = state.CONTENT_TYPE_EXTENSION_OVERRIDES.get(normalized_type)
    if extension is None and normalized_type not in state.CONTENT_TYPE_EXTENSION_OVERRIDES:
        extension = mimetypes.guess_extension(normalized_type, strict=False)

    if extension == ".jpe":
        extension = ".jpg"

    if not extension:
        return None

    return extension


def get_uploaded_file_content_type(uploaded_file: Any) -> str:
    direct_type = getattr(uploaded_file, "type", None)
    if isinstance(direct_type, str) and direct_type.strip():
        return direct_type.strip()

    headers = getattr(uploaded_file, "headers", None)
    if headers is None:
        return ""

    header_value = None
    if hasattr(headers, "get"):
        header_value = headers.get("Content-Type")
    if isinstance(header_value, str) and header_value.strip():
        return header_value.strip()

    if hasattr(headers, "get_content_type"):
        content_type = headers.get_content_type()
        if isinstance(content_type, str) and content_type.strip() and content_type != "text/plain":
            return content_type.strip()

    return ""


def normalize_uploaded_filename(filename: Optional[str], content_type: str) -> str:
    safe_name = Path((filename or "").strip()).name
    if safe_name and safe_name not in (".", ".."):
        stem = Path(safe_name).stem.lower()
        suffix = Path(safe_name).suffix
        if stem not in state.FALLBACK_UPLOAD_FILENAME_PLACEHOLDERS or suffix:
            return safe_name

    fallback_extension = infer_allowed_extension_from_content_type(content_type) or ""
    return "{}{}".format(int(now_local().timestamp() * 1000), fallback_extension)


def stream_upload_to_path(source_stream: Any, target_path: Path) -> int:
    bytes_written = 0
    try:
        with target_path.open("wb") as target_file:
            while True:
                chunk = source_stream.read(state.UPLOAD_CHUNK_SIZE)
                if not chunk:
                    break
                bytes_written += len(chunk)
                if bytes_written > state.MAX_REQUEST_BYTES - 1024 * 1024:
                    raise ValueError("file too large")
                target_file.write(chunk)
    except Exception:
        if target_path.exists():
            target_path.unlink()
        raise

    return bytes_written


def is_inline_mime_type(mime_type: str) -> bool:
    return mime_type.startswith("image/") or mime_type.startswith("audio/") or mime_type.startswith("video/")


def build_audit_log_line(
    *,
    action_type: str,
    user: str,
    app_channel: str,
    indexed_name: str,
    file_path: str,
    client_ip: str,
    extra: Optional[Dict[str, Any]] = None,
) -> str:
    payload = {
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
    return json.dumps(payload, ensure_ascii=False)
