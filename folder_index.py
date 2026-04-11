import base64
import hashlib
import hmac
import json
import secrets
import threading
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

from config import DOWNLOAD_TOKEN_MAX_DAYS, FOLDER_INDEX_FILE_PATH, STORAGE_ROOT


folder_index_lock = threading.RLock()
folder_records: Dict[str, Dict[str, Any]] = {}
download_tokens: Dict[str, Dict[str, Any]] = {}
PASSWORD_HASH_ITERATIONS = 200000


def now_local() -> datetime:
    return datetime.now().astimezone()


def ensure_folder_index_storage() -> None:
    STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
    FOLDER_INDEX_FILE_PATH.parent.mkdir(parents=True, exist_ok=True)


def sanitize_folder_name(folder_name: str) -> Optional[str]:
    normalized = " ".join(folder_name.strip().split())
    if not normalized or normalized in (".", ".."):
        return None
    if "/" in normalized or "\\" in normalized:
        return None
    return normalized[:120]


def _serialize_state() -> Dict[str, Any]:
    _prune_expired_download_tokens_locked()
    return {
        "folders": folder_records,
        "downloadTokens": download_tokens,
    }


def save_folder_index_state() -> None:
    ensure_folder_index_storage()
    temp_path = FOLDER_INDEX_FILE_PATH.with_suffix(".tmp")
    with folder_index_lock:
        temp_path.write_text(
            json.dumps(_serialize_state(), ensure_ascii=False),
            encoding="utf-8",
        )
        temp_path.replace(FOLDER_INDEX_FILE_PATH)


def load_folder_index_state() -> None:
    ensure_folder_index_storage()
    if not FOLDER_INDEX_FILE_PATH.exists():
        return

    try:
        payload = json.loads(FOLDER_INDEX_FILE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return

    loaded_folders = payload.get("folders", {}) if isinstance(payload, dict) else {}
    loaded_tokens = payload.get("downloadTokens", {}) if isinstance(payload, dict) else {}
    if not isinstance(loaded_folders, dict):
        loaded_folders = {}
    if not isinstance(loaded_tokens, dict):
        loaded_tokens = {}

    with folder_index_lock:
        folder_records.clear()
        download_tokens.clear()
        for folder_id, record in loaded_folders.items():
            if isinstance(folder_id, str) and isinstance(record, dict):
                folder_records[folder_id] = dict(record)
        for token, record in loaded_tokens.items():
            if isinstance(token, str) and isinstance(record, dict):
                download_tokens[token] = dict(record)
        _prune_expired_download_tokens_locked()


def _generate_password_hash(password: str, salt_bytes: Optional[bytes] = None) -> Dict[str, str]:
    actual_salt = salt_bytes or secrets.token_bytes(16)
    derived = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        actual_salt,
        PASSWORD_HASH_ITERATIONS,
    )
    return {
        "passwordSalt": base64.b64encode(actual_salt).decode("ascii"),
        "passwordHash": base64.b64encode(derived).decode("ascii"),
    }


def folder_requires_password(folder_record: Optional[Dict[str, Any]]) -> bool:
    return bool(folder_record and folder_record.get("encrypted"))


def verify_folder_password(folder_record: Dict[str, Any], password: str) -> bool:
    salt = folder_record.get("passwordSalt")
    expected_hash = folder_record.get("passwordHash")
    if not isinstance(salt, str) or not isinstance(expected_hash, str):
        return False
    try:
        salt_bytes = base64.b64decode(salt.encode("ascii"), validate=True)
    except (ValueError, UnicodeEncodeError):
        return False
    calculated = _generate_password_hash(password, salt_bytes=salt_bytes)
    return hmac.compare_digest(expected_hash, calculated["passwordHash"])


