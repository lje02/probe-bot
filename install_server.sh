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

# 1. 检查 .env
if [ ! -f "$INSTALL_DIR/.env" ]; then
  if [ -f "$INSTALL_DIR/.env.server.example" ]; then
    cp "$INSTALL_DIR/.env.server.example" "$INSTALL_DIR/.env"
    echo ""
    echo "!! 已生成 .env，请先编辑填好 BOT_TOKEN / CHAT_ID / AUTH_TOKEN，再重新运行本脚本:"
    echo "   nano $INSTALL_DIR/.env"
    exit 1
  else
    echo "找不到 .env 或 .env.server.example，无法继续。"
    exit 1
  fi
fi
chmod 600 "$INSTALL_DIR/.env"
chown "$RUN_USER" "$INSTALL_DIR/.env"

# 2. 建虚拟环境 + 装依赖（虚拟环境避免污染系统 Python，也方便控制版本）
echo "==> 创建虚拟环境..."
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -q -r "$INSTALL_DIR/requirements_server.txt"

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
