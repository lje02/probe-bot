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
import time
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, Header, HTTPException, Request
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

import config

# ---------------------------------------------------------------------------
# 内存状态存储：{node_id: {...}}
# 不落库，重启后清空，重新等节点上报（符合"只看实时状态"的需求）
# ---------------------------------------------------------------------------
NODES: dict[str, dict] = {}

# 记录每个节点当前是否处于"已报警"状态，避免同一问题反复刷屏
ALERT_STATE: dict[str, dict] = {}


def fmt_bytes_per_sec(v: float) -> str:
    if v > 1024 * 1024:
        return f"{v / 1024 / 1024:.1f}MB/s"
    if v > 1024:
        return f"{v / 1024:.1f}KB/s"
    return f"{v:.0f}B/s"


def node_line(node_id: str) -> str:
    n = NODES[node_id]
    online = (time.time() - n["last_seen"]) < config.OFFLINE_THRESHOLD_SEC
    icon = "🟢" if online else "🔴"
    if not online:
        return f"{icon} {n['name']}  (失联 {int(time.time() - n['last_seen'])}s)"
    return (
        f"{icon} {n['name']}  CPU {n['cpu']:.0f}%  MEM {n['mem']:.0f}%  "
        f"DISK {n['disk']:.0f}%  ⬆{fmt_bytes_per_sec(n['net_up'])} "
        f"⬇{fmt_bytes_per_sec(n['net_down'])}"
    )


# ---------------------------------------------------------------------------
# Telegram Bot 部分
# ---------------------------------------------------------------------------
bot_app: Application = None  # 在 lifespan 里初始化


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not NODES:
        await update.message.reply_text("暂无节点上报数据。")
        return
    online_cnt = sum(
        1 for n in NODES.values()
        if time.time() - n["last_seen"] < config.OFFLINE_THRESHOLD_SEC
    )
    lines = [f"📊 节点状态 ({online_cnt}/{len(NODES)} 在线)\n"]
    for node_id in sorted(NODES, key=lambda k: NODES[k]["name"]):
        lines.append(node_line(node_id))
    await update.message.reply_text("\n".join(lines))


async def cmd_node(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("用法: /node <节点名称>")
        return
    name = " ".join(context.args)
    matched = [nid for nid, n in NODES.items() if n["name"] == name]
    if not matched:
        await update.message.reply_text(f"未找到节点: {name}")
        return
    nid = matched[0]
    n = NODES[nid]
    online = time.time() - n["last_seen"] < config.OFFLINE_THRESHOLD_SEC
    msg = (
        f"节点: {n['name']}\n"
        f"状态: {'🟢 在线' if online else '🔴 离线'}\n"
        f"CPU: {n['cpu']:.1f}%\n"
        f"内存: {n['mem']:.1f}%\n"
        f"磁盘: {n['disk']:.1f}%\n"
        f"上行: {fmt_bytes_per_sec(n['net_up'])}\n"
        f"下行: {fmt_bytes_per_sec(n['net_down'])}\n"
        f"运行时长: {n['uptime'] / 3600:.1f} 小时\n"
        f"最后上报: {int(time.time() - n['last_seen'])} 秒前"
    )
    await update.message.reply_text(msg)


async def cmd_traffic(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not NODES:
        await update.message.reply_text("暂无数据。")
        return
    lines = ["📈 流量统计 (累计, 自 Agent 启动)\n"]
    for node_id in sorted(NODES, key=lambda k: NODES[k]["name"]):
        n = NODES[node_id]
        lines.append(
            f"{n['name']}: ⬆总{n['net_sent_total'] / 1024**3:.2f}GB "
            f"⬇总{n['net_recv_total'] / 1024**3:.2f}GB"
        )
    await update.message.reply_text("\n".join(lines))


async def send_alert(text: str):
    if bot_app is None:
        return
    await bot_app.bot.send_message(chat_id=config.CHAT_ID, text=text)


# ---------------------------------------------------------------------------
# 后台任务：定期检查离线 & 阈值报警
# ---------------------------------------------------------------------------
async def monitor_loop():
    while True:
        await asyncio.sleep(config.CHECK_INTERVAL_SEC)
        now = time.time()
        for nid, n in list(NODES.items()):
            state = ALERT_STATE.setdefault(nid, {"offline": False, "high_load": False})
            is_offline = now - n["last_seen"] > config.OFFLINE_THRESHOLD_SEC

            # 离线检测
            if is_offline and not state["offline"]:
                state["offline"] = True
                await send_alert(f"🔴 [宕机报警] {n['name']} 已 {config.OFFLINE_THRESHOLD_SEC}s 无上报，疑似离线")
            elif not is_offline and state["offline"]:
                state["offline"] = False
                await send_alert(f"🟢 [恢复] {n['name']} 已恢复上报")

            # 高负载检测（离线时不重复判断）
            if not is_offline:
                high = n["cpu"] > config.CPU_THRESHOLD or n["mem"] > config.MEM_THRESHOLD
                if high and not state["high_load"]:
                    state["high_load"] = True
                    await send_alert(
                        f"🔥 [高负载] {n['name']} CPU {n['cpu']:.0f}% MEM {n['mem']:.0f}%"
                    )
                elif not high and state["high_load"]:
                    state["high_load"] = False
                    await send_alert(f"✅ [恢复] {n['name']} 负载已恢复正常")


# ---------------------------------------------------------------------------
# FastAPI 部分：接收 Agent 上报
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global bot_app
    bot_app = Application.builder().token(config.BOT_TOKEN).build()
    bot_app.add_handler(CommandHandler("status", cmd_status))
    bot_app.add_handler(CommandHandler("node", cmd_node))
    bot_app.add_handler(CommandHandler("traffic", cmd_traffic))

    await bot_app.initialize()
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
async def report(request: Request, authorization: str = Header(None)):
    if authorization != f"Bearer {config.AUTH_TOKEN}":
        raise HTTPException(status_code=401, detail="invalid token")

    data = await request.json()
    node_id = data["node_id"]

    prev = NODES.get(node_id, {})
    NODES[node_id] = {
        "name": data.get("name", node_id),
        "cpu": data["cpu"],
        "mem": data["mem"],
        "disk": data["disk"],
        "net_up": data["net_up"],
        "net_down": data["net_down"],
        "net_sent_total": data["net_sent_total"],
        "net_recv_total": data["net_recv_total"],
        "uptime": data["uptime"],
        "last_seen": time.time(),
    }
    return {"ok": True}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=config.SERVER_PORT)
