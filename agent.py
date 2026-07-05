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


# 配置从 .env 读取，见 .env.example
# SERVER_URL 必须是 https:// 开头（除非你走的是 Tailscale/WireGuard 内网，见 README 安全说明）
SERVER_URL = _require("PROBE_SERVER_URL")
AUTH_TOKEN = _require("PROBE_AUTH_TOKEN")
NODE_ID = _require("PROBE_NODE_ID")
NODE_NAME = os.environ.get("PROBE_NODE_NAME", NODE_ID)
REPORT_INTERVAL_SEC = int(os.environ.get("PROBE_REPORT_INTERVAL_SEC", "15"))

if not SERVER_URL.startswith("https://") and "PROBE_ALLOW_HTTP" not in os.environ:
    sys.exit(
        "[安全警告] SERVER_URL 不是 https:// 开头。\n"
        "明文 HTTP 会导致 AUTH_TOKEN 和系统数据被中间人窃听/篡改。\n"
        "请给服务端配置 Nginx+HTTPS，或改用 Tailscale/WireGuard 内网地址(见 README)。\n"
        "如果你清楚风险、确实只在私有内网使用，可设置环境变量 PROBE_ALLOW_HTTP=1 跳过此检查。"
    )


def collect():
    cpu = psutil.cpu_percent(interval=1)
    mem = psutil.virtual_memory().percent
    disk = psutil.disk_usage("/").percent
    uptime = time.time() - psutil.boot_time()
    net = psutil.net_io_counters()
    return cpu, mem, disk, uptime, net


def main():
    prev_net = psutil.net_io_counters()
    prev_time = time.time()

    while True:
        cpu, mem, disk, uptime, net = collect()

        now = time.time()
        elapsed = max(now - prev_time, 1e-6)
        net_up = (net.bytes_sent - prev_net.bytes_sent) / elapsed
        net_down = (net.bytes_recv - prev_net.bytes_recv) / elapsed
        prev_net, prev_time = net, now

        payload = {
            "node_id": NODE_ID,
            "name": NODE_NAME,
            "cpu": cpu,
            "mem": mem,
            "disk": disk,
            "net_up": max(net_up, 0),
            "net_down": max(net_down, 0),
            "net_sent_total": net.bytes_sent,
            "net_recv_total": net.bytes_recv,
            "uptime": uptime,
        }

        try:
            requests.post(
                SERVER_URL,
                json=payload,
                headers={"Authorization": f"Bearer {AUTH_TOKEN}"},
                timeout=5,
            )
        except Exception as e:
            print(f"[warn] 上报失败: {e}")

        time.sleep(REPORT_INTERVAL_SEC)


if __name__ == "__main__":
    main()
