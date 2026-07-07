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

  echo ""
  echo "上面的服务端地址是走 WireGuard/私有内网，还是走公网？"
  echo "  - 私有内网(WireGuard/Tailscale等): 流量本身已加密，用 http:// 就行"
  echo "  - 公网: 必须用 https://，否则鉴权 Token 会明文暴露"
  read -rp "走的是私有内网吗？[Y/n]: " use_private_net
  use_private_net=${use_private_net:-Y}

  if [ -z "$auth_token" ] || [ -z "$node_id" ]; then
    rm -f "$INSTALL_DIR/.env"
    echo ""
    echo "!! 鉴权 Token 和 节点 ID 是必填项，不能留空，本次配置已取消。"
    echo "   请重新运行 sudo bash install_agent.sh"
    exit 1
  fi

  if [[ "$use_private_net" =~ ^[Yy]$ ]]; then
    allow_http=1
    echo "==> 已设置 PROBE_ALLOW_HTTP=1（跳过 agent.py 里的强制 https 检查）"
  else
    allow_http=0
    if [[ "$server_url" != https://* ]]; then
      echo ""
      echo "!! 你选择了走公网，但服务端地址不是 https:// 开头，Agent 启动时会被拒绝。"
      echo "   请给服务端配置好 Nginx+HTTPS，并把上面的地址改成 https://，再重新运行本脚本。"
      rm -f "$INSTALL_DIR/.env"
      exit 1
    fi
    echo "==> 未设置 PROBE_ALLOW_HTTP，agent.py 会强制要求 https://"
  fi

  sed -i "s#^PROBE_SERVER_URL=.*#PROBE_SERVER_URL=${server_url}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_AUTH_TOKEN=.*#PROBE_AUTH_TOKEN=${auth_token}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_NODE_ID=.*#PROBE_NODE_ID=${node_id}#" "$INSTALL_DIR/.env"
  sed -i "s#^PROBE_NODE_NAME=.*#PROBE_NODE_NAME=${node_name}#" "$INSTALL_DIR/.env"
  if [ "$allow_http" = "1" ]; then
    sed -i "s|^# *PROBE_ALLOW_HTTP=.*|PROBE_ALLOW_HTTP=1|; s|^PROBE_ALLOW_HTTP=.*|PROBE_ALLOW_HTTP=1|" "$INSTALL_DIR/.env"
  else
    sed -i "/^PROBE_ALLOW_HTTP=/d" "$INSTALL_DIR/.env"
  fi
fi
chmod 600 "$INSTALL_DIR/.env"
chown "$RUN_USER" "$INSTALL_DIR/.env"

# 2. 建虚拟环境 + 装依赖
if [ ! -d "$INSTALL_DIR/.venv" ]; then
  echo "==> 创建虚拟环境..."
  python3 -m venv "$INSTALL_DIR/.venv"
else
  echo "==> 虚拟环境已存在，跳过创建"
fi
"$INSTALL_DIR/.venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -q -r "$INSTALL_DIR/requirements_agent.txt"

# 验证关键依赖真的装上了（曾经出现过 pip 表面成功、实际某个包缺失的情况）
if ! "$INSTALL_DIR/.venv/bin/python" -c "import psutil, requests, dotenv" 2>/dev/null; then
  echo ""
  echo "!! 依赖安装校验失败，虚拟环境里缺少必要的包。"
  echo "   手动排查: $INSTALL_DIR/.venv/bin/pip install -r $INSTALL_DIR/requirements_agent.txt"
  echo "   如果还不行，试试删掉虚拟环境重建: rm -rf $INSTALL_DIR/.venv && sudo bash install_agent.sh"
  exit 1
fi
echo "==> 依赖校验通过"

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
