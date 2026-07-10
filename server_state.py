"""
全局运行状态 v3.0
================
精简版 — 文件索引和文件夹已迁移至 SQLite，仅保留：
  - 清理状态追踪（.cleanup_state）
  - 频率限制窗口（内存）
  - 服务关闭信号
  - 上传会话并发控制锁
"""

import threading
from typing import Dict

from config import STORAGE_ROOT

# ── 清理状态 ───────────────────────────────────────────────────
STATE_FILE = STORAGE_ROOT / ".cleanup_state"
"""记录上次清理日期的文件，避免同一天重复清理"""

# ── 线程同步原语 ───────────────────────────────────────────────
cleanup_lock = threading.Lock()
"""每日清理任务锁，确保同一时间只有一个清理任务执行"""

shutdown_event = threading.Event()
"""服务关闭信号，用于通知后台线程优雅退出"""

rate_limit_lock = threading.Lock()
"""频率限制窗口字典的并发控制锁"""

upload_session_lock = threading.RLock()
"""上传会话操作的并发控制锁（可重入）"""

# ── 频率限制（内存）────────────────────────────────────────────
upload_rate_windows: Dict[str, Dict[str, int]] = {}
"""按客户端 IP 跟踪上传频率: {ip: {"window": int, "count": int}}"""

