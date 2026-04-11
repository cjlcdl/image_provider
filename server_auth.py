import base64
import binascii
import json
import sys
import time as unix_time
from typing import Any, Dict, Optional, Tuple

import server_state as state
from config import PERMANENT_TOKEN_MAX_AGE_SECONDS, PERMANENT_TOKEN_PRIVATE_KEY_PATH
from folder_index import folder_requires_password, get_folder, verify_folder_password
from server_storage import reserve_nonce
from server_utils import read_key_file_bytes

try:
    from cryptography.hazmat.backends import default_backend as cryptography_default_backend
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import padding as asym_padding

    CRYPTOGRAPHY_IMPORT_ERROR = None
except ImportError as exc:
    cryptography_default_backend = None
    serialization = None
    asym_padding = None
    CRYPTOGRAPHY_IMPORT_ERROR = exc


def get_permanent_private_key() -> Optional[Any]:
    if state.permanent_private_key is not None:
        return state.permanent_private_key
    if CRYPTOGRAPHY_IMPORT_ERROR is not None:
        state.permanent_private_key_error = CRYPTOGRAPHY_IMPORT_ERROR
        return None
    if serialization is None:
        state.permanent_private_key_error = RuntimeError("cryptography serialization module is unavailable")
        return None

    try:
        key_bytes = read_key_file_bytes(PERMANENT_TOKEN_PRIVATE_KEY_PATH)
        if cryptography_default_backend is not None:
            state.permanent_private_key = serialization.load_pem_private_key(
                key_bytes,
                password=None,
                backend=cryptography_default_backend(),
            )
        else:
            state.permanent_private_key = serialization.load_pem_private_key(
                key_bytes,
                password=None,
            )
    except Exception as exc:
        state.permanent_private_key_error = exc
        return None

    state.permanent_private_key_error = None
    return state.permanent_private_key


def is_permanent_token_verification_available() -> bool:
    return get_permanent_private_key() is not None and asym_padding is not None


def validate_permanent_token(token_value: str) -> Tuple[bool, Optional[Dict[str, Any]], int, str]:
    is_valid, payload, code, message = validate_rsa_json_token(token_value)
    if not is_valid:
        return False, None, code, message
    if payload is None:
        return False, None, 40100, "invalid token"
    return True, payload, 0, "ok"


def validate_rsa_json_token(token_value: str) -> Tuple[bool, Optional[Dict[str, Any]], int, str]:
    private_key = get_permanent_private_key()
    if private_key is None:
        print(
            "permanent token support unavailable: {!r}".format(state.permanent_private_key_error),
            file=sys.stderr,
        )
        return False, None, 50001, "permanent token verification is unavailable"
    if asym_padding is None:
        return False, None, 50001, "permanent token verification is unavailable"

    try:
        encrypted_payload = base64.b64decode(token_value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError, binascii.Error):
        return False, None, 40100, "invalid token"

    try:
        plaintext = private_key.decrypt(encrypted_payload, asym_padding.PKCS1v15())
    except Exception:
        return False, None, 40100, "invalid token"

    try:
        payload = json.loads(plaintext.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False, None, 40100, "invalid token"

    if not isinstance(payload, dict):
        return False, None, 40100, "invalid token"

    timestamp_value = payload.get("ts")
    nonce = payload.get("nonce")
    if isinstance(timestamp_value, str) and timestamp_value.isdigit():
        timestamp_value = int(timestamp_value)
    if not isinstance(timestamp_value, int) or not isinstance(nonce, str):
        return False, None, 40100, "invalid token"
    if not state.NONCE_PATTERN.fullmatch(nonce):
        return False, None, 40100, "invalid token"
    if abs(int(unix_time.time()) - timestamp_value) > PERMANENT_TOKEN_MAX_AGE_SECONDS:
        return False, None, 40101, "expired permanent token"
    if not reserve_nonce(nonce):
        return False, None, 40102, "replayed permanent token"
    return True, payload, 0, "ok"


def validate_folder_password_token(
    token_value: str,
    expected_folder_id: str,
) -> Tuple[bool, Optional[str], int, str]:
    is_valid, payload, code, message = validate_rsa_json_token(token_value)
    if not is_valid:
        return False, None, code, message
    if payload is None:
        return False, None, 40105, "invalid folder password token"

    folder_id = payload.get("folderId")
    password = payload.get("password")
    if not isinstance(folder_id, str) or folder_id != expected_folder_id:
        return False, None, 40105, "invalid folder password token"
    if not isinstance(password, str) or not password:
        return False, None, 40105, "invalid folder password token"

    folder_record = get_folder(expected_folder_id)
    if folder_record is None:
        return False, None, 40403, "folder not found"
    if not folder_requires_password(folder_record):
        return True, password, 0, "ok"
    if not verify_folder_password(folder_record, password):
        return False, None, 40302, "invalid folder password"
    return True, password, 0, "ok"


def validate_folder_passwords_token(
    token_value: str,
    expected_folder_ids: list,
) -> Tuple[bool, Optional[Dict[str, str]], int, str]:
    is_valid, payload, code, message = validate_rsa_json_token(token_value)
    if not is_valid:
        return False, None, code, message
    if payload is None:
        return False, None, 40107, "invalid folder passwords token"

    raw_folders = payload.get("folders")
    if not isinstance(raw_folders, list):
        return False, None, 40107, "invalid folder passwords token"

    provided_passwords: Dict[str, str] = {}
    for item in raw_folders:
        if not isinstance(item, dict):
            return False, None, 40107, "invalid folder passwords token"
        folder_id = item.get("folderId")
        password = item.get("password")
        if not isinstance(folder_id, str) or not folder_id:
            return False, None, 40107, "invalid folder passwords token"
        if not isinstance(password, str) or not password:
            return False, None, 40107, "invalid folder passwords token"
        provided_passwords[folder_id] = password

    validated_passwords: Dict[str, str] = {}
    for folder_id in expected_folder_ids:
        if not isinstance(folder_id, str) or not folder_id:
            continue
        folder_record = get_folder(folder_id)
        if folder_record is None:
            return False, None, 40403, "folder not found"
        if not folder_requires_password(folder_record):
            continue

        password = provided_passwords.get(folder_id)
        if not isinstance(password, str) or not password:
            return False, None, 40107, "missing folder passwords token"
        if not verify_folder_password(folder_record, password):
            return False, None, 40302, "invalid folder password"
        validated_passwords[folder_id] = password

    return True, validated_passwords, 0, "ok"
