#!/usr/bin/env bash
# 探针机器人 - Agent 一键安装脚本
# 用法: sudo bash install_agent.sh
set -e

if [ "$EUID" -ne 0 ]; then
  echo "请用 sudo 运行: sudo bash install_agent.sh"
  exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="probe-agent"
RUN_USER="${SUDO_USER:-$(whoami)}"

echo "==> 安装目录: $INSTALL_DIR"

# 1. 检查/生成 .env，缺哪个交互式问哪个（图省事也可以直接手动编辑 .env 后再运行本脚本）
if [ ! -f "$INSTALL_DIR/.env" ]; then
  cp "$INSTALL_DIR/.env.agent.example" "$INSTALL_DIR/.env"

  echo ""
  echo "首次安装，交互式填写几项配置（直接回车使用方括号里的默认值）："
  read -rp "服务端地址 [http://10.0.0.1:8000/report]: " server_url
  server_url=${server_url:-http://10.0.0.1:8000/report}
  read -rp "鉴权 Token（要和服务端 .env 里的 PROBE_AUTH_TOKEN 一致）: " auth_token
  read -rp "节点 ID（每台机器唯一，如 hk-01）: " node_id
  read -rp "节点显示名称（如 香港-01）[默认同节点ID]: " node_name
  node_name=${node_name:-$node_id}

  if [ -z "$auth_token" ] || [ -z "$node_id" ]; then
    rm -f "$INSTALL_DIR/.env"
    echo ""
    echo "!! 鉴权 Token 和 节点 ID 是必填项，不能留空，本次配置已取消。"
    echo "   请重新运行 sudo bash install_agent.sh"
    exit 1
  fi

  sed -i "s#^PROBE_SERVER_URL=.*#PROBE_SERVER_URL=${server_url}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_AUTH_TOKEN=.*#PROBE_AUTH_TOKEN=${auth_token}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_NODE_ID=.*#PROBE_NODE_ID=${node_id}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_NODE_NAME=.*#PROBE_NODE_NAME=${node_name}#" "$INSTALL_DIR/.env"
fi
chmod 600 "$INSTALL_DIR/.env"
chown "$RUN_USER" "$INSTALL_DIR/.env"

# 2. 建虚拟环境 + 装依赖
echo "==> 创建虚拟环境..."
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -q -r "$INSTALL_DIR/requirements_agent.txt"

# 3. 生成 systemd 单元文件
# Agent 只是个采集脚本，资源限制给得比服务端更紧：
#   CPUQuota=5%   平时几乎不占 CPU，采集是瞬时的
#   MemoryMax=50M psutil+requests 正常占用几 MB，50M 已经很宽松
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Probe Bot Agent
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/python ${INSTALL_DIR}/agent.py
Restart=always
RestartSec=5

Nice=19
IOSchedulingClass=idle
CPUQuota=5%
MemoryMax=50M

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}

echo ""
echo "==> 安装完成，Agent 已启动并设为开机自启。"
echo ""
echo "常用命令："
echo "  systemctl status ${SERVICE_NAME}    # 查看运行状态"
echo "  journalctl -u ${SERVICE_NAME} -f    # 查看实时日志"
echo "  systemctl restart ${SERVICE_NAME}   # 重启"
