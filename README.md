# Telegram 探针机器人

多节点服务器监控 Bot：多台服务器的状态集中上报，全部通过 Telegram 查看和操作——不需要 Web 面板，不需要额外的客户端。

## 功能

- 🖥 **多节点集中监控** — 每台服务器装一个轻量 Agent，数据汇总到一个 Bot 里查看
- 🔘 **按钮式交互控制台** — `/start` 弹出 inline 按钮菜单，点击导航，不用死记命令
- 🔥 **自动报警** — 节点离线、CPU/内存超阈值时主动推送，无需手动查询
- 🗑 **节点摘除** — 手动摘除（二次确认）+ 长期离线自动清理，列表不会越堆越乱
- 🔒 **内网加密传输** — 走 WireGuard 隧道，token 鉴权，避免明文暴露公网
- ⚙️ **一键部署** — 安装脚本自动配 systemd 常驻服务，异常退出自动重启
- 📉 **低资源占用** — systemd 资源配额限制，探针本身不会跟业务进程抢资源

# 安装依赖

if command -v apt >/dev/null 2>&1; then
  sudo apt update && sudo apt install -y python3 python3-venv python3-pip git
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y python3 python3-pip git
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y python3 python3-pip git
elif command -v apk >/dev/null 2>&1; then
  sudo apk add python3 py3-pip git
else
  echo "未识别的系统，请手动安装: python3 python3-venv python3-pip git"
fi

# 安装git

sudo apt update && sudo apt install -y git

## 快速开始


```bash
git clone https://github.com/lje02/probe-bot.git
cd probe-bot
```

接下来分「服务端」「Agent」两部分部署，跳到下面对应章节。

## 目录结构

```
probe-bot/
├── server.py                # 服务端(收上报 + 判断报警 + Telegram Bot)
├── config.py                # 服务端配置(从 .env 读取)
├── install_server.sh        # 服务端一键安装(建venv+装依赖+配systemd+限资源)
├── requirements_server.txt
├── .env.server.example
├── agent.py                 # Agent(装在每台被监控机器上)
├── install_agent.sh         # Agent一键安装(交互式填配置+配systemd+限资源)
├── requirements_agent.txt
├── .env.agent.example
└── README.md
```

## 第一步：创建 Telegram Bot

1. Telegram 里搜索 `@BotFather`，发送 `/newbot`，按提示创建，拿到 `BOT_TOKEN`
2. 搜索 `@userinfobot`，发送任意消息，拿到你自己的 `chat_id`

## 第二步：部署服务端（找一台稳定的机器/VPS）

```bash
sudo bash install_server.sh
```

首次运行会交互式问你几项（Bot Token、Chat ID、鉴权 Token——留空可自动生成、监听地址），填完自动生成 `.env`、建虚拟环境、装依赖、配置 systemd、限制资源、开机自启并启动。

如果想跳过交互，直接编辑好 `.env.server.example` 复制为 `.env` 再运行脚本也可以，脚本检测到 `.env` 已存在就不会再问。

`.env` 文件包含密钥，注意：
- 不要提交到 git（已在 `.gitignore` 里）
- 不要截图分享给别人
- 脚本已自动设置权限为仅自己可读（`chmod 600`）

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

在每台要监控的服务器上都 clone 一份：

```bash
git clone https://github.com/lje02/probe-bot.git
cd probe-bot
sudo bash install_agent.sh
```

首次运行会交互式问你几项（服务端地址、Token、节点 ID/名称、走内网还是公网），填完自动建虚拟环境、装依赖、配置 systemd、限制资源、开机自启并启动。每台机器跑一次，注意 **节点 ID 每台要填不一样的**（比如 hk-01 / jp-02）。

「走内网还是公网」这一步决定 `PROBE_ALLOW_HTTP` 怎么设：选内网（比如 WireGuard）会自动设 `PROBE_ALLOW_HTTP=1`，跳过强制 HTTPS 检查；选公网则要求地址必须是 `https://`，否则脚本直接拒绝，不会生成一个会明文暴露 Token 的配置。

