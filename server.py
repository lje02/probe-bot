"""
探针机器人 - 服务端
职责：
  1. 接收各节点 Agent 上报的数据（HTTP POST /report）
  2. 判断节点是否离线、资源是否超阈值，并主动推送报警到 Telegram
  3. 提供 Telegram 命令查询：/status /node /traffic

运行：
  1. 修改 config.py 里的 BOT_TOKEN / CHAT_ID / AUTH_TOKEN / 阈值
  2. pip install -r requirements_server.txt
  3. python server.py
"""

import asyncio
import hmac
import html
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
)

import config

# ---------------------------------------------------------------------------
# 内存状态存储：{node_id: {...}}
# 不落库，重启后清空，重新等节点上报（符合"只看实时状态"的需求）
# ---------------------------------------------------------------------------
NODES: dict[str, dict] = {}

# 记录每个节点当前是否处于"已报警"状态，避免同一问题反复刷屏
ALERT_STATE: dict[str, dict] = {}

# 待"立即刷新"的节点集合 —— 点刷新按钮时把 node_id 放进来，
# Agent 每隔几秒会主动来问一次"要不要立刻上报"，问到了就会被取走（一次性）
PENDING_REFRESH: set[str] = set()


def request_refresh(node_id: str):
    PENDING_REFRESH.add(node_id)


def fmt_bytes_per_sec(v: float) -> str:
    if v > 1024 * 1024:
        return f"{v / 1024 / 1024:.1f}MB/s"
    if v > 1024:
        return f"{v / 1024:.1f}KB/s"
    return f"{v:.0f}B/s"


def node_line(node_id: str) -> str:
    n = NODES[node_id]
    name = html.escape(n["name"])
    online = (time.time() - n["last_seen"]) < config.OFFLINE_THRESHOLD_SEC
    icon = "🟢" if online else "🔴"
    if not online:
        return f"{icon} {name}  (失联 {int(time.time() - n['last_seen'])}s)"
    return (
        f"{icon} {name}  CPU {n['cpu']:.0f}%  MEM {n['mem']:.0f}%  "
        f"DISK {n['disk']:.0f}%  ⬆{fmt_bytes_per_sec(n['net_up'])} "
        f"⬇{fmt_bytes_per_sec(n['net_down'])}"
    )


# ---------------------------------------------------------------------------
# Telegram Bot 部分
# ---------------------------------------------------------------------------
bot_app: Application = None  # 在 lifespan 里初始化


# ---------------------------------------------------------------------------
# 文本内容构建（供"命令"和"按钮回调"两种入口共用）
# ---------------------------------------------------------------------------
def build_status_text() -> str:
    if not NODES:
        return "暂无节点上报数据。"
    online_cnt = sum(
        1 for n in NODES.values()
        if time.time() - n["last_seen"] < config.OFFLINE_THRESHOLD_SEC
    )
    lines = [f"<b>📊 节点状态</b>  ({online_cnt}/{len(NODES)} 在线)\n"]
    for node_id in sorted(NODES, key=lambda k: NODES[k]["name"]):
        lines.append(node_line(node_id))
    return "\n".join(lines)


def build_traffic_text() -> str:
    if not NODES:
        return "暂无数据。"
    lines = ["<b>📈 流量统计</b>  <i>(累计, 自 Agent 启动)</i>\n"]
    for node_id in sorted(NODES, key=lambda k: NODES[k]["name"]):
        n = NODES[node_id]
        lines.append(
            f"• {html.escape(n['name'])}：⬆ {n['net_sent_total'] / 1024**3:.2f}GB"
            f"　⬇ {n['net_recv_total'] / 1024**3:.2f}GB"
        )
    return "\n".join(lines)


def build_node_text(node_id: str) -> str:
    n = NODES[node_id]
    online = time.time() - n["last_seen"] < config.OFFLINE_THRESHOLD_SEC
    return (
        f"<b>🖥 {html.escape(n['name'])}</b>\n\n"
        f"状态　　{'🟢 在线' if online else '🔴 离线'}\n"
        f"CPU　　 {n['cpu']:.1f}%\n"
        f"内存　　{n['mem']:.1f}%\n"
        f"磁盘　　{n['disk']:.1f}%\n"
        f"上行　　{fmt_bytes_per_sec(n['net_up'])}\n"
        f"下行　　{fmt_bytes_per_sec(n['net_down'])}\n"
        f"运行时长 {n['uptime'] / 3600:.1f} 小时\n"
        f"最后上报 {int(time.time() - n['last_seen'])} 秒前"
    )


