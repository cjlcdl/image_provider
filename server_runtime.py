"""
服务启动模块 v3.0
================
使用 uvicorn 启动 FastAPI 应用（替代原 stdlib http.server）。
启动时自动初始化数据库、创建存储目录、启动后台任务。
"""

import asyncio
import logging
import threading

import uvicorn

import server_state as state
from config import HOST, PORT
from server_database import async_session_factory, backup_database_if_due, init_database
from server_storage import cleanup_expired_temp_files, cleanup_scheduler_loop, ensure_storage

# 配置日志（替代散落的 print() 调用）
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("imageprovider")


async def _startup_tasks() -> None:
    """启动时执行的一次性初始化任务"""
    ensure_storage()
    await init_database()
    async with async_session_factory() as db:
        from server_storage import cleanup_expired_sessions
        await cleanup_expired_sessions(db)
    logger.info("storage initialized, database ready")


def _background_cleanup_loop() -> None:
    """后台清理线程：定时清理过期临时文件 + 数据库自动备份"""
    import time

    # 在新的事件循环中运行异步清理调度器
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    async def _run():
        await cleanup_scheduler_loop(async_session_factory)

    try:
        loop.run_until_complete(_run())
    except Exception as exc:
        logger.error(f"background cleanup error: {exc}")
    finally:
        loop.close()


def run() -> None:
    """启动服务（同步入口，供 app.py 调用）"""
    asyncio.run(_startup_tasks())

    cleanup_thread = threading.Thread(target=_background_cleanup_loop, daemon=True, name="cleanup-scheduler")
    cleanup_thread.start()

    def _backup_loop():
        import time
        while not state.shutdown_event.is_set():
            if state.shutdown_event.wait(60):
                break
            try:
                backup_database_if_due()
            except Exception as exc:
                logger.error(f"database backup error: {exc}")

    backup_thread = threading.Thread(target=_backup_loop, daemon=True, name="db-backup")
    backup_thread.start()

    logger.info(f"ImageProvider v3.0 starting on {HOST}:{PORT}")
    uvicorn.run(
        "app:app",
        host=HOST,
        port=PORT,
        log_level="info",
        access_log=True,
        timeout_keep_alive=90000,       # Keep-Alive 超时（秒）
        limit_concurrency=100,       # 最大并发连接数
        limit_max_requests=10000,    # 每个 worker 最大请求数（防止内存泄漏）
    )


if __name__ == "__main__":
    run()
