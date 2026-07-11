#!/usr/bin/env bash
# 探针机器人 - 服务端一键安装脚本
# 用法: sudo bash install_server.sh
set -e

if [ "$EUID" -ne 0 ]; then
  echo "请用 sudo 运行: sudo bash install_server.sh"
  exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="probe-server"
RUN_USER="${SUDO_USER:-$(whoami)}"

echo "==> 安装目录: $INSTALL_DIR"
echo "==> 运行用户: $RUN_USER"

# ---------------------------------------------------------------------------
# 0. 自动检测并安装系统级依赖 (python3 / venv 模块 / pip / git)
#    已经装好的话直接跳过，不会重复安装
# ---------------------------------------------------------------------------
ensure_system_deps() {
  local need_install=0
  command -v python3 >/dev/null 2>&1 || need_install=1
  command -v git >/dev/null 2>&1 || need_install=1
  python3 -m venv --help >/dev/null 2>&1 || need_install=1

  if [ "$need_install" = "0" ]; then
    echo "==> 系统依赖 (python3/venv/git) 已齐全，跳过"
    return
  fi

  echo "==> 检测到缺少系统依赖，尝试自动安装..."
  if command -v apt >/dev/null 2>&1; then
    apt update && apt install -y python3 python3-venv python3-pip git
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-pip git
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip git
  elif command -v apk >/dev/null 2>&1; then
    apk add python3 py3-pip git
  else
    echo "!! 无法识别系统的包管理器，请手动安装: python3 python3-venv python3-pip git"
    exit 1
  fi

  if ! python3 -m venv --help >/dev/null 2>&1; then
    echo "!! python3 的 venv 模块仍不可用。"
    echo "   Debian/Ubuntu 有时需要装指定版本，比如: apt install python3.11-venv"
    echo "   请手动排查后重新运行本脚本。"
    exit 1
  fi
  echo "==> 系统依赖安装完成"
}
ensure_system_deps

# 1. 检查/生成 .env，缺哪个交互式问哪个
if [ ! -f "$INSTALL_DIR/.env" ]; then
  if [ ! -f "$INSTALL_DIR/.env.server.example" ]; then
    echo "找不到 .env.server.example，无法继续。"
    exit 1
  fi
  cp "$INSTALL_DIR/.env.server.example" "$INSTALL_DIR/.env"

  echo ""
  echo "首次安装，交互式填写几项配置（直接回车使用方括号里的默认值）："
  read -rp "Telegram Bot Token（从 @BotFather 获取）: " bot_token
  read -rp "你自己的 Chat ID（从 @userinfobot 获取）: " chat_id
  read -rp "鉴权 Token（留空则自动生成随机值，Agent 上报时要用同一个）: " auth_token
  if [ -z "$auth_token" ]; then
    auth_token=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
    echo "已自动生成鉴权 Token: $auth_token"
  fi
  read -rp "服务监听地址（建议填 WireGuard 内网 IP，如 10.0.0.1）[127.0.0.1]: " server_host
  server_host=${server_host:-127.0.0.1}

  if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
    rm -f "$INSTALL_DIR/.env"
    echo ""
    echo "!! BOT_TOKEN 和 CHAT_ID 是必填项，不能留空，本次配置已取消。"
    echo "   请重新运行 sudo bash install_server.sh"
    exit 1
  fi

  sed -i "s#^PROBE_BOT_TOKEN=.*#PROBE_BOT_TOKEN=${bot_token}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_CHAT_ID=.*#PROBE_CHAT_ID=${chat_id}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_AUTH_TOKEN=.*#PROBE_AUTH_TOKEN=${auth_token}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_SERVER_HOST=.*#PROBE_SERVER_HOST=${server_host}#" "$INSTALL_DIR/.env"

  echo ""
  echo "配置已写入 $INSTALL_DIR/.env"
  echo "记下这个鉴权 Token，等下配置 Agent 时要用: $auth_token"
  echo ""
fi
chmod 600 "$INSTALL_DIR/.env"
chown "$RUN_USER" "$INSTALL_DIR/.env"

# 关键依赖硬编码在这里做兜底 —— 万一 requirements_server.txt 文件本身传输/提交时损坏
# (比如少了某一行)，脚本不会傻乎乎地装完就算数，而是会自动按这份清单重装修复
REQUIRED_PACKAGES=(
  "fastapi>=0.110"
  "uvicorn[standard]>=0.29"
  "python-telegram-bot>=21.0"
  "python-dotenv>=1.0"
)

# 2. 建虚拟环境 + 装依赖（虚拟环境避免污染系统 Python，也方便控制版本）
if [ ! -d "$INSTALL_DIR/.venv" ]; then
  echo "==> 创建虚拟环境..."
  python3 -m venv "$INSTALL_DIR/.venv"
else
  echo "==> 虚拟环境已存在，跳过创建"
fi
"$INSTALL_DIR/.venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -q -r "$INSTALL_DIR/requirements_server.txt"

# 验证关键依赖真的装上了；不通过就自动用硬编码清单重装一次，而不是直接报错让人手动排查
if ! "$INSTALL_DIR/.venv/bin/python" -c "import fastapi, uvicorn, telegram, dotenv" 2>/dev/null; then
  echo "!! 依赖校验没通过（可能是 requirements_server.txt 内容不完整），自动尝试按标准清单修复..."
  "$INSTALL_DIR/.venv/bin/pip" install -q "${REQUIRED_PACKAGES[@]}"

  if ! "$INSTALL_DIR/.venv/bin/python" -c "import fastapi, uvicorn, telegram, dotenv" 2>/dev/null; then
    echo ""
    echo "!! 自动修复也没成功，大概率是网络问题（连不上 PyPI）。"
    echo "   手动排查: $INSTALL_DIR/.venv/bin/pip install ${REQUIRED_PACKAGES[*]}"
    echo "   如果还不行，试试删掉虚拟环境重建: rm -rf $INSTALL_DIR/.venv && sudo bash install_server.sh"
    exit 1
  fi
  echo "==> 自动修复成功"
fi
echo "==> 依赖校验通过"

# 3. 生成 systemd 单元文件
# 资源限制说明:
#   Nice=19            调度优先级降到最低，不和业务进程抢 CPU
#   IOSchedulingClass=idle  磁盘 IO 优先级最低
#   CPUQuota=20%        最多用 20% 的一个核心
#   MemoryMax=150M      内存超过这个数会被 OOM kill，防止意外泄漏拖垮整机
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Probe Bot Server
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/server.py
Restart=always
RestartSec=5

Nice=19
IOSchedulingClass=idle
CPUQuota=20%
MemoryMax=150M

[Install]
WantedBy=multi-user.target
EOF

# 4. 启用并启动
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}

echo ""
echo "==> 安装完成，服务已启动并设为开机自启。"
echo ""
echo "常用命令："
echo "  systemctl status ${SERVICE_NAME}    # 查看运行状态"
echo "  journalctl -u ${SERVICE_NAME} -f    # 查看实时日志"
echo "  systemctl restart ${SERVICE_NAME}   # 重启"