def build_help_text() -> str:
    return (
        "<b>ℹ️ 使用说明</b>\n\n"
        "点击下方按钮查看节点状态、流量统计，或用命令：\n"
        "/status — 所有节点一览\n"
        "/traffic — 累计流量\n"
        "/node &lt;节点名&gt; — 单节点详情\n"
        "/remove &lt;节点名&gt; — 摘除节点\n\n"
        "节点详情页有「🗑 摘除节点」按钮，需二次确认才会真正删除。\n"
        "长期离线（默认 7 天）的节点会自动清理，无需手动处理。\n"
        "摘除/清理后如果该节点重新上报，会自动再次出现在列表里。\n\n"
        "节点异常（离线 / 高负载）时会自动推送提醒，无需手动查询。"
    )


# ---------------------------------------------------------------------------
# 按钮布局
# ---------------------------------------------------------------------------
def main_menu_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("📊 节点状态", callback_data="menu:status"),
            InlineKeyboardButton("📈 流量统计", callback_data="menu:traffic"),
        ],
        [
            InlineKeyboardButton("🗂 节点列表", callback_data="menu:nodes"),
            InlineKeyboardButton("ℹ️ 帮助", callback_data="menu:help"),
        ],
    ])


def status_view_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("🔄 刷新", callback_data="force:status"),
            InlineKeyboardButton("⬅️ 返回", callback_data="menu:main"),
        ],
    ])


def traffic_view_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("🔄 刷新", callback_data="force:traffic"),
            InlineKeyboardButton("⬅️ 返回", callback_data="menu:main"),
        ],
    ])


def nodes_list_kb() -> InlineKeyboardMarkup:
    rows = []
    sorted_ids = sorted(NODES, key=lambda k: NODES[k]["name"])
    # 每行放 2 个节点按钮
    for i in range(0, len(sorted_ids), 2):
        row = []
        for nid in sorted_ids[i:i + 2]:
            n = NODES[nid]
            online = time.time() - n["last_seen"] < config.OFFLINE_THRESHOLD_SEC
            icon = "🟢" if online else "🔴"
            row.append(InlineKeyboardButton(f"{icon} {n['name']}", callback_data=f"node:{nid}"))
        rows.append(row)
    rows.append([InlineKeyboardButton("⬅️ 返回", callback_data="menu:main")])
    return InlineKeyboardMarkup(rows)


def node_detail_kb(node_id: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("🔄 刷新", callback_data=f"force:node:{node_id}"),
            InlineKeyboardButton("⬅️ 返回列表", callback_data="menu:nodes"),
        ],
        [
            InlineKeyboardButton("🗑 摘除节点", callback_data=f"remove_ask:{node_id}"),
        ],
    ])


def remove_confirm_kb(node_id: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("✅ 确认摘除", callback_data=f"remove_do:{node_id}"),
            InlineKeyboardButton("❌ 取消", callback_data=f"node:{node_id}"),
        ],
    ])


def remove_node(node_id: str):
    NODES.pop(node_id, None)
    ALERT_STATE.pop(node_id, None)
    PENDING_REFRESH.discard(node_id)


# ---------------------------------------------------------------------------
# 命令入口（/start /status /traffic /node）
# ---------------------------------------------------------------------------
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "<b>🛰 探针机器人控制台</b>\n请选择要查看的内容：",
        parse_mode=ParseMode.HTML,
        reply_markup=main_menu_kb(),
    )


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        build_status_text(), parse_mode=ParseMode.HTML, reply_markup=status_view_kb()
    )


async def cmd_traffic(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        build_traffic_text(), parse_mode=ParseMode.HTML, reply_markup=traffic_view_kb()
    )


