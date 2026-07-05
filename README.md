# Telegram 探针机器人

多节点服务器监控，实时状态 + 异常报警，全部通过 Telegram 查看，不做 Web 面板，不存历史数据。

## 目录结构

```
probe_bot/
├── server.py                # 服务端(收上报 + 判断报警 + Telegram Bot)
├── config.py                # 服务端配置(需要修改)
├── requirements_server.txt
├── agent.py                 # Agent(装在每台被监控机器上)
├── requirements_agent.txt
└── README.md
```

## 第一步：创建 Telegram Bot

1. Telegram 里搜索 `@BotFather`，发送 `/newbot`，按提示创建，拿到 `BOT_TOKEN`
2. 搜索 `@userinfobot`，发送任意消息，拿到你自己的 `chat_id`

## 第二步：部署服务端（找一台稳定的机器/VPS）

```bash
cd probe_bot
pip install -r requirements_server.txt --break-system-packages

cp .env.server.example .env
# 编辑 .env，填入 BOT_TOKEN / CHAT_ID / AUTH_TOKEN
# AUTH_TOKEN 随便生成一个随机字符串，例如: openssl rand -hex 16

python server.py
```

`.env` 文件包含密钥，注意：
- 不要把它提交到 git（建议在 `.gitignore` 里加一行 `.env`）
- 不要截图分享给别人
- 文件权限建议设为仅自己可读：`chmod 600 .env`

建议用 systemd 常驻（避免关终端就断）：

```ini
# /etc/systemd/system/probe-server.service
[Unit]
Description=Probe Bot Server
After=network.target

[Service]
WorkingDirectory=/path/to/probe_bot
ExecStart=/usr/bin/python3 server.py
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now probe-server
```

`config.py` 里 `PROBE_SERVER_HOST` 默认兜底是 `127.0.0.1`，但你实际部署时要按下面"安全部署"里的说明，改成 WireGuard 网卡的内网 IP，Agent 才能连上。

## 安全部署（你已经有 WireGuard，直接用它，不需要 Tailscale/Nginx）

WireGuard 隧道内的流量本身就是加密的，所以只要服务端和 Agent 之间**只通过 WireGuard 的内网 IP 通信**（不经过公网 IP），明文 HTTP 就是安全的。核心思路：让 8000 端口只在 WireGuard 网卡上监听，公网网卡完全不监听这个端口。

### 第一步：查看服务端的 WireGuard 内网 IP

```bash
ip addr show wg0   # 网卡名如果不是 wg0，换成你自己的
# 类似输出: inet 10.0.0.1/24 ... 记下这个 10.0.0.1
```

### 第二步：服务端 `.env` 绑定到这个内网 IP（不是 0.0.0.0，也不是公网 IP）

```bash
PROBE_SERVER_HOST=10.0.0.1   # 换成你实际的 wg0 地址
PROBE_SERVER_PORT=8000
```

这样 uvicorn 只在 WireGuard 网卡上监听，公网 IP 上根本连不到这个端口，不需要额外配置防火墙。

（如果你想更保险，再加一条 iptables 规则明确拒绝非 wg0 来源访问该端口也可以，但只监听内网 IP 通常已经够了。)

### 第三步：每台 Agent 的 `.env`

```bash
PROBE_SERVER_URL=http://10.0.0.1:8000/report   # 服务端的 wg0 内网 IP
PROBE_AUTH_TOKEN=... 和服务端一致
PROBE_ALLOW_HTTP=1   # 因为走的是 WireGuard 加密隧道，跳过 agent.py 里的 https 强制检查
```

前提是每台被监控的服务器也都已经加入了同一个 WireGuard 网络（能互相 ping 通对方的 `10.0.0.x` 地址）。如果还没加入，就把它们也配成 WireGuard 的 peer。

> 如果以后有台机器不方便装 WireGuard、只能走公网连接，那台单独走 Nginx+HTTPS 的方案（见下方"备选方案"），两种方式可以混用，服务端同时监听 wg0 内网 IP 和一个额外的 HTTPS 端口即可。

<details>
<summary>备选方案：Nginx + HTTPS（用不到可以跳过）</summary>

服务端装 Nginx，申请免费证书（certbot），只对外暴露 443：

```nginx
server {
    listen 443 ssl;
    server_name probe.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/probe.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/probe.yourdomain.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
    }
}
```

```bash
sudo certbot --nginx -d probe.yourdomain.com
```

Agent 端 `.env` 里 `PROBE_SERVER_URL` 填 `https://probe.yourdomain.com/report` 即可（不设置 `PROBE_ALLOW_HTTP`，让 agent.py 的强制检查生效）。

</details>

## 第三步：在每台被监控的服务器上部署 Agent

把 `agent.py` 和 `requirements_agent.txt` 拷贝过去：

```bash
pip install -r requirements_agent.txt --break-system-packages

cp .env.agent.example .env
# 编辑 .env：
#   PROBE_SERVER_URL  = 服务端地址(见下面"安全部署"，必须是 https:// 或 Tailscale 内网)
#   PROBE_AUTH_TOKEN  = 和服务端 .env 里的 PROBE_AUTH_TOKEN 一致
#   PROBE_NODE_ID     = 每台机器唯一，比如 hk-01
#   PROBE_NODE_NAME   = 显示名字，比如 香港-01

python agent.py
```

同样建议 systemd 常驻，把上面 service 文件的 `ExecStart` 换成 `agent.py` 即可，每台机器装一份，`NODE_ID` 记得改成不一样的。

## 使用

在和你的 Bot 的私聊窗口里：

- `/status` — 查看所有节点实时状态一览
- `/node 香港-01` — 查看单个节点详情
- `/traffic` — 查看各节点累计流量

出现异常时 Bot 会**主动**推送消息给你，无需查询：

- 🔴 节点失联（默认 90 秒无上报）
- 🔥 CPU / 内存超过 90%（可在 `config.py` 改阈值）
- 🟢 / ✅ 恢复正常时也会推送一条

## 后续可扩展方向（现在没做，想要再加）

- 阈值动态修改命令（`/setcpu 85` 之类）
- 历史数据存储 + 曲线图
- 多用户/多群权限控制
- 流量超额提醒（比如月流量跑到 80% 时提醒）
