"""
ImageProvider v3.0 — FastAPI 应用入口
=====================================
元数据与数据分离架构：
  - SQLite 存储所有元数据（文件属性、文件夹树、令牌、审计日志）
  - 文件内容以内容寻址存储（CAS）方式保存在文件系统中
  - 链接格式：/p/{base64url(systemName)}
"""

import logging
import os as _os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.base import BaseHTTPMiddleware

from config import (
    CLEANUP_HOUR,
    DOWNLOAD_TOKEN_MAX_DAYS,
    PERMANENT_TOKEN_HEADER,
    PUBLIC_BASE_URL,
)
from server_auth import is_token_verification_available
from server_database import init_database
from server_routers_files import router as files_router
from server_routers_folders import router as folders_router
from server_routers_upload import router as upload_router
from server_storage import get_disk_capacity
from server_utils import now_local

logger = logging.getLogger("imageprovider")


# ── 应用生命周期 ──────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    """启动时初始化数据库，关闭时清理资源"""
    await init_database()
    logger.info("database initialized, file route prefix: /p")
    logger.info("public base URL: %s", PUBLIC_BASE_URL)
    yield
    logger.info("shutting down")


app = FastAPI(
    title="ImageProvider",
    version="3.0.0",
    description="文件存储服务 — 元数据与数据分离架构",
    lifespan=lifespan,
)


# ── 请求体大小限制中间件（防止大 JSON body 耗尽内存）─────────────
#    默认限制 1MB，可通过 IMAGE_PROVIDER_MAX_JSON_BODY_BYTES 配置

_MAX_JSON_BODY = int(_os.getenv("IMAGE_PROVIDER_MAX_JSON_BODY_BYTES", str(1024 * 1024)))


class _RequestBodySizeLimitMiddleware(BaseHTTPMiddleware):
    """非上传类接口的请求体大小限制中间件"""
    async def dispatch(self, request: Request, call_next):
        content_length = request.headers.get("content-length")
        if content_length and content_length.isdigit():
            if int(content_length) > _MAX_JSON_BODY:
                from fastapi.responses import JSONResponse
                return JSONResponse(
                    status_code=413,
                    content={"code": 41300, "message": "request body too large", "data": None},
                )
        return await call_next(request)


app.add_middleware(_RequestBodySizeLimitMiddleware)


# ── CORS 中间件 ───────────────────────────────────────────────────
#    生产环境建议通过 IMAGE_PROVIDER_CORS_ORIGINS 配置具体域名（逗号分隔）

_cors_origins_raw = _os.getenv("IMAGE_PROVIDER_CORS_ORIGINS", "*")
_cors_origins = (
    [o.strip() for o in _cors_origins_raw.split(",") if o.strip()]
    if _cors_origins_raw != "*"
    else ["*"]
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_credentials=False,  # 无 Cookie 场景，设为 False 避免与 allow_origins=["*"] 冲突
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── 注册路由 ──────────────────────────────────────────────────────

app.include_router(upload_router)
app.include_router(files_router)
app.include_router(folders_router)


# ── 健康检查 ──────────────────────────────────────────────────────

@app.get("/api/health")
async def health_check():
    """服务健康检查（无需鉴权，仅暴露必要运行信息）"""
    disk = get_disk_capacity()
    return {
        "code": 0,
        "message": "ok",
        "data": {
            "status": "running",
            "version": "3.0.0",
            **disk,
        },
    }


# ── 主入口 ──────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    import asyncio
    import logging
    import os as _os_main
    import threading
    import time

    from config import HOST, PORT
    from server_database import async_session_factory, backup_database_if_due
    from server_storage import cleanup_scheduler_loop, ensure_storage

    # 日志
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    parser = argparse.ArgumentParser(description="ImageProvider v3.0")
    parser.add_argument("--host", default=_os_main.getenv("IMAGE_PROVIDER_HOST", HOST))
    parser.add_argument("--port", type=int, default=int(_os_main.getenv("IMAGE_PROVIDER_PORT", str(PORT))))
    args = parser.parse_args()

    # 确保存储目录存在
    ensure_storage()

    # 启动后台清理调度线程
    def _cleanup_loop():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(cleanup_scheduler_loop(async_session_factory))
        except Exception:
            pass
        finally:
            loop.close()

    cleanup_thread = threading.Thread(target=_cleanup_loop, daemon=True, name="cleanup-scheduler")
    cleanup_thread.start()

    # 启动数据库自动备份线程
    def _backup_loop():
        import server_state
        while not server_state.shutdown_event.is_set():
            if server_state.shutdown_event.wait(60):
                break
            try:
                backup_database_if_due()
            except Exception:
                pass

    backup_thread = threading.Thread(target=_backup_loop, daemon=True, name="db-backup")
    backup_thread.start()

    # 启动 HTTP 服务
    import uvicorn
    logger.info("ImageProvider v3.0 starting on %s:%s", args.host, args.port)
    uvicorn.run(
        "app:app",
        host=args.host,
        port=args.port,
        log_level="info",
        access_log=True,
        timeout_keep_alive=90000,
        limit_concurrency=100,
        limit_max_requests=10000,
    )