async def cmd_node(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text(
            "请选择要查看的节点：", reply_markup=nodes_list_kb()
        )
        return
    name = " ".join(context.args)
    matched = [nid for nid, n in NODES.items() if n["name"] == name]
    if not matched:
        await update.message.reply_text(f"未找到节点: {name}")
        return
    nid = matched[0]
    await update.message.reply_text(
        build_node_text(nid), parse_mode=ParseMode.HTML, reply_markup=node_detail_kb(nid)
    )


async def cmd_remove(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("用法: /remove <节点名称>")
        return
    name = " ".join(context.args)
    matched = [nid for nid, n in NODES.items() if n["name"] == name]
    if not matched:
        await update.message.reply_text(f"未找到节点: {name}")
        return
    nid = matched[0]
    await update.message.reply_text(
        f"确定要摘除节点 <b>{html.escape(name)}</b> 吗？\n"
        f"（摘除后如果该节点重新上报会自动再次出现）",
        parse_mode=ParseMode.HTML,
        reply_markup=remove_confirm_kb(nid),
    )


# ---------------------------------------------------------------------------
# 按钮回调入口 —— 点击后原地编辑消息，而不是发新消息，体验更像一个"面板"
# ---------------------------------------------------------------------------
async def on_button_click(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()  # 消除按钮上的加载圈
    data = query.data

    if data == "menu:main":
        await query.edit_message_text(
            "<b>🛰 探针机器人控制台</b>\n请选择要查看的内容：",
            parse_mode=ParseMode.HTML,
            reply_markup=main_menu_kb(),
        )
    elif data == "menu:status":
        await query.edit_message_text(
            build_status_text(), parse_mode=ParseMode.HTML, reply_markup=status_view_kb()
        )
    elif data == "menu:traffic":
        await query.edit_message_text(
            build_traffic_text(), parse_mode=ParseMode.HTML, reply_markup=traffic_view_kb()
        )
    elif data == "menu:nodes":
        if not NODES:
            await query.edit_message_text("暂无节点上报数据。", reply_markup=main_menu_kb())
        else:
            await query.edit_message_text(
                "<b>🗂 节点列表</b>\n点击查看详情：",
                parse_mode=ParseMode.HTML,
                reply_markup=nodes_list_kb(),
            )
    elif data == "menu:help":
        await query.edit_message_text(
            build_help_text(), parse_mode=ParseMode.HTML, reply_markup=status_view_kb()
        )
    elif data.startswith("node:"):
        nid = data.split(":", 1)[1]
        if nid not in NODES:
            await query.edit_message_text("该节点数据已不存在。", reply_markup=nodes_list_kb())
        else:
            await query.edit_message_text(
                build_node_text(nid), parse_mode=ParseMode.HTML, reply_markup=node_detail_kb(nid)
            )
    elif data.startswith("remove_ask:"):
        nid = data.split(":", 1)[1]
        if nid not in NODES:
            await query.edit_message_text("该节点数据已不存在。", reply_markup=nodes_list_kb())
        else:
            name = html.escape(NODES[nid]["name"])
            await query.edit_message_text(
                f"确定要摘除节点 <b>{name}</b> 吗？\n"
                f"（摘除后如果该节点重新上报会自动再次出现）",
                parse_mode=ParseMode.HTML,
                reply_markup=remove_confirm_kb(nid),
            )
    elif data.startswith("remove_do:"):
        nid = data.split(":", 1)[1]
        name = html.escape(NODES[nid]["name"]) if nid in NODES else nid
        remove_node(nid)
        await query.edit_message_text(
            f"🗑 已摘除节点 <b>{name}</b>",
            parse_mode=ParseMode.HTML,
            reply_markup=nodes_list_kb(),
        )
    elif data == "force:status":
        if NODES:
            await query.edit_message_text("⏳ 正在请求节点立即上报，请稍候…")
            for nid in NODES:
                request_refresh(nid)
            await asyncio.sleep(config.FORCE_REFRESH_WAIT_SEC)
        await query.edit_message_text(
            build_status_text(), parse_mode=ParseMode.HTML, reply_markup=status_view_kb()
        )
    elif data == "force:traffic":
        if NODES:
            await query.edit_message_text("⏳ 正在请求节点立即上报，请稍候…")
            for nid in NODES:
                request_refresh(nid)
            await asyncio.sleep(config.FORCE_REFRESH_WAIT_SEC)
        await query.edit_message_text(
            build_traffic_text(), parse_mode=ParseMode.HTML, reply_markup=traffic_view_kb()
        )
    elif data.startswith("force:node:"):
        nid = data.split(":", 2)[2]
        if nid not in NODES:
            await query.edit_message_text("该节点数据已不存在。", reply_markup=nodes_list_kb())
        else:
            name = html.escape(NODES[nid]["name"])
            await query.edit_message_text(f"⏳ 正在请求 {name} 立即上报，请稍候…")
            request_refresh(nid)
            await asyncio.sleep(config.FORCE_REFRESH_WAIT_SEC)
            if nid in NODES:
                await query.edit_message_text(
                    build_node_text(nid), parse_mode=ParseMode.HTML, reply_markup=node_detail_kb(nid)
                )
            else:
                await query.edit_message_text("节点已不存在或已被摘除。", reply_markup=nodes_list_kb())


async def send_alert(text: str):
    if bot_app is None:
        return
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("📊 查看状态", callback_data="menu:status")]])
    await bot_app.bot.send_message(
        chat_id=config.CHAT_ID, text=text, parse_mode=ParseMode.HTML, reply_markup=kb
    )


