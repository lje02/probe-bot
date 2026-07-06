"""
探针机器人 - Agent（部署在每台被监控的服务器上）

用法：
  1. 修改下面 SERVER_URL / AUTH_TOKEN / NODE_ID / NODE_NAME
  2. pip install -r requirements_agent.txt
  3. python agent.py
  4. 建议配合 systemd 常驻运行（见 README）
"""

import os
import sys
import time
import requests
import psutil
from dotenv import load_dotenv

load_dotenv()  # 读取同目录下的 .env


def _require(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        sys.exit(f"[配置错误] 缺少环境变量 {name}，请检查 .env 文件")
    return val


# 配置从 .env 读取，见 .env.agent.example
# SERVER_URL 必须是 https:// 开头（除非你走的是 Tailscale/WireGuard 内网，见 README 安全说明）
SERVER_URL = _require("PROBE_SERVER_URL")
AUTH_TOKEN = _require("PROBE_AUTH_TOKEN")
NODE_ID = _require("PROBE_NODE_ID")
NODE_NAME = os.environ.get("PROBE_NODE_NAME", NODE_ID)
REPORT_INTERVAL_SEC = int(os.environ.get("PROBE_REPORT_INTERVAL_SEC", "5"))

# 除了定时上报，Agent 还会用这个更短的间隔轻量问一下服务端"要不要立刻上报一次"
# （对应 Bot 里点"刷新"按钮的场景），请求很小，正常情况几乎不耗资源
REFRESH_CHECK_INTERVAL_SEC = int(os.environ.get("PROBE_REFRESH_CHECK_INTERVAL_SEC", "3"))

# 从 SERVER_URL(形如 http://host:port/report) 推导出 refresh_check 的地址
_base_url = SERVER_URL.rsplit("/", 1)[0]
REFRESH_CHECK_URL = f"{_base_url}/refresh_check/{NODE_ID}"

ALLOW_HTTP = os.environ.get("PROBE_ALLOW_HTTP", "").strip().lower() in ("1", "true", "yes")

if not SERVER_URL.startswith("https://") and not ALLOW_HTTP:
    sys.exit(
        "[安全警告] SERVER_URL 不是 https:// 开头。\n"
        "明文 HTTP 会导致 AUTH_TOKEN 和系统数据被中间人窃听/篡改。\n"
        "请给服务端配置 Nginx+HTTPS，或改用 Tailscale/WireGuard 内网地址(见 README)。\n"
        "如果你清楚风险、确实只在私有内网使用，可设置环境变量 PROBE_ALLOW_HTTP=1 跳过此检查。"
    )


def collect():
    # percpu=True 一次性拿到每个核心的使用率，整机 CPU% 直接取均值，
    # 不用再额外调用一次 cpu_percent（避免多阻塞 1 秒）
    cpu_per_core = psutil.cpu_percent(interval=1, percpu=True)
    cpu = sum(cpu_per_core) / len(cpu_per_core) if cpu_per_core else 0.0

    mem = psutil.virtual_memory().percent
    disk = psutil.disk_usage("/").percent
    uptime = time.time() - psutil.boot_time()
    net = psutil.net_io_counters()

    # 负载均值 1/5/15 分钟，Windows 等平台可能不支持，降级为 0
    try:
        load1, load5, load15 = psutil.getloadavg()
    except (AttributeError, OSError):
        load1 = load5 = load15 = 0.0

    return cpu, cpu_per_core, mem, disk, uptime, net, (load1, load5, load15)


def check_force_refresh(session) -> bool:
    """轻量问询：服务端是否要求本节点立即上报一次。
    网络问题/超时都当作"不需要"处理，不影响主流程。"""
    try:
        resp = session.get(
            REFRESH_CHECK_URL,
            headers={"Authorization": f"Bearer {AUTH_TOKEN}"},
            timeout=3,
        )
        if resp.status_code == 200:
            return bool(resp.json().get("refresh", False))
    except Exception:
        pass
    return False


def report_once(session, prev_net, prev_time):
    """采集并上报一次，返回最新的 (net, now) 供下次计算速率用"""
    cpu, cpu_per_core, mem, disk, uptime, net, loadavg = collect()
    load1, load5, load15 = loadavg

    now = time.time()
    elapsed = max(now - prev_time, 1e-6)
    net_up = (net.bytes_sent - prev_net.bytes_sent) / elapsed
    net_down = (net.bytes_recv - prev_net.bytes_recv) / elapsed

    payload = {
        "node_id": NODE_ID,
        "name": NODE_NAME,
        "cpu": cpu,
        "cpu_per_core": cpu_per_core,
        "mem": mem,
        "disk": disk,
        "net_up": max(net_up, 0),
        "net_down": max(net_down, 0),
        "net_sent_total": net.bytes_sent,
        "net_recv_total": net.bytes_recv,
        "uptime": uptime,
        "load1": load1,
        "load5": load5,
        "load15": load15,
    }

    try:
        resp = session.post(
            SERVER_URL,
            json=payload,
            headers={"Authorization": f"Bearer {AUTH_TOKEN}"},
            timeout=5,
        )
        if resp.status_code == 401:
            print("[error] 上报被拒绝(401): AUTH_TOKEN 和服务端不一致，请检查 .env")
        elif resp.status_code >= 400:
            print(f"[warn] 服务端返回异常状态码 {resp.status_code}: {resp.text[:200]}")
    except Exception as e:
        print(f"[warn] 上报失败(网络/连接问题): {e}")

    return net, now


def main():
    session = requests.Session()  # 复用 TCP 连接，减少每次上报的开销
    prev_net = psutil.net_io_counters()
    prev_time = time.time()
    next_report_time = time.time()  # 启动后先正常上报一次

    while True:
        now = time.time()
        due_scheduled = now >= next_report_time
        due_forced = False if due_scheduled else check_force_refresh(session)

        if due_scheduled or due_forced:
            prev_net, prev_time = report_once(session, prev_net, prev_time)
            next_report_time = time.time() + REPORT_INTERVAL_SEC

        time.sleep(REFRESH_CHECK_INTERVAL_SEC)


if __name__ == "__main__":
    main()
