"""
探针机器人 - 配置文件
把下面几项改成你自己的值
"""

# --- Telegram ---
BOT_TOKEN = "在这里填入 BotFather 给你的 token"
CHAT_ID = "在这里填入你自己的 chat_id（私聊用）"

# --- Agent 上报鉴权 ---
# 每台 Agent 上报时都要带这个 token，防止别人伪造数据
AUTH_TOKEN = "自己设置一个随机字符串，比如用 openssl rand -hex 16 生成"

# --- 服务端监听端口 ---
SERVER_PORT = 8000

# --- 报警阈值 ---
CPU_THRESHOLD = 90      # CPU 使用率超过 90% 报警
MEM_THRESHOLD = 90      # 内存使用率超过 90% 报警

# --- 离线判定 ---
# 超过这么多秒没收到某节点的上报，就判定为离线
OFFLINE_THRESHOLD_SEC = 90

# --- 后台巡检间隔 ---
CHECK_INTERVAL_SEC = 15
