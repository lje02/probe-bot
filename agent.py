"""
探针机器人 - Agent（部署在每台被监控的服务器上）

用法：
  1. 修改下面 SERVER_URL / AUTH_TOKEN / NODE_ID / NODE_NAME
  2. pip install -r requirements_agent.txt
  3. python agent.py
  4. 建议配合 systemd 常驻运行（见 README）
"""

import time
import requests
import psutil

# ------------------- 按需修改 -------------------
SERVER_URL = "http://你的服务端IP或域名:8000/report"
AUTH_TOKEN = "要和服务端 config.py 里的 AUTH_TOKEN 保持一致"
NODE_ID = "hk-01"          # 每台机器唯一，比如 hk-01 / jp-02
NODE_NAME = "香港-01"       # 显示在 Telegram 里的名字
REPORT_INTERVAL_SEC = 15   # 上报间隔
# -------------------------------------------------


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
