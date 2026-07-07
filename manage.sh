#!/usr/bin/env bash
# 探针机器人 - 统一管理脚本
# 用法: sudo bash manage.sh
set -e

if [ "$EUID" -ne 0 ]; then
  echo "请用 sudo 运行: sudo bash manage.sh"
  exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INSTALL_DIR"

SERVER_SVC="probe-server"
AGENT_SVC="probe-agent"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

server_installed() { [ -f "${SYSTEMD_DIR}/${SERVER_SVC}.service" ]; }
agent_installed()  { [ -f "${SYSTEMD_DIR}/${AGENT_SVC}.service" ]; }

# ---------------------------------------------------------------------------
# 选择本次要管理的服务（服务端 / Agent）
# ---------------------------------------------------------------------------
choose_service() {
  local has_server has_agent
  server_installed && has_server=1 || has_server=0
  agent_installed && has_agent=1 || has_agent=0

  if [ "$has_server" = "1" ] && [ "$has_agent" = "0" ]; then
    echo "$SERVER_SVC"
    return
  fi
  if [ "$has_agent" = "1" ] && [ "$has_server" = "0" ]; then
    echo "$AGENT_SVC"
    return
  fi

  echo "" >&2
  echo "这台机器上检测到的服务：" >&2
  [ "$has_server" = "1" ] && echo "  1) $SERVER_SVC (已安装)" >&2 || echo "  1) $SERVER_SVC (未安装)" >&2
  [ "$has_agent" = "1" ]  && echo "  2) $AGENT_SVC (已安装)"  >&2 || echo "  2) $AGENT_SVC (未安装)"  >&2
  read -rp "选择要管理哪个 [1/2]: " choice >&2
  case "$choice" in
    1) echo "$SERVER_SVC" ;;
    2) echo "$AGENT_SVC" ;;
    *) echo "无效选择" >&2; exit 1 ;;
  esac
}

install_script_for() {
  if [ "$1" = "$SERVER_SVC" ]; then echo "install_server.sh"; else echo "install_agent.sh"; fi
}

# ---------------------------------------------------------------------------
# 各项操作
# ---------------------------------------------------------------------------
do_install() {
  local svc; svc=$(choose_service_for_install)
  sudo bash "$(install_script_for "$svc")"
}

choose_service_for_install() {
  echo "" >&2
  echo "要安装哪个角色？" >&2
  echo "  1) 服务端 (probe-server，接收上报+跑 Telegram Bot)" >&2
  echo "  2) Agent (probe-agent，采集本机数据并上报)" >&2
  read -rp "选择 [1/2]: " choice >&2
  case "$choice" in
    1) echo "$SERVER_SVC" ;;
    2) echo "$AGENT_SVC" ;;
    *) echo "无效选择" >&2; exit 1 ;;
  esac
}

do_update() {
  local svc; svc=$(choose_service)

  if [ -d .git ]; then
    echo "==> 拉取最新代码..."
    git pull
  else
    echo "!! 当前目录不是 git 仓库，跳过 git pull，只重新装依赖/配置。"
  fi

  echo "==> 重新运行安装脚本（幂等，已有 .env 不会被覆盖）..."
  sudo bash "$(install_script_for "$svc")"

  echo "==> 重启服务..."
  systemctl restart "$svc"
  sleep 1
  systemctl status "$svc" --no-pager || true
}

do_status() {
  local svc; svc=$(choose_service)
  systemctl status "$svc" --no-pager || true
}

do_logs() {
  local svc; svc=$(choose_service)
  echo "==> 实时日志 (Ctrl+C 退出)"
  journalctl -u "$svc" -f
}

do_restart() {
  local svc; svc=$(choose_service)
  systemctl restart "$svc"
  echo "==> 已重启 $svc"
  sleep 1
  systemctl status "$svc" --no-pager || true
}

do_stop() {
  local svc; svc=$(choose_service)
  systemctl stop "$svc"
  echo "==> 已停止 $svc（开机自启还在，下次开机会自动拉起；如果不想自启，选卸载菜单里的对应选项）"
}

do_uninstall() {
  local svc; svc=$(choose_service)

  echo ""
  echo "!! 即将卸载 $svc，这会："
  echo "   1. 停止并禁用该服务"
  echo "   2. 删除 systemd 单元文件"
  read -rp "确认继续吗？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "已取消。"
    return
  fi

  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/${svc}.service"
  systemctl daemon-reload
  echo "==> 服务已卸载。"

  read -rp "要不要顺便删除虚拟环境 .venv（释放磁盘空间，下次重装会自动重建）？[y/N]: " del_venv
  if [[ "$del_venv" =~ ^[Yy]$ ]]; then
    rm -rf "$INSTALL_DIR/.venv"
    echo "==> 已删除 .venv"
  fi

  read -rp "要不要顺便删除 .env（里面有 Token 等密钥，删了下次要重新配置）？[y/N]: " del_env
  if [[ "$del_env" =~ ^[Yy]$ ]]; then
    rm -f "$INSTALL_DIR/.env"
    echo "==> 已删除 .env"
  fi

  echo ""
  echo "==> 卸载完成。如果想彻底删除整个项目目录，手动执行："
  echo "    rm -rf $INSTALL_DIR"
}

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------
show_menu() {
  echo ""
  echo "========== 探针机器人 管理菜单 =========="
  server_installed && echo "  服务端: 已安装" || echo "  服务端: 未安装"
  agent_installed  && echo "  Agent : 已安装" || echo "  Agent : 未安装"
  echo "------------------------------------------"
  echo "  1) 安装 / 首次配置"
  echo "  2) 更新代码并重启"
  echo "  3) 查看状态"
  echo "  4) 查看实时日志"
  echo "  5) 重启服务"
  echo "  6) 停止服务"
  echo "  7) 卸载"
  echo "  0) 退出"
  echo "=========================================="
  read -rp "选择操作: " opt

  case "$opt" in
    1) do_install ;;
    2) do_update ;;
    3) do_status ;;
    4) do_logs ;;
    5) do_restart ;;
    6) do_stop ;;
    7) do_uninstall ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
  esac
}

# 支持直接传参跳过菜单，比如: sudo bash manage.sh update
case "${1:-}" in
  install)   do_install ;;
  update)    do_update ;;
  status)    do_status ;;
  logs)      do_logs ;;
  restart)   do_restart ;;
  stop)      do_stop ;;
  uninstall) do_uninstall ;;
  "")        while true; do show_menu; done ;;
  *)
    echo "未知参数: $1"
    echo "用法: sudo bash manage.sh [install|update|status|logs|restart|stop|uninstall]"
    echo "不带参数则进入交互菜单"
    exit 1
    ;;
esac