def export_folder_record(folder_record: Dict[str, Any]) -> Dict[str, Any]:
    folder_id = str(folder_record.get("id", ""))
    return {
        "id": folder_id,
        "name": str(folder_record.get("name", "")),
        "parentId": folder_record.get("parentId"),
        "encrypted": bool(folder_record.get("encrypted")),
        "allowDirectDownload": bool(folder_record.get("allowDirectDownload")),
        "createdAt": folder_record.get("createdAt"),
        "updatedAt": folder_record.get("updatedAt"),
        "path": build_folder_path(folder_id),
        "depth": len(build_folder_name_chain(folder_id)),
    }


def list_folders() -> List[Dict[str, Any]]:
    with folder_index_lock:
        exported = [export_folder_record(record) for record in folder_records.values()]
    exported.sort(key=lambda item: (str(item.get("path", "")), str(item.get("name", ""))))
    return exported


def get_folder(folder_id: Optional[str]) -> Optional[Dict[str, Any]]:
    if not folder_id:
        return None
    with folder_index_lock:
        record = folder_records.get(folder_id)
        if record is None:
            return None
        return dict(record)


def folder_exists(folder_id: Optional[str]) -> bool:
    if not folder_id:
        return True
    with folder_index_lock:
        return folder_id in folder_records


def build_folder_name_chain(folder_id: Optional[str]) -> List[str]:
    if not folder_id:
        return []

    names: List[str] = []
    current_id = folder_id
    seen_ids = set()
    with folder_index_lock:
        while current_id:
            if current_id in seen_ids:
                break
            seen_ids.add(current_id)
            record = folder_records.get(current_id)
            if record is None:
                break
            names.append(str(record.get("name", "")))
            parent_id = record.get("parentId")
            current_id = parent_id if isinstance(parent_id, str) and parent_id else None
    names.reverse()
    return names


def build_folder_path(folder_id: Optional[str]) -> str:
    parts = build_folder_name_chain(folder_id)
    if not parts:
        return "/"
    return "/" + "/".join(parts)


def create_folder(
    *,
    name: str,
    parent_id: Optional[str],
    encrypted: bool,
    password: Optional[str],
    allow_direct_download: bool,
) -> Dict[str, Any]:
    normalized_name = sanitize_folder_name(name)
    if normalized_name is None:
        raise ValueError("invalid folder name")
    normalized_parent_id = parent_id or None
    if normalized_parent_id and not folder_exists(normalized_parent_id):
        raise KeyError("parent folder not found")
    if encrypted and not password:
        raise PermissionError("missing folder password")

    timestamp = now_local().isoformat()
    folder_id = uuid.uuid4().hex
    record: Dict[str, Any] = {
        "id": folder_id,
        "name": normalized_name,
        "parentId": normalized_parent_id,
        "encrypted": encrypted,
        "allowDirectDownload": allow_direct_download if encrypted else True,
        "createdAt": timestamp,
        "updatedAt": timestamp,
    }
    if encrypted and password:
        record.update(_generate_password_hash(password))

    with folder_index_lock:
        folder_records[folder_id] = record
    save_folder_index_state()
    return export_folder_record(record)


def collect_descendant_folder_ids(folder_id: str) -> List[str]:
    descendants: List[str] = []
    pending = [folder_id]
    with folder_index_lock:
        while pending:
            current_id = pending.pop()
            for child_id, child_record in folder_records.items():
                if child_record.get("parentId") == current_id:
                    descendants.append(child_id)
                    pending.append(child_id)
    return descendants


