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

# 编辑 config.py，填入：
#   BOT_TOKEN   = 上一步拿到的 token
#   CHAT_ID     = 你自己的 chat_id
#   AUTH_TOKEN  = 随便生成一个随机字符串，例如：
#       openssl rand -hex 16

python server.py
```

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

记得在服务端防火墙放行 `SERVER_PORT`（默认 8000），或者用 Nginx 反代加 HTTPS（公网建议做）。

## 第三步：在每台被监控的服务器上部署 Agent

把 `agent.py` 和 `requirements_agent.txt` 拷贝过去：

```bash
pip install -r requirements_agent.txt --break-system-packages

# 编辑 agent.py 顶部：
#   SERVER_URL  = http://你的服务端IP:8000/report
#   AUTH_TOKEN  = 和服务端 config.py 里的 AUTH_TOKEN 一致
#   NODE_ID     = 每台机器唯一，比如 hk-01
#   NODE_NAME   = 显示名字，比如 香港-01

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