# ---------------------------------------------------------------------------
# 后台任务：定期检查离线 & 阈值报警
# ---------------------------------------------------------------------------
async def monitor_loop():
    while True:
        await asyncio.sleep(config.CHECK_INTERVAL_SEC)
        now = time.time()
        for nid, n in list(NODES.items()):
            name = html.escape(n["name"])

            # 长期离线自动清理（默认 7 天，避免列表里堆一堆早就废弃的节点）
            if now - n["last_seen"] > config.STALE_REMOVE_SEC:
                remove_node(nid)
                await send_alert(f"🗑 <b>[自动清理]</b> {name} 已离线超过 {config.STALE_REMOVE_SEC // 86400} 天，已自动从列表移除")
                continue

            state = ALERT_STATE.setdefault(nid, {"offline": False, "high_load": False})
            is_offline = now - n["last_seen"] > config.OFFLINE_THRESHOLD_SEC

            # 离线检测
            if is_offline and not state["offline"]:
                state["offline"] = True
                await send_alert(f"🔴 <b>[宕机报警]</b> {name} 已 {config.OFFLINE_THRESHOLD_SEC}s 无上报，疑似离线")
            elif not is_offline and state["offline"]:
                state["offline"] = False
                await send_alert(f"🟢 <b>[恢复]</b> {name} 已恢复上报")

            # 高负载检测（离线时不重复判断）
            if not is_offline:
                high = n["cpu"] > config.CPU_THRESHOLD or n["mem"] > config.MEM_THRESHOLD
                if high and not state["high_load"]:
                    state["high_load"] = True
                    await send_alert(
                        f"🔥 <b>[高负载]</b> {name} CPU {n['cpu']:.0f}% MEM {n['mem']:.0f}%"
                    )
                elif not high and state["high_load"]:
                    state["high_load"] = False
                    await send_alert(f"✅ <b>[恢复]</b> {name} 负载已恢复正常")


# ---------------------------------------------------------------------------
# 上报数据的校验模型 —— 字段缺失/类型不对时，返回清晰的 422 而不是裸 500
# ---------------------------------------------------------------------------
class ReportPayload(BaseModel):
    node_id: str
    name: str = ""
    cpu: float
    mem: float
    disk: float
    net_up: float
    net_down: float
    net_sent_total: float
    net_recv_total: float
    uptime: float


# ---------------------------------------------------------------------------
# FastAPI 部分：接收 Agent 上报
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global bot_app
    bot_app = Application.builder().token(config.BOT_TOKEN).build()
    bot_app.add_handler(CommandHandler("start", cmd_start))
    bot_app.add_handler(CommandHandler("menu", cmd_start))
    bot_app.add_handler(CommandHandler("status", cmd_status))
    bot_app.add_handler(CommandHandler("node", cmd_node))
    bot_app.add_handler(CommandHandler("traffic", cmd_traffic))
    bot_app.add_handler(CommandHandler("remove", cmd_remove))
    bot_app.add_handler(CallbackQueryHandler(on_button_click))

    await bot_app.initialize()

    # 注册命令列表 —— 让输入框左边的菜单图标点开后显示这些命令，而不是空的
    await bot_app.bot.set_my_commands([
        ("start", "打开控制台菜单"),
        ("status", "查看所有节点状态"),
        ("node", "查看单个节点详情"),
        ("traffic", "查看流量统计"),
        ("remove", "摘除指定节点"),
    ])

    await bot_app.start()
    await bot_app.updater.start_polling()

    monitor_task = asyncio.create_task(monitor_loop())

    yield  # ---- 应用运行中 ----

    monitor_task.cancel()
    await bot_app.updater.stop()
    await bot_app.stop()
    await bot_app.shutdown()


app = FastAPI(lifespan=lifespan)


@app.post("/report")
async def report(payload: ReportPayload, authorization: str = Header(None)):
    expected = f"Bearer {config.AUTH_TOKEN}"
    if not authorization or not hmac.compare_digest(authorization, expected):
        raise HTTPException(status_code=401, detail="invalid token")

    NODES[payload.node_id] = {
        "name": payload.name or payload.node_id,
        "cpu": payload.cpu,
        "mem": payload.mem,
        "disk": payload.disk,
        "net_up": payload.net_up,
        "net_down": payload.net_down,
        "net_sent_total": payload.net_sent_total,
        "net_recv_total": payload.net_recv_total,
        "uptime": payload.uptime,
        "last_seen": time.time(),
    }
    return {"ok": True}


@app.get("/refresh_check/{node_id}")
async def refresh_check(node_id: str, authorization: str = Header(None)):
    """Agent 轻量轮询用的接口：问一下"要不要立刻上报"。
    命中一次就从待刷新集合里取走，避免同一次点击触发反复上报。"""
    expected = f"Bearer {config.AUTH_TOKEN}"
    if not authorization or not hmac.compare_digest(authorization, expected):
        raise HTTPException(status_code=401, detail="invalid token")

    if node_id in PENDING_REFRESH:
        PENDING_REFRESH.discard(node_id)
        return {"refresh": True}
    return {"refresh": False}


if __name__ == "__main__":
    uvicorn.run(app, host=config.SERVER_HOST, port=config.SERVER_PORT)
