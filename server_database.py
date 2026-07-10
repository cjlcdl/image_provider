"""
数据库会话管理与初始化
=====================
- 创建异步 SQLAlchemy 引擎和会话工厂
- 启用 SQLite WAL 模式以支持并发读写
- 提供 FastAPI 依赖注入的 get_db 生成器
- 数据库自动备份功能
"""

import shutil
import time as unix_time
from datetime import datetime, timedelta
from pathlib import Path
from typing import AsyncGenerator

from sqlalchemy import event, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from config import DB_PATH, DB_BACKUP_DIR, DB_BACKUP_MAX_COUNT, DB_BACKUP_INTERVAL_MINUTES
from server_models import Base

# ---------------------------------------------------------------------------
# 数据库引擎（异步）
# ---------------------------------------------------------------------------
# SQLite 文件数据库不适合使用连接池（QueuePool），异步引擎会自动选择
# NullPool，每个连接独立管理，WAL 模式已提供足够的并发能力。

engine = create_async_engine(
    f"sqlite+aiosqlite:///{DB_PATH}",
    connect_args={
        "check_same_thread": False,  # SQLite 默认只允许单线程，FastAPI 异步需关闭
    },
    echo=False,  # 生产环境关闭 SQL 日志；调试时可设为 True
)

# 异步会话工厂
async_session_factory = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,  # 提交后不过期对象，避免懒加载时报错
)


# ---------------------------------------------------------------------------
# SQLite WAL 模式 + 性能优化（在每次新连接建立时执行）
# ---------------------------------------------------------------------------

@event.listens_for(engine.sync_engine, "connect")
def _set_sqlite_pragma(dbapi_connection, connection_record):
    """在 SQLite 连接建立时设置 PRAGMA 优化选项"""
    cursor = dbapi_connection.cursor()
    # WAL 模式：支持并发读 + 单写，大幅提升并发性能
    cursor.execute("PRAGMA journal_mode=WAL")
    # 忙等待超时 5 秒（而非立即返回 SQLITE_BUSY）
    cursor.execute("PRAGMA busy_timeout=5000")
    # 启用外键约束检查
    cursor.execute("PRAGMA foreign_keys=ON")
    # 同步模式：NORMAL（WAL 模式下安全且性能更好）
    cursor.execute("PRAGMA synchronous=NORMAL")
    # 缓存大小：64MB
    cursor.execute("PRAGMA cache_size=-65536")
    cursor.close()


# ---------------------------------------------------------------------------
# 数据库初始化（创建所有表）
# ---------------------------------------------------------------------------

async def init_database() -> None:
    """创建数据库目录和所有表（如果不存在）"""
    db_dir = Path(DB_PATH).parent
    db_dir.mkdir(parents=True, exist_ok=True)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


# ---------------------------------------------------------------------------
# FastAPI 依赖注入：获取数据库会话
# ---------------------------------------------------------------------------

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """FastAPI 依赖注入生成器：每次请求创建一个数据库会话，请求结束后自动关闭"""
    async with async_session_factory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        finally:
            await session.close()


# ---------------------------------------------------------------------------
# 数据库自动备份
# ---------------------------------------------------------------------------

_last_backup_time: float = 0.0


def _backup_filename() -> str:
    """生成带时间戳的备份文件名"""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return f"metadata_backup_{timestamp}.db"


def _prune_old_backups() -> None:
    """清理超过保留数量的旧备份文件"""
    backup_dir = Path(DB_BACKUP_DIR)
    if not backup_dir.exists():
        return

    backup_files = sorted(
        [f for f in backup_dir.iterdir() if f.suffix == ".db" and f.name.startswith("metadata_backup_")],
        key=lambda f: f.stat().st_mtime,
        reverse=True,
    )
    # 删除超出保留数量的旧备份
    for old_file in backup_files[DB_BACKUP_MAX_COUNT:]:
        try:
            old_file.unlink()
        except OSError:
            pass


def backup_database_if_due() -> bool:
    """如果距上次备份超过指定间隔，执行一次数据库备份

    返回 True 表示执行了备份，False 表示跳过。
    使用 SQLite 在线备份 API（零停机，WAL 模式下安全）。
    备份时通过 URI 参数 ?nolock=1 避免与主连接冲突。
    """
    global _last_backup_time

    current_time = unix_time.time()
    if current_time - _last_backup_time < DB_BACKUP_INTERVAL_MINUTES * 60:
        return False

    db_path = Path(DB_PATH)
    if not db_path.exists():
        return False

    backup_dir = Path(DB_BACKUP_DIR)
    backup_dir.mkdir(parents=True, exist_ok=True)

    backup_path = backup_dir / _backup_filename()

    try:
        import sqlite3

        # 使用 URI 连接方式，启用 WAL 读取一致性
        source = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        dest = sqlite3.connect(str(backup_path))
        source.backup(dest)
        dest.close()
        source.close()

        _last_backup_time = current_time
        _prune_old_backups()
        return True
    except Exception:
        return False