def update_folder(
    folder_id: str,
    *,
    name: Optional[str] = None,
    parent_id: Optional[str] = None,
    parent_id_provided: bool = False,
    encrypted: Optional[bool] = None,
    allow_direct_download: Optional[bool] = None,
    password: Optional[str] = None,
) -> Dict[str, Any]:
    with folder_index_lock:
        record = folder_records.get(folder_id)
        if record is None:
            raise KeyError("folder not found")

        if name is not None:
            normalized_name = sanitize_folder_name(name)
            if normalized_name is None:
                raise ValueError("invalid folder name")
            record["name"] = normalized_name

        if parent_id_provided:
            normalized_parent_id = parent_id or None
            if normalized_parent_id == folder_id:
                raise ValueError("invalid target parent")
            if normalized_parent_id and normalized_parent_id not in folder_records:
                raise KeyError("target parent folder not found")
            descendant_ids = set(collect_descendant_folder_ids(folder_id))
            if normalized_parent_id in descendant_ids:
                raise ValueError("invalid target parent")
            record["parentId"] = normalized_parent_id

        if encrypted is not None:
            record["encrypted"] = encrypted
            if encrypted:
                if not password:
                    raise PermissionError("missing folder password")
                record.update(_generate_password_hash(password))
                record["allowDirectDownload"] = bool(allow_direct_download)
            else:
                record.pop("passwordSalt", None)
                record.pop("passwordHash", None)
                record["allowDirectDownload"] = True

        if encrypted is None and allow_direct_download is not None:
            record["allowDirectDownload"] = bool(allow_direct_download)

        record["updatedAt"] = now_local().isoformat()
        exported = export_folder_record(record)

    save_folder_index_state()
    return exported


def change_folder_password(folder_id: str, new_password: str) -> Dict[str, Any]:
    if not new_password:
        raise PermissionError("missing folder password")
    with folder_index_lock:
        record = folder_records.get(folder_id)
        if record is None:
            raise KeyError("folder not found")
        if not record.get("encrypted"):
            raise ValueError("folder is not encrypted")
        record.update(_generate_password_hash(new_password))
        record["updatedAt"] = now_local().isoformat()
        exported = export_folder_record(record)

    save_folder_index_state()
    return exported


def delete_folder_recursive(folder_id: str) -> List[str]:
    with folder_index_lock:
        if folder_id not in folder_records:
            raise KeyError("folder not found")
        descendant_ids = collect_descendant_folder_ids(folder_id)
        removed_ids = [folder_id] + descendant_ids
        for removed_id in removed_ids:
            folder_records.pop(removed_id, None)

    save_folder_index_state()
    return removed_ids


def create_download_token(relative_path: str, folder_id: str, expires_days: int) -> Dict[str, Any]:
    bounded_days = max(1, min(expires_days, DOWNLOAD_TOKEN_MAX_DAYS))
    expires_at = now_local() + timedelta(days=bounded_days)
    token = secrets.token_urlsafe(32)
    with folder_index_lock:
        download_tokens[token] = {
            "path": relative_path,
            "folderId": folder_id,
            "expiresAt": expires_at.isoformat(),
        }
    save_folder_index_state()
    return {
        "token": token,
        "expiresAt": expires_at.isoformat(),
        "expiresInDays": bounded_days,
    }


def _prune_expired_download_tokens_locked() -> None:
    expired_tokens = []
    now_value = now_local()
    for token, record in download_tokens.items():
        expires_at = record.get("expiresAt")
        if not isinstance(expires_at, str):
            expired_tokens.append(token)
            continue
        try:
            expires_at_value = datetime.fromisoformat(expires_at)
        except ValueError:
            expired_tokens.append(token)
            continue
        if expires_at_value <= now_value:
            expired_tokens.append(token)
    for token in expired_tokens:
        download_tokens.pop(token, None)


def validate_download_token(token: str, relative_path: str) -> bool:
    if not token:
        return False
    with folder_index_lock:
        _prune_expired_download_tokens_locked()
        record = download_tokens.get(token)
        if record is None:
            return False
        return str(record.get("path", "")) == relative_path


def get_disk_capacity() -> Dict[str, int]:
    usage = STORAGE_ROOT.resolve().stat() if False else None
    total, used, free = __import__("shutil").disk_usage(str(STORAGE_ROOT.resolve()))
    return {
        "diskTotalBytes": int(total),
        "diskUsedBytes": int(used),
        "diskFreeBytes": int(free),
    }