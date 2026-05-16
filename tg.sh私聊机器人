#!/bin/bash
# ╔══════════════════════════════════════════════════════╗
# ║     Telegram 客服中转机器人 v2  — 一键安装脚本       ║
# ║     支持: Ubuntu / Debian / CentOS / RHEL / Fedora   ║
# ╚══════════════════════════════════════════════════════╝

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
MAGENTA='\033[0;35m'

INSTALL_DIR="/opt/tg-relay-bot"
SERVICE_NAME="tg-relay-bot"

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

# ══════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════

banner() {
cat << 'EOF'

  ████████╗ ██████╗     ██████╗  ██████╗ ████████╗
     ██╔══╝██╔════╝     ██╔══██╗██╔═══██╗╚══██╔══╝
     ██║   ██║  ███╗    ██████╔╝██║   ██║   ██║
     ██║   ██║   ██║    ██╔══██╗██║   ██║   ██║
     ██║   ╚██████╔╝    ██████╔╝╚██████╔╝   ██║
     ╚═╝    ╚═════╝     ╚═════╝  ╚═════╝    ╚═╝

      Telegram 客服中转机器人 v2 — 管理程序
      功能：消息中转 · 全媒体 · 屏蔽拉黑 · 会话管理
EOF
echo ""
}

# ══════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════

show_menu() {
    # 检测当前安装状态
    local status_line
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        status_line="${GREEN}● 运行中${NC}"
    elif systemctl list-units --all 2>/dev/null | grep -q "$SERVICE_NAME"; then
        status_line="${RED}● 已停止${NC}"
    elif [ -d "$INSTALL_DIR" ]; then
        status_line="${YELLOW}● 已安装（未注册服务）${NC}"
    else
        status_line="${CYAN}● 未安装${NC}"
    fi

    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║         Telegram 客服机器人  管理菜单         ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  当前状态: $(printf '%-34b' "$status_line")${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}1)${NC} 全新安装机器人                           ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}2)${NC} 重新配置（Token / 主人ID / 匿名模式）    ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}3)${NC} 更新程序文件（保留配置）                 ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}4)${NC} 启动机器人                               ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}5)${NC} 停止机器人                               ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}6)${NC} 重启机器人                               ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${CYAN}7)${NC} 查看运行状态                             ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${CYAN}8)${NC} 查看实时日志                             ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${CYAN}9)${NC} 查看当前配置                             ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${RED}10)${NC} 完全卸载（删除所有文件）                ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${MAGENTA}0)${NC} 退出                                     ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════
#  基础检查
# ══════════════════════════════════════════════════════

check_root() {
    [[ $EUID -eq 0 ]] || error "请用 root 权限运行: sudo bash install.sh"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release; OS=$ID; OS_VER=${VERSION_ID:-""}
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        error "无法识别操作系统，请手动安装。"
    fi
    info "操作系统: ${OS} ${OS_VER}"
}

check_installed() {
    [ -d "$INSTALL_DIR" ] || error "未检测到已安装的机器人，请先选择「全新安装」。"
}

check_service_exists() {
    systemctl list-units --all 2>/dev/null | grep -q "$SERVICE_NAME" || \
    [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] || \
    error "未检测到服务，请先选择「全新安装」。"
}

# ══════════════════════════════════════════════════════
#  系统依赖 & Python
# ══════════════════════════════════════════════════════

install_system_deps() {
    step "安装系统依赖"
    case $OS in
        ubuntu|debian)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y python3 python3-pip python3-venv curl >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf install -y python3 python3-pip curl >/dev/null 2>&1
            else
                yum install -y python3 python3-pip curl >/dev/null 2>&1
            fi ;;
        fedora)
            dnf install -y python3 python3-pip curl >/dev/null 2>&1 ;;
        *) warn "未知系统，跳过依赖安装，如报错请手动安装 python3 python3-pip" ;;
    esac
    success "系统依赖完成"
}

check_python() {
    if command -v python3 &>/dev/null && python3 -c "import sys; exit(0 if sys.version_info>=(3,8) else 1)" 2>/dev/null; then
        PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        success "Python ${PY_VER} ✓"; PYTHON_CMD="python3"; return
    fi
    warn "未找到 Python 3.8+，尝试自动安装..."
    case $OS in
        ubuntu|debian) apt-get install -y python3 python3-pip python3-venv >/dev/null 2>&1 ;;
        *) dnf install -y python3 python3-pip >/dev/null 2>&1 || yum install -y python3 python3-pip >/dev/null 2>&1 ;;
    esac
    PYTHON_CMD="python3"; success "Python 安装完成"
}

# ══════════════════════════════════════════════════════
#  交互配置
# ══════════════════════════════════════════════════════