如果想跳过交互，直接编辑好 `.env.agent.example` 复制为 `.env` 再运行脚本也可以，脚本检测到 `.env` 已存在就不会再问。

## 使用

私聊你的 Bot，发 `/start`（或 `/menu`）会弹出一个按钮控制台：

```
🛰 探针机器人控制台
请选择要查看的内容：

[📊 节点状态]  [📈 流量统计]
[🗂 节点列表]  [ℹ️ 帮助]
```

- 点 **📊 节点状态** — 所有节点一览，带 🔄刷新 / ⬅️返回 按钮，原地更新不刷屏
- 点 **🗂 节点列表** — 每个节点一个按钮（🟢/🔴 标在线状态），点进去看该节点详情
- 点 **📈 流量统计** — 各节点累计流量
- 节点详情页有 **🗑 摘除节点** 按钮，点了会要求二次确认，防止手滑误删
- 报警推送消息下面也带一个 **📊 查看状态** 按钮，点一下直接跳到状态面板

摘除/清理都只是从"当前显示列表"里移除，不会影响 Agent 本身运行——如果被摘除的节点后续又上报了数据，会自动重新出现在列表里。长期离线（默认 7 天，`.env` 里 `PROBE_STALE_REMOVE_DAYS` 可调）的节点也会自动清理，不用手动维护。

依然保留了命令行式用法（想直接打字也行）：

- `/status` — 节点状态
- `/node 香港-01` — 指定节点详情（不带参数会弹出节点按钮列表）
- `/traffic` — 流量统计
- `/remove 香港-01` — 摘除节点（会要求二次确认）

出现异常时 Bot 会**主动**推送消息给你，无需查询：

- 🔴 节点失联（默认 90 秒无上报）
- 🔥 CPU / 内存超过 90%（可在 `.env` 改阈值）
- 🟢 / ✅ 恢复正常时也会推送一条

## 资源占用控制

两个安装脚本生成的 systemd 服务都自带资源限制，不会因为探针本身把机器资源占满：

| 限制项 | Agent | 服务端 | 说明 |
|---|---|---|---|
| `Nice=19` | ✅ | ✅ | 调度优先级降到最低，业务进程抢 CPU 时优先让着它们 |
| `IOSchedulingClass=idle` | ✅ | ✅ | 磁盘 IO 优先级最低 |
| `CPUQuota` | 5% | 20% | 最多用多少个 CPU 核心的百分比 |
| `MemoryMax` | 50M | 150M | 超过直接被系统 OOM kill，防止意外内存泄漏拖垮整机 |

Agent 本身也很轻：只用 `psutil` 采集数据、`requests.Session()` 复用连接上报，每 15 秒跑一次，正常情况下 CPU 占用几乎为 0，内存占用几 MB。

如果嫌默认限制太紧（比如报警显示服务被 OOM kill 了），改 `/etc/systemd/system/probe-server.service`（或 `probe-agent.service`）里的 `CPUQuota`/`MemoryMax` 数值，然后：

```bash
sudo systemctl daemon-reload
sudo systemctl restart probe-server   # 或 probe-agent
```

## 后续可扩展方向（现在没做，想要再加）

- 阈值动态修改命令（`/setcpu 85` 之类）
- 历史数据存储 + 曲线图
- 多用户/多群权限控制
- 流量超额提醒（比如月流量跑到 80% 时提醒）

## 更新代码

```bash
cd probe-bot
git pull
sudo systemctl restart probe-server   # 服务端机器上执行
sudo systemctl restart probe-agent    # 每台 Agent 机器上执行
```

`.env` 和 `.venv` 都在 `.gitignore` 里，`git pull` 不会动到你的配置和依赖环境。如果 `requirements_*.txt` 有变化，记得重新跑一下对应的 `pip install`。

## License

MIT（占位，按你实际情况改成想用的协议，或删掉这节）
