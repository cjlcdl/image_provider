import json
import mimetypes
import shutil
import time as unix_time
import uuid
from datetime import datetime, time, timedelta
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import server_state as state
from config import (
    AUDIT_LOG_FILE_PATH,
    CLEANUP_HOUR,
    FILE_ROUTE_PREFIX,
    IP_BLACKLIST,
    PERMANENT_TOKEN_MAX_AGE_SECONDS,
    RATE_LIMIT_MAX_REQUESTS,
    RATE_LIMIT_WINDOW_SECONDS,
    UPLOAD_SESSION_MAX_AGE_SECONDS,
    UPLOAD_SESSION_ROOT,
)
from server_utils import build_audit_log_line, extract_allowed_extension, now_local, safe_storage_path


def ensure_storage() -> None:
    state.TEMP_UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    state.PERMANENT_UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
    AUDIT_LOG_FILE_PATH.parent.mkdir(parents=True, exist_ok=True)
    UPLOAD_SESSION_ROOT.mkdir(parents=True, exist_ok=True)


def read_last_cleanup_date() -> Optional[str]:
    if not state.STATE_FILE.exists():
        return None
    return state.STATE_FILE.read_text(encoding="utf-8").strip() or None


def write_last_cleanup_date(cleanup_date: str) -> None:
    state.STATE_FILE.write_text(cleanup_date, encoding="utf-8")


def save_permanent_index() -> None:
    temp_index_file = state.PERMANENT_INDEX_FILE.with_suffix(".tmp")
    temp_index_file.write_text(
        json.dumps({"files": state.permanent_file_index}, ensure_ascii=False),
        encoding="utf-8",
    )
    temp_index_file.replace(state.PERMANENT_INDEX_FILE)