collect_config() {
    step "配置机器人参数"

    echo ""
    echo -e "${BOLD}① Bot Token${NC}（去 @BotFather → /newbot 创建）"
    echo ""
    while true; do
        read -rp "  Token: " BOT_TOKEN
        BOT_TOKEN=$(echo "$BOT_TOKEN" | tr -d '[:space:]')
        [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{35,}$ ]] && { success "Token ✓"; break; }
        warn "格式不正确，示例: 123456789:ABCdef..."
    done

    echo ""
    echo -e "${BOLD}② 绑定主人的 Telegram 用户 ID${NC}"
    echo -e "   所有用户消息都会转发给这个账号"
    echo -e "   查询方法：给 ${CYAN}@userinfobot${NC} 发任意消息"
    echo ""
    while true; do
        read -rp "  主人 ID: " OWNER_ID
        OWNER_ID=$(echo "$OWNER_ID" | tr -d '[:space:]')
        [[ "$OWNER_ID" =~ ^[0-9]+$ ]] && { success "主人 ID: ${OWNER_ID} ✓"; break; }
        warn "ID 必须是纯数字"
    done

    echo ""
    echo -e "${BOLD}③ 匿名模式${NC}"
    echo -e "   ${GREEN}y${NC} = 匿名  主人只看到匿名编号，不显示真实用户名"
    echo -e "   ${YELLOW}n${NC} = 实名  主人能看到来信者名字和用户名（推荐）"
    echo ""
    read -rp "  启用匿名? [y/N]: " ANON_CHOICE
    if [[ "$ANON_CHOICE" =~ ^[Yy]$ ]]; then
        ANONYMOUS_MODE="True"; info "匿名模式 ✓"
    else
        ANONYMOUS_MODE="False"; info "实名模式 ✓"
    fi
}

# ══════════════════════════════════════════════════════
#  写入文件
# ══════════════════════════════════════════════════════

write_config() {
    cat > "$INSTALL_DIR/config.py" << PYEOF
BOT_TOKEN      = "${BOT_TOKEN}"
OWNER_ID       = ${OWNER_ID}
ANONYMOUS_MODE = ${ANONYMOUS_MODE}
PYEOF
    success "config.py 已写入"
}

