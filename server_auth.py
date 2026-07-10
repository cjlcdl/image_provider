"""
认证模块 v3.1
============
- RSA OAEP (SHA-256) Courage-Token 验证（FastAPI 依赖注入风格）
- 文件夹密码令牌验证
- Nonce 防重放（SQLite 持久化，支持多 worker 安全）
- 私钥加载（兼容 UTF-8 BOM，不永久缓存失败状态）
"""

import base64
import binascii
import hashlib
import hmac
import json
import logging
import re
import sys
import threading
import time as unix_time
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Tuple

from fastapi import Depends, Header, HTTPException
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from config import PERMANENT_TOKEN_MAX_AGE_SECONDS, PERMANENT_TOKEN_PRIVATE_KEY_PATH
from server_models import Folder, UsedNonce
from server_utils import read_key_file_bytes

logger = logging.getLogger("imageprovider.auth")

# ---------------------------------------------------------------------------
# cryptography 库加载
# ---------------------------------------------------------------------------

try:
    from cryptography.hazmat.backends import default_backend as crypto_backend
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding as asym_padding

    CRYPTOGRAPHY_IMPORT_ERROR = None
except ImportError as exc:
    crypto_backend = None
    serialization = None
    hashes = None
    asym_padding = None
    CRYPTOGRAPHY_IMPORT_ERROR = exc

# ---------------------------------------------------------------------------
# 私钥缓存（模块级，避免每次请求都读取磁盘）
# ---------------------------------------------------------------------------

_permanent_private_key: Any = None
_permanent_private_key_error: Any = None
_key_lock = threading.Lock()

NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


# ---------------------------------------------------------------------------
# 私钥加载
# ---------------------------------------------------------------------------

def _get_private_key() -> Optional[Any]:
    """加载 RSA 私钥（带双重检查锁定缓存，失败不永久缓存）"""
    global _permanent_private_key, _permanent_private_key_error

    if _permanent_private_key is not None:
        return _permanent_private_key

    if CRYPTOGRAPHY_IMPORT_ERROR is not None:
        _permanent_private_key_error = CRYPTOGRAPHY_IMPORT_ERROR
        return None
    if serialization is None:
        _permanent_private_key_error = RuntimeError("cryptography unavailable")
        return None

    with _key_lock:
        if _permanent_private_key is not None:
            return _permanent_private_key

        try:
            key_bytes = read_key_file_bytes(PERMANENT_TOKEN_PRIVATE_KEY_PATH)
            if crypto_backend is not None:
                _permanent_private_key = serialization.load_pem_private_key(
                    key_bytes, password=None, backend=crypto_backend()
                )
            else:
                _permanent_private_key = serialization.load_pem_private_key(
                    key_bytes, password=None
                )
        except Exception as exc:
            _permanent_private_key_error = exc
            return None

    _permanent_private_key_error = None
    return _permanent_private_key


def is_token_verification_available() -> bool:
    """Courage-Token 验签功能是否可用"""
    return _get_private_key() is not None and asym_padding is not None


# ---------------------------------------------------------------------------
# OAEP 填充辅助（v3.1：从 PKCS#1 v1.5 升级为 OAEP SHA-256）
# ---------------------------------------------------------------------------

def _oaep_padding():
    """构造 OAEP-SHA256 填充对象"""
    if hashes is None:
        raise RuntimeError("cryptography hashes module unavailable")
    return asym_padding.OAEP(
        mgf=asym_padding.MGF1(algorithm=hashes.SHA256()),
        algorithm=hashes.SHA256(),
        label=None,
    )


# ---------------------------------------------------------------------------
# Nonce 防重放（SQLite 持久化，异步）
# ---------------------------------------------------------------------------

async def _reserve_nonce_async(db: AsyncSession, nonce: str) -> bool:
    """异步版：在数据库中原子性预留 nonce。

    使用 INSERT … ON CONFLICT DO NOTHING 实现原子检查并插入。
    仅捕获 IntegrityError（真正的冲突），其他异常（DB 故障等）向上传播。

    注意：不在本函数中清理过期 nonce（由定时任务统一处理），
    以避免 DELETE + INSERT 之间的并发竞争窗口。
    """
    expires_at = datetime.now(timezone.utc).timestamp() + PERMANENT_TOKEN_MAX_AGE_SECONDS
    expires_dt = datetime.fromtimestamp(expires_at, tz=timezone.utc)

    from sqlalchemy.dialects.sqlite import insert as sqlite_insert
    from sqlalchemy.exc import IntegrityError

    try:
        stmt = sqlite_insert(UsedNonce).values(
            nonce=nonce,
            expires_at=expires_dt,
        )
        stmt = stmt.on_conflict_do_nothing(index_elements=["nonce"])
        result = await db.execute(stmt)
        await db.flush()
        return result.rowcount > 0
    except IntegrityError:
        # 真正的 nonce 冲突（已存在且未过期）
        return False
    # 其他异常（DB 连接断开、磁盘满等）不吞噬，向上传播为 500