def load_permanent_index() -> None:
    if not state.PERMANENT_INDEX_FILE.exists():
        return

    try:
        payload = json.loads(state.PERMANENT_INDEX_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return

    records = payload.get("files", {}) if isinstance(payload, dict) else {}
    if not isinstance(records, dict):
        return

    with state.index_lock:
        state.permanent_file_index.clear()
        for relative_path, metadata in records.items():
            if isinstance(relative_path, str) and isinstance(metadata, dict):
                state.permanent_file_index[relative_path] = metadata


def clear_temporary_index() -> None:
    with state.index_lock:
        state.temporary_file_index.clear()


def upload_session_metadata_path(upload_id: str) -> Path:
    return UPLOAD_SESSION_ROOT / "{}.json".format(upload_id)


def upload_session_part_path(upload_id: str) -> Path:
    return UPLOAD_SESSION_ROOT / "{}.part".format(upload_id)


def remove_upload_session_files(upload_id: str) -> None:
    upload_session_metadata_path(upload_id).unlink(missing_ok=True)
    upload_session_part_path(upload_id).unlink(missing_ok=True)


def save_upload_session_record(record: Dict[str, Any]) -> None:
    upload_id = str(record["uploadId"])
    metadata_path = upload_session_metadata_path(upload_id)
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = metadata_path.with_suffix(".tmp")
    temp_path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
    temp_path.replace(metadata_path)


def load_upload_session_record(upload_id: str) -> Optional[Dict[str, Any]]:
    metadata_path = upload_session_metadata_path(upload_id)
    if not metadata_path.exists():
        return None

    try:
        record = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None

    if not isinstance(record, dict):
        return None

    if record.get("status") == "uploading":
        part_path = upload_session_part_path(upload_id)
        actual_size = part_path.stat().st_size if part_path.exists() else 0
        if int(record.get("uploadedSize", 0)) != actual_size:
            record["uploadedSize"] = actual_size
            record["updatedAt"] = now_local().isoformat()
            save_upload_session_record(record)

    return record


def is_upload_session_expired(record: Dict[str, Any]) -> bool:
    updated_at = record.get("updatedAt") or record.get("createdAt")
    if not isinstance(updated_at, str) or not updated_at:
        return True

    try:
        updated_at_value = datetime.fromisoformat(updated_at)
    except ValueError:
        return True

    age_seconds = (now_local() - updated_at_value).total_seconds()
    return age_seconds > UPLOAD_SESSION_MAX_AGE_SECONDS


def cleanup_expired_upload_sessions() -> int:
    ensure_storage()
    removed_count = 0
    for metadata_path in UPLOAD_SESSION_ROOT.glob("*.json"):
        try:
            record = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            record = None

        upload_id = metadata_path.stem
        if not isinstance(record, dict) or is_upload_session_expired(record):
            remove_upload_session_files(upload_id)
            removed_count += 1

    return removed_count


def build_upload_session_record(
    *,
    storage_type: str,
    indexed_name: str,
    system_name: str,
    relative_path: str,
    total_size: int,
    mime_type: str,
    folder_id: Optional[str] = None,
) -> Dict[str, Any]:
    timestamp = now_local().isoformat()
    return {
        "uploadId": uuid.uuid4().hex,
        "uploadToken": __import__("secrets").token_urlsafe(32),
        "status": "uploading",
        "storage": storage_type,
        "indexedName": indexed_name,
        "systemName": system_name,
        "relativePath": relative_path,
        "totalSize": total_size,
        "uploadedSize": 0,
        "mimeType": mime_type,
        "folderId": folder_id,
        "createdAt": timestamp,
        "updatedAt": timestamp,
    }


def get_index_store(storage_type: str) -> Dict[str, Dict[str, Any]]:
    if storage_type == "permanent":
        return state.permanent_file_index
    return state.temporary_file_index


def upsert_file_index_record(
    storage_type: str,
    relative_path: str,
    system_name: str,
    indexed_name: str,
    file_size: int,
    mime_type: str,
    folder_id: Optional[str] = None,
    uploaded_at: Optional[str] = None,
) -> Dict[str, Any]:
    existing_record = get_file_index_record(storage_type, relative_path) or {}
    record = {
        "indexedName": indexed_name,
        "systemName": system_name,
        "size": file_size,
        "mimeType": mime_type,
        "uploadedAt": uploaded_at or existing_record.get("uploadedAt") or now_local().isoformat(),
        "folderId": folder_id if folder_id is not None else existing_record.get("folderId"),
    }

    with state.index_lock:
        index_store = get_index_store(storage_type)
        index_store[relative_path] = record
        if storage_type == "permanent":
            save_permanent_index()

    return record


def remove_file_index_record(storage_type: str, relative_path: str) -> None:
    with state.index_lock:
        index_store = get_index_store(storage_type)
        index_store.pop(relative_path, None)
        if storage_type == "permanent":
            save_permanent_index()


def rename_file_index_record(storage_type: str, relative_path: str, indexed_name: str) -> Optional[Dict[str, Any]]:
    with state.index_lock:
        index_store = get_index_store(storage_type)
        record = index_store.get(relative_path)
        if record is None:
            return None
        record["indexedName"] = indexed_name
        if storage_type == "permanent":
            save_permanent_index()
        return dict(record)


def get_file_index_record(storage_type: str, relative_path: str) -> Optional[Dict[str, Any]]:
    with state.index_lock:
        record = get_index_store(storage_type).get(relative_path)
        if record is None:
            return None
        return dict(record)


def set_file_index_folder(storage_type: str, relative_path: str, folder_id: Optional[str]) -> Optional[Dict[str, Any]]:
    with state.index_lock:
        index_store = get_index_store(storage_type)
        record = index_store.get(relative_path)
        if record is None:
            return None
        record["folderId"] = folder_id
        if storage_type == "permanent":
            save_permanent_index()
        return dict(record)


def prune_missing_permanent_index_records() -> bool:
    removed = False
    with state.index_lock:
        stale_paths = []
        for relative_path in state.permanent_file_index.keys():
            resolved = resolve_relative_path(relative_path)
            if resolved is None or not resolved[1].exists():
                stale_paths.append(relative_path)

        for relative_path in stale_paths:
            state.permanent_file_index.pop(relative_path, None)
            removed = True

        if removed:
            save_permanent_index()

    return removed


def cleanup_uploaded_files() -> int:
    ensure_storage()
    removed_count = 0

    with state.cleanup_lock:
        for child in state.TEMP_UPLOAD_ROOT.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
                removed_count += 1
            else:
                child.unlink()
                removed_count += 1

        clear_used_nonces()
        clear_temporary_index()
        write_last_cleanup_date(now_local().date().isoformat())

    return removed_count


def cleanup_if_due() -> None:
    current = now_local()
    today = current.date()
    cleanup_time = datetime.combine(today, time(hour=CLEANUP_HOUR), tzinfo=current.tzinfo)
    last_cleanup = read_last_cleanup_date()

    if current >= cleanup_time and last_cleanup != today.isoformat():
        cleanup_uploaded_files()


def next_cleanup_at(reference: datetime) -> datetime:
    target = datetime.combine(reference.date(), time(hour=CLEANUP_HOUR), tzinfo=reference.tzinfo)
    if reference >= target:
        target += timedelta(days=1)
    return target


def cleanup_scheduler() -> None:
    try:
        cleanup_if_due()
    except Exception as exc:
        print("cleanup startup check failed: {}".format(exc))

    while not state.shutdown_event.is_set():
        current = now_local()
        target = next_cleanup_at(current)
        wait_seconds = max(1, int((target - current).total_seconds()))
        if state.shutdown_event.wait(wait_seconds):
            break
        try:
            cleanup_uploaded_files()
        except Exception as exc:
            print("cleanup scheduler failed: {}".format(exc))


def prune_used_nonces(reference_ts: Optional[int] = None) -> bool:
    if reference_ts is None:
        reference_ts = int(unix_time.time())

    expired_nonces = [
        nonce for nonce, expires_at in state.used_nonce_expirations.items() if expires_at <= reference_ts
    ]
    for nonce in expired_nonces:
        state.used_nonce_expirations.pop(nonce, None)
    return bool(expired_nonces)


def clear_used_nonces() -> None:
    with state.nonce_lock:
        state.used_nonce_expirations.clear()


def reserve_nonce(nonce: str) -> bool:
    current_ts = int(unix_time.time())
    with state.nonce_lock:
        prune_used_nonces(current_ts)
        expires_at = state.used_nonce_expirations.get(nonce)
        if expires_at is not None and expires_at > current_ts:
            return False
        state.used_nonce_expirations[nonce] = current_ts + PERMANENT_TOKEN_MAX_AGE_SECONDS
    return True


def is_ip_blacklisted(client_ip: str) -> bool:
    return client_ip in IP_BLACKLIST


def is_rate_limited(client_ip: str) -> bool:
    current_window = int(unix_time.time()) // RATE_LIMIT_WINDOW_SECONDS
    with state.rate_limit_lock:
        stale_ips = [
            ip for ip, bucket in state.upload_rate_windows.items() if bucket["window"] != current_window
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


def resolve_relative_path(relative_path: str) -> Optional[Tuple[str, Path, str]]:
    if not relative_path.startswith(FILE_ROUTE_PREFIX + "/"):
        return None

    route_path = relative_path[len(FILE_ROUTE_PREFIX) :].lstrip("/")
    if not route_path:
        return None

    if route_path.startswith("permanent/"):
        storage_type = "permanent"
        target_path = safe_storage_path(state.PERMANENT_UPLOAD_ROOT, route_path[len("permanent/") :])
    else:
        storage_type = "temporary"
        target_path = safe_storage_path(state.TEMP_UPLOAD_ROOT, route_path)

    if target_path is None:
        return None
    return storage_type, target_path, relative_path


def build_file_item(storage_type: str, relative_path: str, target_path: Path) -> Dict[str, Any]:
    mime_type = mimetypes.guess_type(target_path.name)[0] or "application/octet-stream"
    record = get_file_index_record(storage_type, relative_path) or {}
    indexed_name = record.get("indexedName") or target_path.name
    uploaded_at = record.get("uploadedAt")
    folder_id = record.get("folderId") if isinstance(record.get("folderId"), str) else None

    return {
        "indexedName": indexed_name,
        "systemName": target_path.name,
        "storage": storage_type,
        "size": target_path.stat().st_size,
        "mimeType": mime_type,
        "path": relative_path,
        "url": relative_path,
        "uploadedAt": uploaded_at,
        "folderId": folder_id,
    }


def list_all_files() -> list:
    prune_missing_permanent_index_records()
    files = []

    if state.TEMP_UPLOAD_ROOT.exists():
        for folder in sorted(state.TEMP_UPLOAD_ROOT.iterdir()):
            if not folder.is_dir():
                continue
            for child in sorted(folder.iterdir()):
                if not child.is_file():
                    continue
                relative_path = "{}/{}/{}".format(FILE_ROUTE_PREFIX, folder.name, child.name)
                files.append(build_file_item("temporary", relative_path, child))

    if state.PERMANENT_UPLOAD_ROOT.exists():
        for child in sorted(state.PERMANENT_UPLOAD_ROOT.iterdir()):
            if not child.is_file():
                continue
            relative_path = "{}/permanent/{}".format(FILE_ROUTE_PREFIX, child.name)
            files.append(build_file_item("permanent", relative_path, child))

    files.sort(key=lambda item: (item.get("storage", ""), item.get("path", "")))
    return files


def apply_file_filters(
    files: list,
    storage_filter: Optional[str] = None,
    keyword: Optional[str] = None,
    mime_type: Optional[str] = None,
    extension: Optional[str] = None,
    folder_id: Optional[str] = None,
) -> list:
    filtered_files = files

    if storage_filter:
        filtered_files = [item for item in filtered_files if item.get("storage") == storage_filter]

    if keyword:
        keyword_lower = keyword.lower()
        filtered_files = [
            item
            for item in filtered_files
            if keyword_lower in str(item.get("indexedName", "")).lower()
            or keyword_lower in str(item.get("systemName", "")).lower()
            or keyword_lower in str(item.get("path", "")).lower()
        ]

    if mime_type:
        filtered_files = [item for item in filtered_files if item.get("mimeType") == mime_type]

    if extension:
        normalized_extension = extension.lower().lstrip(".")
        filtered_files = [
            item
            for item in filtered_files
            if str(item.get("systemName", "")).lower().endswith("." + normalized_extension)
        ]

    if folder_id is not None:
        if folder_id == "root":
            filtered_files = [item for item in filtered_files if not item.get("folderId")]
        else:
            filtered_files = [item for item in filtered_files if item.get("folderId") == folder_id]

    return filtered_files


def paginate_files(files: list, page: int, page_size: int) -> Tuple[list, int]:
    total = len(files)
    start_index = (page - 1) * page_size
    end_index = start_index + page_size
    return files[start_index:end_index], total


def delete_file_by_relative_path(relative_path: str) -> Tuple[bool, Dict[str, Any]]:
    resolved = resolve_relative_path(relative_path)
    if resolved is None:
        return False, {"path": relative_path, "reason": "file not found"}

    storage_type, target_path, normalized_path = resolved
    if not target_path.exists() or not target_path.is_file():
        remove_file_index_record(storage_type, normalized_path)
        return False, {"path": normalized_path, "reason": "file not found"}

    target_path.unlink()
    remove_file_index_record(storage_type, normalized_path)
    if storage_type == "temporary" and target_path.parent.exists() and not any(target_path.parent.iterdir()):
        target_path.parent.rmdir()

    return True, {"path": normalized_path, "storage": storage_type}


def generate_storage_file_name(target_storage: str, extension: str) -> str:
    normalized_extension = ""
    if extension:
        normalized_extension = extension if extension.startswith(".") else "." + extension
    if target_storage == "permanent":
        return "{}_{}{}".format(int(unix_time.time()), uuid.uuid4().hex[:16], normalized_extension)
    return "{}{}".format(uuid.uuid4().hex, normalized_extension)


def build_relative_url_for_storage(target_storage: str, file_name: str) -> str:
    if target_storage == "permanent":
        return "{}/permanent/{}".format(FILE_ROUTE_PREFIX, file_name)
    folder_name = now_local().strftime("%Y%m%d")
    return "{}/{}/{}".format(FILE_ROUTE_PREFIX, folder_name, file_name)


def move_file_by_relative_path(relative_path: str, target_storage: str) -> Tuple[bool, Dict[str, Any]]:
    resolved = resolve_relative_path(relative_path)
    if resolved is None:
        return False, {"path": relative_path, "reason": "file not found"}

    source_storage, source_path, normalized_path = resolved
    if not source_path.exists() or not source_path.is_file():
        remove_file_index_record(source_storage, normalized_path)
        return False, {"path": normalized_path, "reason": "file not found"}

    if target_storage not in ("temporary", "permanent"):
        return False, {"path": normalized_path, "reason": "invalid target storage"}

    file_size = source_path.stat().st_size
    mime_type = mimetypes.guess_type(source_path.name)[0] or "application/octet-stream"
    indexed_record = get_file_index_record(source_storage, normalized_path) or {}
    indexed_name = indexed_record.get("indexedName") or source_path.name
    uploaded_at = indexed_record.get("uploadedAt") or now_local().isoformat()
    folder_id = indexed_record.get("folderId") if isinstance(indexed_record.get("folderId"), str) else None

    if source_storage == target_storage:
        return True, {
            "path": normalized_path,
            "sourceStorage": source_storage,
            "targetStorage": target_storage,
            "indexedName": indexed_name,
            "mimeType": mime_type,
            "size": file_size,
        }

    extension = Path(source_path.name).suffix or extract_allowed_extension(source_path.name) or ""

    target_file_name = generate_storage_file_name(target_storage, extension)
    target_relative_url = build_relative_url_for_storage(target_storage, target_file_name)
    target_resolved = resolve_relative_path(target_relative_url)
    if target_resolved is None:
        return False, {"path": normalized_path, "reason": "failed to resolve target path"}

    _resolved_storage, target_path, normalized_target_path = target_resolved
    target_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source_path), str(target_path))

    with state.index_lock:
        source_store = get_index_store(source_storage)
        target_store = get_index_store(target_storage)
        source_store.pop(normalized_path, None)
        target_store[normalized_target_path] = {
            "indexedName": indexed_name,
            "systemName": target_file_name,
            "size": file_size,
            "mimeType": mime_type,
            "uploadedAt": uploaded_at,
            "folderId": folder_id,
        }
        if source_storage == "permanent" or target_storage == "permanent":
            save_permanent_index()

    if source_storage == "temporary" and source_path.parent.exists() and not any(source_path.parent.iterdir()):
        source_path.parent.rmdir()

    return True, {
        "path": normalized_target_path,
        "sourceStorage": source_storage,
        "targetStorage": target_storage,
        "indexedName": indexed_name,
        "mimeType": mime_type,
        "size": file_size,
    }


def append_audit_log(log_line: str) -> None:
    with state.audit_log_lock:
        with AUDIT_LOG_FILE_PATH.open("a", encoding="utf-8") as file_obj:
            file_obj.write(log_line)
            file_obj.write("\n")