write_bot_files() {
    step "写入程序文件"
    mkdir -p "$INSTALL_DIR"

    # ── requirements.txt ──
    cat > "$INSTALL_DIR/requirements.txt" << 'REQEOF'
python-telegram-bot==20.7
REQEOF

    # ── bot.py ──
    cat > "$INSTALL_DIR/bot.py" << 'BOTEOF'
"""
Telegram 客服中转机器人 v2
══════════════════════════════════════════════════════
功能：
  • 任何用户发消息 → 自动转发给主人（卡片式布局）
  • 主人回复转发消息 → 自动转回给原用户
  • 全媒体支持：文字/图片/视频/语音/音频/文件/贴纸/
                视频留言/位置/联系人
  • 屏蔽拉黑：主人可拉黑用户，用户收到提示
  • 会话管理：/end /endall /sessions /r
  • 操作按钮：每条消息附快捷按钮（切换回复/拉黑）
══════════════════════════════════════════════════════
"""

import logging
import sqlite3
import hashlib
from telegram import (
    Update, InlineKeyboardButton, InlineKeyboardMarkup, constants
)
from telegram.ext import (
    Application, CommandHandler, MessageHandler,
    CallbackQueryHandler, ContextTypes, filters,
)
from config import BOT_TOKEN, OWNER_ID, ANONYMOUS_MODE

logging.basicConfig(
    format="%(asctime)s [%(levelname)s] %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

DB_PATH = "chat.db"

def get_db():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db():
    with get_db() as db:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS sessions (
            user_id     INTEGER PRIMARY KEY,
            username    TEXT,
            first_name  TEXT,
            status      TEXT    DEFAULT 'active',
            started_at  TEXT    DEFAULT (datetime('now','localtime')),
            last_msg_at TEXT    DEFAULT (datetime('now','localtime')),
            ended_at    TEXT,
            msg_count   INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS reply_target (
            id      INTEGER PRIMARY KEY CHECK (id=1),
            user_id INTEGER
        );
        CREATE TABLE IF NOT EXISTS msg_map (
            owner_msg_id INTEGER PRIMARY KEY,
            user_id      INTEGER NOT NULL,
            created_at   TEXT DEFAULT (datetime('now','localtime'))
        );
        CREATE TABLE IF NOT EXISTS blocklist (
            user_id    INTEGER PRIMARY KEY,
            blocked_at TEXT DEFAULT (datetime('now','localtime')),
            reason     TEXT
        );
        """)

def upsert_session(user):
    with get_db() as db:
        db.execute("""
            INSERT INTO sessions (user_id, username, first_name, status)
            VALUES (?,?,?,'active')
            ON CONFLICT(user_id) DO UPDATE SET
                username    = excluded.username,
                first_name  = excluded.first_name,
                status      = 'active',
                started_at  = CASE WHEN status != 'active'
                              THEN datetime('now','localtime') ELSE started_at END,
                ended_at    = NULL
        """, (user.id, user.username, user.first_name))

def touch_session(user_id: int):
    with get_db() as db:
        db.execute("""
            UPDATE sessions
            SET last_msg_at = datetime('now','localtime'),
                msg_count   = msg_count + 1
            WHERE user_id = ?
        """, (user_id,))

def open_session_for(user_id: int):
    with get_db() as db:
        db.execute("""
            INSERT INTO sessions (user_id, status) VALUES (?,'active')
            ON CONFLICT(user_id) DO UPDATE SET
                status     = 'active',
                started_at = CASE WHEN status != 'active'
                             THEN datetime('now','localtime') ELSE started_at END,
                ended_at   = NULL
        """, (user_id,))

def close_session(user_id: int):
    with get_db() as db:
        db.execute("""
            UPDATE sessions SET status='closed',
            ended_at=datetime('now','localtime') WHERE user_id=?
        """, (user_id,))

def is_active(user_id: int) -> bool:
    with get_db() as db:
        row = db.execute(
            "SELECT status FROM sessions WHERE user_id=?", (user_id,)
        ).fetchone()
        return row is not None and row["status"] == "active"

def get_session_info(user_id: int):
    with get_db() as db:
        return db.execute(
            "SELECT * FROM sessions WHERE user_id=?", (user_id,)
        ).fetchone()

def get_active_sessions():
    with get_db() as db:
        return db.execute(
            "SELECT * FROM sessions WHERE status='active' ORDER BY last_msg_at DESC"
        ).fetchall()

def set_reply_target(user_id: int):
    with get_db() as db:
        db.execute("""
            INSERT INTO reply_target (id, user_id) VALUES (1,?)
            ON CONFLICT(id) DO UPDATE SET user_id=excluded.user_id
        """, (user_id,))

def get_reply_target():
    with get_db() as db:
        row = db.execute("SELECT user_id FROM reply_target WHERE id=1").fetchone()
        return row["user_id"] if row else None

def clear_reply_target():
    with get_db() as db:
        db.execute("DELETE FROM reply_target WHERE id=1")

def save_msg_map(owner_msg_id: int, user_id: int):
    with get_db() as db:
        db.execute(
            "INSERT OR REPLACE INTO msg_map (owner_msg_id, user_id) VALUES (?,?)",
            (owner_msg_id, user_id),
        )

def lookup_user(owner_msg_id: int):
    with get_db() as db:
        row = db.execute(
            "SELECT user_id FROM msg_map WHERE owner_msg_id=?", (owner_msg_id,)
        ).fetchone()
        return row["user_id"] if row else None

def block_user(user_id: int, reason: str = ""):
    with get_db() as db:
        db.execute(
            "INSERT OR REPLACE INTO blocklist (user_id, reason) VALUES (?,?)",
            (user_id, reason),
        )
        db.execute(
            "UPDATE sessions SET status='blocked' WHERE user_id=?", (user_id,)
        )

def unblock_user(user_id: int):
    with get_db() as db:
        db.execute("DELETE FROM blocklist WHERE user_id=?", (user_id,))
        db.execute(
            "UPDATE sessions SET status='closed'"
            " WHERE user_id=? AND status='blocked'", (user_id,)
        )

def is_blocked(user_id: int) -> bool:
    with get_db() as db:
        return db.execute(
            "SELECT 1 FROM blocklist WHERE user_id=?", (user_id,)
        ).fetchone() is not None

def get_blocklist():
    with get_db() as db:
        return db.execute("""
            SELECT bl.user_id, bl.blocked_at, bl.reason,
                   s.first_name, s.username
            FROM blocklist bl
            LEFT JOIN sessions s ON bl.user_id = s.user_id
            ORDER BY bl.blocked_at DESC
        """).fetchall()

def display_name(user) -> str:
    if ANONYMOUS_MODE:
        tag = hashlib.md5(str(user.id).encode()).hexdigest()[:8].upper()
        return f"匿名用户 #{tag}"
    parts = [p for p in [user.first_name, user.last_name] if p]
    name = " ".join(parts) or f"用户{user.id}"
    if user.username:
        name += f" (@{user.username})"
    return name

def display_name_from_row(row) -> str:
    if ANONYMOUS_MODE:
        tag = hashlib.md5(str(row["user_id"]).encode()).hexdigest()[:8].upper()
        return f"匿名用户 #{tag}"
    name = row["first_name"] or f"用户{row['user_id']}"
    if row["username"]:
        name += f" (@{row['username']})"
    return name

def msg_type_icon(msg) -> str:
    if msg.text:        return "💬"
    if msg.photo:       return "🖼"
    if msg.video:       return "🎬"
    if msg.voice:       return "🎤"
    if msg.audio:       return "🎵"
    if msg.document:    return "📎"
    if msg.sticker:     return "😄"
    if msg.video_note:  return "⭕"
    if msg.location:    return "📍"
    if msg.contact:     return "👤"
    return "📦"

def msg_type_label(msg) -> str:
    labels = {
        "text": "文字", "photo": "图片", "video": "视频",
        "voice": "语音", "audio": "音频", "document": "文件",
        "sticker": "贴纸", "video_note": "视频留言",
        "location": "位置", "contact": "联系人",
    }
    for attr, label in labels.items():
        if getattr(msg, attr, None):
            return label
    return "其他"

async def send_media(bot, chat_id: int, msg, extra_caption: str = ""):
    cap = (msg.caption or "") + extra_caption
    try:
        if msg.text:
            sent = await bot.send_message(chat_id=chat_id, text=msg.text)
        elif msg.photo:
            sent = await bot.send_photo(
                chat_id=chat_id, photo=msg.photo[-1].file_id, caption=cap)
        elif msg.video:
            sent = await bot.send_video(
                chat_id=chat_id, video=msg.video.file_id, caption=cap)
        elif msg.voice:
            sent = await bot.send_voice(
                chat_id=chat_id, voice=msg.voice.file_id, caption=cap)
        elif msg.audio:
            sent = await bot.send_audio(
                chat_id=chat_id, audio=msg.audio.file_id, caption=cap)
        elif msg.document:
            sent = await bot.send_document(
                chat_id=chat_id, document=msg.document.file_id, caption=cap)
        elif msg.sticker:
            sent = await bot.send_sticker(
                chat_id=chat_id, sticker=msg.sticker.file_id)
        elif msg.video_note:
            sent = await bot.send_video_note(
                chat_id=chat_id, video_note=msg.video_note.file_id)
        elif msg.location:
            sent = await bot.send_location(
                chat_id=chat_id,
                latitude=msg.location.latitude,
                longitude=msg.location.longitude)
        elif msg.contact:
            sent = await bot.send_contact(
                chat_id=chat_id,
                phone_number=msg.contact.phone_number,
                first_name=msg.contact.first_name,
                last_name=msg.contact.last_name or "")
        else:
            return None
        return sent.message_id
    except Exception as e:
        logger.error("send_media → chat_id=%s err=%s", chat_id, e)
        return None

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id == OWNER_ID:
        await update.message.reply_html(
            "🤖 <b>客服中转机器人 v2 已就绪</b>\n"
            "══════════════════════════\n"
            "📥 用户发来消息后你会收到卡片通知\n\n"
            "<b>📨 回复方式：</b>\n"
            "  ➤ 直接<b>回复</b>转发消息（推荐）\n"
            "  ➤ /r 用户ID — 手动指定，再直接发\n\n"
            "<b>📋 会话：</b>  /sessions · /end · /endall\n"
            "<b>🚫 黑名单：</b>/block · /unblock · /blocklist\n"
            "<b>❓ 帮助：</b>  /help"
        )
    else:
        if is_blocked(user.id):
            await update.message.reply_text("⚠️ 你无法使用此服务。")
            return
        upsert_session(user)
        await update.message.reply_html(
            f"👋 你好，<b>{user.first_name}</b>！\n\n"
            "直接发消息给我，我会帮你转达。\n"
            "对方回复后，我也会发给你。\n\n"
            "支持：文字、图片、视频、语音、文件等。\n\n"
            "/end — 结束对话   /help — 帮助"
        )

async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id == OWNER_ID:
        await update.message.reply_html(
            "📖 <b>主人操作手册</b>\n"
            "══════════════════════════\n\n"
            "<b>📨 回复用户：</b>\n"
            "  长按转发消息 → 回复（自动识别用户）\n"
            "  <code>/r 用户ID</code> 手动指定，之后直接发消息\n\n"
            "<b>📋 会话管理：</b>\n"
            "  <code>/sessions</code>         查看活跃用户列表\n"
            "  <code>/r</code>                查看当前回复目标\n"
            "  <code>/r 用户ID</code>         切换回复目标\n"
            "  <code>/end 用户ID</code>       结束某用户对话\n"
            "  <code>/endall</code>           结束全部对话\n\n"
            "<b>🚫 黑名单：</b>\n"
            "  <code>/block 用户ID [原因]</code>  拉黑\n"
            "  <code>/unblock 用户ID</code>        解除拉黑\n"
            "  <code>/blocklist</code>             查看黑名单\n\n"
            "<b>📦 支持媒体类型：</b>\n"
            "  文字 · 图片 · 视频 · 语音 · 音频\n"
            "  文件 · 贴纸 · 视频留言 · 位置 · 联系人"
        )
    else:
        await update.message.reply_html(
            "📖 <b>使用说明</b>\n"
            "══════════════════════════\n\n"
            "直接发任意消息给我，我会转达给对方。\n"
            "支持：文字、图片、视频、语音、文件等。\n\n"
            "/end  — 结束当前对话\n"
            "/start — 重新开始"
        )

async def cmd_end(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id == OWNER_ID:
        if context.args and context.args[0].isdigit():
            uid = int(context.args[0])
        else:
            uid = get_reply_target()
        if not uid:
            await update.message.reply_text("❌ 请指定用户 ID\n用法: /end 用户ID"); return
        close_session(uid)
        if get_reply_target() == uid:
            clear_reply_target()
        await update.message.reply_html(f"✅ 已结束与用户 <code>{uid}</code> 的对话。")
        try:
            await context.bot.send_message(
                chat_id=uid,
                text="📴 对话已结束。\n如需再次联系，直接发消息即可重新开始。",
            )
        except Exception: pass
    else:
        if not is_active(user.id):
            await update.message.reply_text("❌ 你当前没有活跃的对话。"); return
        close_session(user.id)
        await update.message.reply_text("✅ 对话已结束。\n如需再次联系，直接发消息即可重新开始。")
        try:
            await context.bot.send_message(
                chat_id=OWNER_ID,
                text=(
                    "📴 <b>用户主动结束了对话</b>\n"
                    "━━━━━━━━━━━━━━━━━━\n"
                    f"👤 {display_name(user)}\n"
                    f"🆔 <code>{user.id}</code>"
                ),
                parse_mode=constants.ParseMode.HTML,
            )
        except Exception: pass

async def cmd_endall(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    rows = get_active_sessions()
    with get_db() as db:
        db.execute(
            "UPDATE sessions SET status='closed',"
            " ended_at=datetime('now','localtime') WHERE status='active'"
        )
    clear_reply_target()
    for row in rows:
        try:
            await context.bot.send_message(
                chat_id=row["user_id"],
                text="📴 对话已结束。\n如需再次联系，直接发消息即可重新开始。",
            )
        except Exception: pass
    await update.message.reply_text(f"✅ 已结束全部 {len(rows)} 个活跃对话。")

async def cmd_sessions(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    rows = get_active_sessions()
    if not rows:
        await update.message.reply_text("💤 当前没有活跃用户。"); return
    current = get_reply_target()
    lines = [f"💬 <b>活跃会话（{len(rows)} 个）</b>", "━━━━━━━━━━━━━━━━━━"]
    for r in rows:
        name = display_name_from_row(r)
        marker = "  ◀ 当前回复目标" if r["user_id"] == current else ""
        lines.append(
            f"• <b>{name}</b>{marker}\n"
            f"  🆔 <code>{r['user_id']}</code>  "
            f"📨 {r['msg_count']} 条  "
            f"🕐 {r['last_msg_at']}"
        )
    lines += ["━━━━━━━━━━━━━━━━━━", "回复转发消息，或 /r 用户ID 切换目标"]
    await update.message.reply_html("\n".join(lines))

async def cmd_r(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    if not context.args:
        current = get_reply_target()
        if current:
            row = get_session_info(current)
            name = display_name_from_row(row) if row else f"用户{current}"
            await update.message.reply_html(
                f"🎯 <b>当前回复目标</b>\n"
                f"━━━━━━━━━━━━━━━━━━\n"
                f"👤 {name}\n"
                f"🆔 <code>{current}</code>\n\n"
                f"切换: /r 用户ID"
            )
        else:
            await update.message.reply_text(
                "❌ 尚未选定回复对象\n用法: /r 用户ID\n或直接回复某条转发消息"
            )
        return
    if not context.args[0].isdigit():
        await update.message.reply_text("❌ 用法: /r 用户ID（纯数字）"); return
    uid = int(context.args[0])
    set_reply_target(uid)
    row = get_session_info(uid)
    name = display_name_from_row(row) if row else f"用户{uid}"
    status_str = "✅ 活跃中" if is_active(uid) else "⚠️ 无活跃会话（发消息将自动重开）"
    await update.message.reply_html(
        f"🎯 <b>已切换回复目标</b>\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"👤 {name}\n"
        f"🆔 <code>{uid}</code>  {status_str}\n\n"
        f"现在直接发消息即可发给 ta。"
    )

async def cmd_block(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("用法: /block 用户ID [原因]\n示例: /block 123456 广告骚扰"); return
    uid = int(context.args[0])
    reason = " ".join(context.args[1:]) if len(context.args) > 1 else ""
    block_user(uid, reason)
    if get_reply_target() == uid:
        clear_reply_target()
    try:
        await context.bot.send_message(chat_id=uid, text="⛔ 你已被禁止使用此服务。")
    except Exception: pass
    await update.message.reply_html(
        f"🚫 <b>已拉黑用户</b>\n"
        f"━━━━━━━━━━━━━━━━━━\n"
        f"🆔 <code>{uid}</code>"
        + (f"\n📝 原因: {reason}" if reason else "")
        + f"\n\n解除: /unblock {uid}"
    )

async def cmd_unblock(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("用法: /unblock 用户ID"); return
    uid = int(context.args[0])
    if not is_blocked(uid):
        await update.message.reply_html(f"⚠️ 用户 <code>{uid}</code> 不在黑名单中。"); return
    unblock_user(uid)
    try:
        await context.bot.send_message(chat_id=uid, text="✅ 你已被解除限制，可以重新发送消息。")
    except Exception: pass
    await update.message.reply_html(f"✅ 已解除用户 <code>{uid}</code> 的拉黑。")

async def cmd_blocklist(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。"); return
    rows = get_blocklist()
    if not rows:
        await update.message.reply_text("✅ 黑名单为空。"); return
    lines = [f"🚫 <b>黑名单（{len(rows)} 人）</b>", "━━━━━━━━━━━━━━━━━━"]
    for r in rows:
        name = r["first_name"] or f"用户{r['user_id']}"
        if r["username"]: name += f" (@{r['username']})"
        lines.append(
            f"• <b>{name}</b>\n"
            f"  🆔 <code>{r['user_id']}</code>  🕐 {r['blocked_at']}"
            + (f"\n  📝 {r['reason']}" if r["reason"] else "")
        )
    lines += ["━━━━━━━━━━━━━━━━━━", "解除: /unblock 用户ID"]
    await update.message.reply_html("\n".join(lines))

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    msg  = update.message
    if msg is None:
        return

    if user.id == OWNER_ID:
        target_uid = None
        if msg.reply_to_message:
            target_uid = lookup_user(msg.reply_to_message.message_id)
            if target_uid:
                set_reply_target(target_uid)
        if target_uid is None:
            target_uid = get_reply_target()
        if target_uid is None:
            await msg.reply_html(
                "⚠️ <b>未选定回复对象</b>\n\n"
                "请<b>回复</b>某条转发消息，\n"
                "或用 /r 用户ID 指定目标。"
            ); return
        if is_blocked(target_uid):
            await msg.reply_html(
                f"⛔ 用户 <code>{target_uid}</code> 已被拉黑，无法发送。\n"
                f"解除: /unblock {target_uid}"
            ); return
        open_session_for(target_uid)
        sent_id = await send_media(context.bot, target_uid, msg)
        if sent_id is not None:
            await msg.reply_text("✓ 已发送", quote=True)
        else:
            await msg.reply_html("❌ 发送失败\n可能原因：对方已屏蔽机器人或账号不存在")
        return

    if is_blocked(user.id):
        await msg.reply_text("⛔ 你无法使用此服务。")
        return

    upsert_session(user)
    touch_session(user.id)

    icon  = msg_type_icon(msg)
    mtype = msg_type_label(msg)

    header_text = (
        f"┌─ 📨 <b>新消息</b>  {icon} {mtype}\n"
        f"│  👤 {display_name(user)}\n"
    )
    if not ANONYMOUS_MODE:
        header_text += f"│  🆔 <code>{user.id}</code>\n"
    header_text += "└─────────────────────"

    try:
        header_msg = await context.bot.send_message(
            chat_id=OWNER_ID,
            text=header_text,
            parse_mode=constants.ParseMode.HTML,
        )
        content_id = await send_media(context.bot, OWNER_ID, msg)
        kb = InlineKeyboardMarkup([[
            InlineKeyboardButton("🎯 回复此人", callback_data=f"target_{user.id}"),
            InlineKeyboardButton("🚫 拉黑",     callback_data=f"block_{user.id}"),
        ]])
        action_msg = await context.bot.send_message(
            chat_id=OWNER_ID,
            text=f"↑ 回复: /r <code>{user.id}</code>   结束: /end <code>{user.id}</code>",
            parse_mode=constants.ParseMode.HTML,
            reply_markup=kb,
        )
        for mid in [header_msg.message_id, content_id, action_msg.message_id]:
            if mid:
                save_msg_map(mid, user.id)
    except Exception as e:
        logger.error("转发给主人失败: %s", e)
        await msg.reply_text("❌ 消息发送失败，请稍后重试。")
        return

    await msg.reply_text("✅ 消息已发送，等待回复…", quote=True)

async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    if query.from_user.id != OWNER_ID:
        await query.answer("❌ 无权操作", show_alert=True); return
    data = query.data
    if data.startswith("target_"):
        uid = int(data.split("_")[1])
        set_reply_target(uid)
        row  = get_session_info(uid)
        name = display_name_from_row(row) if row else f"用户{uid}"
        await query.edit_message_text(
            f"🎯 <b>已切换回复目标</b>\n"
            f"━━━━━━━━━━━━━━━━━━\n"
            f"👤 {name}\n"
            f"🆔 <code>{uid}</code>\n\n"
            f"直接发消息即可回复 ta。\n"
            f"/end <code>{uid}</code> 结束  /block <code>{uid}</code> 拉黑",
            parse_mode=constants.ParseMode.HTML,
        )
    elif data.startswith("block_"):
        uid = int(data.split("_")[1])
        block_user(uid)
        if get_reply_target() == uid:
            clear_reply_target()
        try:
            await context.bot.send_message(chat_id=uid, text="⛔ 你已被禁止使用此服务。")
        except Exception: pass
        await query.edit_message_text(
            f"🚫 <b>已拉黑用户</b>\n"
            f"🆔 <code>{uid}</code>\n\n"
            f"解除: /unblock <code>{uid}</code>",
            parse_mode=constants.ParseMode.HTML,
        )

def main():
    init_db()
    app = Application.builder().token(BOT_TOKEN).build()
    for name, handler in [
        ("start",     cmd_start),
        ("help",      cmd_help),
        ("end",       cmd_end),
        ("endall",    cmd_endall),
        ("sessions",  cmd_sessions),
        ("r",         cmd_r),
        ("block",     cmd_block),
        ("unblock",   cmd_unblock),
        ("blocklist", cmd_blocklist),
    ]:
        app.add_handler(CommandHandler(name, handler))
    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, handle_message))
    logger.info("🤖 机器人启动 | 主人ID=%s | 匿名=%s", OWNER_ID, ANONYMOUS_MODE)
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTEOF

    success "程序文件写入完成"
}

# ══════════════════════════════════════════════════════
#  安装流程子步骤
# ══════════════════════════════════════════════════════

setup_venv() {
    step "创建 Python 虚拟环境 & 安装依赖"
    cd "$INSTALL_DIR"
    $PYTHON_CMD -m venv venv >/dev/null 2>&1
    source venv/bin/activate
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
    success "依赖安装完成 (python-telegram-bot 20.7)"
}

create_service() {
    step "创建 systemd 服务"
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Telegram Relay Chat Bot v2
After=network.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/bot.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    success "服务已创建并设置开机自启: ${SERVICE_NAME}"
}

create_manage_script() {
    cat > /usr/local/bin/tgbot << EOF
#!/bin/bash
case "\$1" in
    start)     systemctl start ${SERVICE_NAME}   && echo "✅ 已启动" ;;
    stop)      systemctl stop ${SERVICE_NAME}    && echo "⏹ 已停止" ;;
    restart)   systemctl restart ${SERVICE_NAME} && echo "🔄 已重启" ;;
    status)    systemctl status ${SERVICE_NAME} ;;
    log)       journalctl -u ${SERVICE_NAME} -f ;;
    uninstall)
        systemctl stop ${SERVICE_NAME} 2>/dev/null
        systemctl disable ${SERVICE_NAME} 2>/dev/null
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        rm -rf ${INSTALL_DIR}
        rm -f /usr/local/bin/tgbot
        systemctl daemon-reload
        echo "✅ 已卸载"
        ;;
    *) echo "用法: tgbot {start|stop|restart|status|log|uninstall}" ;;
esac
EOF
    chmod +x /usr/local/bin/tgbot
    success "管理快捷命令已安装: tgbot"
}

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       🎉  安装完成！客服中转机器人 v2 已就绪        ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}安装目录:${NC}   ${INSTALL_DIR}"
    echo -e "  ${BOLD}主人 ID:${NC}    ${OWNER_ID}"
    echo -e "  ${BOLD}匿名模式:${NC}   ${ANONYMOUS_MODE}"
    echo ""
    echo -e "  ${BOLD}── 快捷命令 ────────────────────────────────${NC}"
    echo -e "    ${CYAN}tgbot start${NC}      启动     ${CYAN}tgbot stop${NC}    停止"
    echo -e "    ${CYAN}tgbot restart${NC}    重启     ${CYAN}tgbot log${NC}     实时日志"
    echo -e "    ${CYAN}tgbot status${NC}     状态     ${CYAN}tgbot uninstall${NC} 卸载"
    echo ""
    echo -e "  ${GREEN}${BOLD}➜ 去 Telegram 找你的机器人，发 /start 开始！${NC}"
    echo ""
}

# ══════════════════════════════════════════════════════
#  菜单动作
# ══════════════════════════════════════════════════════

action_fresh_install() {
    if [ -d "$INSTALL_DIR" ]; then
        warn "检测到已有安装目录: ${INSTALL_DIR}"
        read -rp "  覆盖安装（保留数据库）？[y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "已取消。"; return; }
        # 停止旧服务
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi
    detect_os
    install_system_deps
    check_python
    collect_config
    write_bot_files
    write_config
    setup_venv
    create_service
    create_manage_script
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "机器人启动成功！"
    else
        warn "启动可能有问题，请选择「查看实时日志」排查。"
    fi
    print_summary
    press_any_key
}

action_reconfig() {
    check_installed
    warn "重新配置将覆盖 config.py，不影响聊天记录数据库。"
    echo ""
    collect_config
    write_config
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    success "配置已更新，服务已重启。"
    press_any_key
}

action_update_files() {
    check_installed
    warn "更新程序文件（bot.py / requirements.txt），config.py 和数据库不受影响。"
    read -rp "  确认更新？[y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "已取消。"; return; }
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    detect_os
    check_python
    write_bot_files
    # 重新安装依赖（版本可能变化）
    cd "$INSTALL_DIR"
    source venv/bin/activate 2>/dev/null || {
        $PYTHON_CMD -m venv venv >/dev/null 2>&1
        source venv/bin/activate
    }
    pip install -q --upgrade pip
    pip install -q -r requirements.txt
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "程序更新完成，机器人已重新启动！"
    else
        warn "启动可能有问题，请选择「查看实时日志」排查。"
    fi
    press_any_key
}

action_start() {
    check_service_exists
    systemctl start "$SERVICE_NAME" && success "机器人已启动。" || warn "启动失败，请查看日志。"
    press_any_key
}

action_stop() {
    check_service_exists
    systemctl stop "$SERVICE_NAME" && success "机器人已停止。" || warn "停止失败。"
    press_any_key
}

action_restart() {
    check_service_exists
    systemctl restart "$SERVICE_NAME" && success "机器人已重启。" || warn "重启失败，请查看日志。"
    press_any_key
}

action_status() {
    check_service_exists
    echo ""
    systemctl status "$SERVICE_NAME" --no-pager
    echo ""
    press_any_key
}

action_log() {
    check_service_exists
    echo ""
    info "按 Ctrl+C 退出日志查看"
    echo ""
    journalctl -u "$SERVICE_NAME" -f --no-pager
}

action_show_config() {
    check_installed
    echo ""
    echo -e "${BOLD}${CYAN}── 当前配置 (${INSTALL_DIR}/config.py) ──${NC}"
    echo ""
    # 脱敏显示 Token
    if [ -f "$INSTALL_DIR/config.py" ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ BOT_TOKEN ]]; then
                token_val=$(echo "$line" | grep -oP '(?<=")[^"]+(?=")')
                prefix="${token_val%%:*}"
                echo "  BOT_TOKEN      = \"${prefix}:****** (已隐藏)\""
            else
                echo "  $line"
            fi
        done < "$INSTALL_DIR/config.py"
    else
        warn "config.py 不存在。"
    fi
    echo ""
    # 数据库简报
    if [ -f "$INSTALL_DIR/chat.db" ]; then
        echo -e "${BOLD}── 数据库简报 ──${NC}"
        python3 - << 'PYEOF' 2>/dev/null || true
import sqlite3, os
db = sqlite3.connect("/opt/tg-relay-bot/chat.db")
try:
    total   = db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
    active  = db.execute("SELECT COUNT(*) FROM sessions WHERE status='active'").fetchone()[0]
    blocked = db.execute("SELECT COUNT(*) FROM blocklist").fetchone()[0]
    msgs    = db.execute("SELECT SUM(msg_count) FROM sessions").fetchone()[0] or 0
    print(f"  总用户数: {total}  |  活跃会话: {active}  |  黑名单: {blocked}  |  累计消息: {msgs}")
except Exception as e:
    print(f"  无法读取: {e}")
PYEOF
    fi
    echo ""
    press_any_key
}

action_uninstall() {
    echo ""
    echo -e "${RED}${BOLD}⚠️  警告：此操作将删除所有文件，包括聊天记录数据库！${NC}"
    echo ""
    read -rp "  输入 YES 确认卸载（其他任意键取消）: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        info "已取消。"; press_any_key; return
    fi
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/tgbot
    systemctl daemon-reload
    success "卸载完成，所有文件已删除。"
    press_any_key
}

press_any_key() {
    echo ""
    read -rp "  按 Enter 返回主菜单…" _
}

# ══════════════════════════════════════════════════════
#  主入口
# ══════════════════════════════════════════════════════

main() {
    check_root

    while true; do
        clear
        banner
        show_menu
        read -rp "  请输入选项 [0-10]: " CHOICE
        echo ""

        case "$CHOICE" in
            1)  action_fresh_install ;;
            2)  action_reconfig ;;
            3)  action_update_files ;;
            4)  action_start ;;
            5)  action_stop ;;
            6)  action_restart ;;
            7)  action_status ;;
            8)  action_log ;;
            9)  action_show_config ;;
            10) action_uninstall ;;
            0)
                echo -e "${GREEN}再见！${NC}"
                echo ""
                exit 0
                ;;
            *)
                warn "无效选项，请输入 0-10 之间的数字。"
                sleep 1
                ;;
        esac
    done
}

main