async def _prune_expired_nonces_async(db: AsyncSession) -> None:
    """清理数据库中过期的 nonce 记录"""
    await db.execute(
        delete(UsedNonce).where(
            UsedNonce.expires_at <= datetime.now(timezone.utc)
        )
    )
    await db.flush()


async def clear_used_nonces_async(db: AsyncSession) -> None:
    """清空所有 nonce（每日清理时调用）"""
    await db.execute(delete(UsedNonce))
    await db.flush()


# 保留同步版供兼容（后台清理线程使用）
_used_nonce_expirations: Dict[str, int] = {}
_nonce_lock = threading.Lock()


def _reserve_nonce_sync(nonce: str) -> bool:
    """同步版 nonce 预留（仅用于无 DB 会话的后台兼容场景）"""
    current_ts = int(unix_time.time())
    with _nonce_lock:
        expired = [n for n, e in _used_nonce_expirations.items() if e <= current_ts]
        for n in expired:
            _used_nonce_expirations.pop(n, None)
        if nonce in _used_nonce_expirations:
            return False
        _used_nonce_expirations[nonce] = current_ts + PERMANENT_TOKEN_MAX_AGE_SECONDS
    return True


def clear_used_nonces_sync() -> None:
    """同步版清空 nonce"""
    with _nonce_lock:
        _used_nonce_expirations.clear()


# ---------------------------------------------------------------------------
# RSA 令牌验证核心（异步 + OAEP）
# ---------------------------------------------------------------------------

async def validate_rsa_token_async(
    db: AsyncSession, token_value: str
) -> Tuple[bool, Optional[Dict[str, Any]], int, str]:
    """验证 RSA-OAEP 加密的 JSON 令牌（v3.1 OAEP SHA-256）

    流程：
      Base64 解码 → RSA-OAEP 解密 → JSON 解析
      → ts 有效期检查 → nonce 防重放（DB 持久化）

    Returns:
        (success, payload_dict, error_code, error_message)
    """
    private_key = _get_private_key()
    if private_key is None:
        logger.error(f"token verification unavailable: {_permanent_private_key_error!r}")
        return False, None, 40100, "invalid token"
    if asym_padding is None:
        return False, None, 40100, "invalid token"

    # Step 1: Base64 解码
    try:
        encrypted_payload = base64.b64decode(token_value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError, binascii.Error):
        return False, None, 40100, "invalid token"

    # Step 2: RSA-OAEP 解密（v3.1 升级）
    try:
        plaintext = private_key.decrypt(encrypted_payload, _oaep_padding())
    except Exception:
        return False, None, 40100, "invalid token"

    # Step 3: JSON 解析
    try:
        payload = json.loads(plaintext.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False, None, 40100, "invalid token"

    if not isinstance(payload, dict):
        return False, None, 40100, "invalid token"

    # Step 4: 时间戳有效期检查
    timestamp_value = payload.get("ts")
    nonce = payload.get("nonce")
    if isinstance(timestamp_value, str) and timestamp_value.isdigit():
        timestamp_value = int(timestamp_value)
    if not isinstance(timestamp_value, int) or not isinstance(nonce, str):
        return False, None, 40100, "invalid token"
    if not NONCE_PATTERN.fullmatch(nonce):
        return False, None, 40100, "invalid token"
    if abs(int(unix_time.time()) - timestamp_value) > PERMANENT_TOKEN_MAX_AGE_SECONDS:
        return False, None, 40101, "expired permanent token"

    # Step 5: Nonce 防重放（DB 持久化）
    if not await _reserve_nonce_async(db, nonce):
        return False, None, 40102, "replayed permanent token"

    return True, payload, 0, "ok"


# 保留同步版供兼容（后台线程等无 DB 会话场景）
def validate_rsa_token_sync(token_value: str) -> Tuple[bool, Optional[Dict[str, Any]], int, str]:
    """同步版令牌验证（兼容旧代码，仅用于无 DB 会话的后台场景）"""
    private_key = _get_private_key()
    if private_key is None:
        return False, None, 40100, "invalid token"
    if asym_padding is None:
        return False, None, 40100, "invalid token"

    try:
        encrypted_payload = base64.b64decode(token_value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError, binascii.Error):
        return False, None, 40100, "invalid token"

    try:
        plaintext = private_key.decrypt(encrypted_payload, _oaep_padding())
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
    if not NONCE_PATTERN.fullmatch(nonce):
        return False, None, 40100, "invalid token"
    if abs(int(unix_time.time()) - timestamp_value) > PERMANENT_TOKEN_MAX_AGE_SECONDS:
        return False, None, 40101, "expired permanent token"
    if not _reserve_nonce_sync(nonce):
        return False, None, 40102, "replayed permanent token"

    return True, payload, 0, "ok"


# ---------------------------------------------------------------------------
# PBKDF2 密码哈希（600000 迭代，OWASP 2025 推荐）
# ---------------------------------------------------------------------------

PASSWORD_HASH_ITERATIONS = 600000


def _generate_password_hash(password: str, salt_bytes: Optional[bytes] = None) -> Dict[str, str]:
    """生成 PBKDF2-SHA256 密码哈希"""
    import secrets as _secrets
    actual_salt = salt_bytes or _secrets.token_bytes(16)
    derived = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), actual_salt, PASSWORD_HASH_ITERATIONS
    )
    return {
        "passwordSalt": base64.b64encode(actual_salt).decode("ascii"),
        "passwordHash": base64.b64encode(derived).decode("ascii"),
    }


