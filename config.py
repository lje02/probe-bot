"""
探针机器人 - 配置文件
所有敏感信息(token/密钥)从环境变量读取，不写死在代码里，避免误提交到 git 或截图泄露。

本地运行前，把 .env.example 复制成 .env 并填好即可，程序会自动加载。
"""

import os
import sys
from dotenv import load_dotenv

load_dotenv()  # 自动读取同目录下的 .env 文件


def _require(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        sys.exit(f"[配置错误] 缺少环境变量 {name}，请检查 .env 文件")
    return val


# --- Telegram ---
BOT_TOKEN = _require("PROBE_BOT_TOKEN")
CHAT_ID = _require("PROBE_CHAT_ID")

# --- Agent 上报鉴权 ---
# 每台 Agent 上报时都要带这个 token，防止别人伪造数据
AUTH_TOKEN = _require("PROBE_AUTH_TOKEN")

# --- 服务端监听地址/端口 ---
# 只监听本机回环地址，不直接暴露公网端口，靠 Nginx/Tailscale 转发(见 README 安全部分)
SERVER_HOST = os.environ.get("PROBE_SERVER_HOST", "127.0.0.1")
SERVER_PORT = int(os.environ.get("PROBE_SERVER_PORT", "8000"))

# --- 报警阈值 ---
CPU_THRESHOLD = float(os.environ.get("PROBE_CPU_THRESHOLD", "90"))
MEM_THRESHOLD = float(os.environ.get("PROBE_MEM_THRESHOLD", "90"))

# --- 离线判定 ---
# 超过这么多秒没收到某节点的上报，就判定为离线
OFFLINE_THRESHOLD_SEC = int(os.environ.get("PROBE_OFFLINE_THRESHOLD_SEC", "90"))

# --- 后台巡检间隔 ---
CHECK_INTERVAL_SEC = int(os.environ.get("PROBE_CHECK_INTERVAL_SEC", "15"))