def verify_folder_password(folder_record, password: str) -> bool:
    """验证文件夹密码（兼容 ORM 对象和 dict）"""
    if hasattr(folder_record, "password_salt"):
        salt = folder_record.password_salt
        expected_hash = folder_record.password_hash
    else:
        salt = folder_record.get("passwordSalt") or folder_record.get("password_salt")
        expected_hash = folder_record.get("passwordHash") or folder_record.get("password_hash")

    if not isinstance(salt, str) or not isinstance(expected_hash, str):
        return False
    try:
        salt_bytes = base64.b64decode(salt.encode("ascii"), validate=True)
    except (ValueError, UnicodeEncodeError):
        return False

    calculated = _generate_password_hash(password, salt_bytes=salt_bytes)
    return hmac.compare_digest(expected_hash, calculated["passwordHash"])


def folder_requires_password(folder_record) -> bool:
    """判断文件夹是否启用了密码加密保护"""
    if folder_record is None:
        return False
    if hasattr(folder_record, "encrypted"):
        return bool(folder_record.encrypted)
    return bool(folder_record.get("encrypted"))


# ---------------------------------------------------------------------------
# FastAPI 管理令牌验证（显式传参，不做 Depends）
# ---------------------------------------------------------------------------

async def verify_management_token(
    db: AsyncSession,
    courage_token: str,
) -> Dict[str, Any]:
    """验证 Courage-Token 管理令牌（OAEP + DB nonce）

    Args:
        db: 数据库会话（由路由通过 Depends(get_db) 获取后传入）
        courage_token: Courage-Token 请求头值（由路由提取后传入）

    Returns:
        令牌 payload（含 ts 和 nonce）

    Raises:
        HTTPException: 验证失败时
    """
    token_value = courage_token.strip()
    if not token_value:
        raise HTTPException(status_code=401, detail="missing management token")

    is_valid, payload, code, message = await validate_rsa_token_async(db, token_value)
    if not is_valid:
        status = 401 if code < 50000 else 500
        raise HTTPException(status_code=status, detail=message)
    if payload is None:
        raise HTTPException(status_code=401, detail="invalid token")

    return payload


# ---------------------------------------------------------------------------
# 文件夹密码令牌辅助
# ---------------------------------------------------------------------------

async def check_folder_password_token(
    db: AsyncSession,
    folder_id: str,
    token_value: str,
) -> str:
    """验证单个文件夹密码令牌（供路由器调用的辅助函数）

    Args:
        db: 数据库会话
        folder_id: 目标文件夹 ID
        token_value: Folder-Password-Token 请求头值

    Returns:
        验证后的文件夹密码字符串

    Raises:
        HTTPException: 验证失败时
    """
    if not folder_id:
        return ""

    result = await db.execute(select(Folder).where(Folder.id == folder_id))
    folder_record = result.scalar_one_or_none()
    if folder_record is None:
        raise HTTPException(status_code=404, detail="folder not found")
    if not folder_record.encrypted:
        return ""

    token_value = token_value.strip()
    if not token_value:
        raise HTTPException(status_code=401, detail="missing folder password token")

    is_valid, payload, code, message = await validate_rsa_token_async(db, token_value)
    if not is_valid:
        status = 401
        if code == 40302: status = 403
        if code == 40403: status = 404
        raise HTTPException(status_code=status, detail=message)
    if payload is None:
        raise HTTPException(status_code=401, detail="invalid folder password token")

    token_folder_id = payload.get("folderId")
    password = payload.get("password")
    if not isinstance(token_folder_id, str) or token_folder_id != folder_id:
        raise HTTPException(status_code=401, detail="invalid folder password token")
    if not isinstance(password, str) or not password:
        raise HTTPException(status_code=401, detail="invalid folder password token")

    if not verify_folder_password(folder_record, password):
        raise HTTPException(status_code=403, detail="invalid folder password")

    return password
