#!/bin/bash

# ========================================================
# sing-box 综合管理脚本 
# ========================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
PURPLE='\033[0;35m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
LINK_DIR="/etc/sing-box/links"
CERT_DIR="/etc/sing-box/certs"
BACKUP_DIR="/root/singbox_backup"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# --- 辅助工具 ---
pause() {
    echo ""
    read -p "操作完成，按回车键继续..."
}

# ============================================================
# [修复1] tmp.json 竞态：改为 mktemp 临时文件，并用 trap 保底清理
# ============================================================
# 全局临时文件变量，供 save_and_restart 使用
_TMP_JSON=""

# 脚本退出时自动清理所有遗留临时文件
trap 'rm -f "$_TMP_JSON"' EXIT

# 创建进程级唯一临时文件，路径写入 _TMP_JSON
make_tmp() {
    _TMP_JSON=$(mktemp /tmp/sb_XXXXXX.json)
}

# 原子化写入配置并进行语法检查
# 调用前须先 make_tmp，再把内容写入 $_TMP_JSON
save_and_restart() {
    if [[ -z "$_TMP_JSON" || ! -f "$_TMP_JSON" ]]; then
        echo -e "${RED}错误: 临时配置文件不存在。${PLAIN}"
        return 1
    fi

    if $SB_BIN check -c "$_TMP_JSON" > /dev/null 2>&1; then
        mv "$_TMP_JSON" "$CONFIG_FILE"
        _TMP_JSON=""          # mv 后路径已失效，清空防止 trap 误删
        systemctl restart sing-box
        return 0
    else
        echo -e "${RED}✘ 配置语法检查失败，请检查参数设置。旧配置已保留。${PLAIN}"
        rm -f "$_TMP_JSON"
        _TMP_JSON=""
        return 1
    fi
}

# ============================================================
# [修复2] 数组越界保护：统一输入校验函数
# ============================================================
# 用法: validate_index <用户输入> <数组最大长度>
# 返回 0=合法, 1=非法（自动打印错误）
validate_index() {
    local input=$1
    local max=$2
    if [[ ! "$input" =~ ^[0-9]+$ ]] || (( input < 1 || input > max )); then
        echo -e "${RED}✘ 无效序号，请输入 1 ~ $max 之间的数字。${PLAIN}"
        return 1
    fi
    return 0
}

# 辅助函数：只在指定的 CERT_DIR 目录下扫描
find_certs() {
    local domain=$1
    local search_dir="$CERT_DIR/$domain"
    
    CERT_PATH=""; KEY_PATH=""
    
    if [[ -d "$search_dir" ]]; then
        local c_names=("server.crt" "fullchain.cer" "fullchain.pem" "$domain.cer" "cert.pem")
        local k_names=("server.key" "$domain.key" "privkey.pem" "cert.key")

        for f in "${c_names[@]}"; do [[ -f "$search_dir/$f" ]] && CERT_PATH="$search_dir/$f" && break; done
        for f in "${k_names[@]}"; do [[ -f "$search_dir/$f" ]] && KEY_PATH="$search_dir/$f" && break; done
    fi
}

init_config() {
    mkdir -p /etc/sing-box "$LINK_DIR" "$CERT_DIR"
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}

get_ip() {
    local mode=${1:-"all"}
    local ip4 ip6

    ip4=$(curl -s4 --connect-timeout 3 icanhazip.com || curl -s4 --connect-timeout 3 ifconfig.me)
    ip6=$(curl -s6 --connect-timeout 3 icanhazip.com || curl -s6 --connect-timeout 3 ifconfig.me)

    case $mode in
        4) echo "$ip4" ;;
        6) [[ -n "$ip6" ]] && echo "[$ip6]" ;;
        "all")
            if [[ -n "$ip4" ]]; then
                echo "$ip4"
            elif [[ -n "$ip6" ]]; then
                echo "[$ip6]"
            else
                echo "127.0.0.1"
            fi
            ;;
    esac
}

# ============================================================
# [修复3] 端口占用检测：独立函数，供所有添加节点流程调用
# ============================================================
# 用法: check_port <端口号>
# 返回 0=端口空闲可用, 1=端口已被占用
check_port() {
    local port=$1
    # 校验端口号合法性（1-65535）
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo -e "${RED}✘ 端口号无效，请输入 1 ~ 65535 之间的数字。${PLAIN}"
        return 1
    fi
    # 用 ss 检测 TCP/UDP 监听，兼容无 lsof 的环境
    if ss -tlnpu 2>/dev/null | grep -q ":${port}[[:space:]]"; then
        local proc
        proc=$(ss -tlnpu 2>/dev/null | grep ":${port}[[:space:]]" | awk '{print $NF}' | head -1)
        echo -e "${RED}✘ 端口 $port 已被占用！进程信息: $proc${PLAIN}"
        echo -e "${YELLOW}  提示: 请换一个端口，或用 'ss -tlnpu | grep :$port' 查看详情。${PLAIN}"
        return 1
    fi
    return 0
}

show_status() {
    local PID=$(systemctl show -p MainPID sing-box | cut -d= -f2)
    local STATUS=$(systemctl is-active --quiet sing-box && echo -e "${GREEN}运行中${PLAIN}" || echo -e "${RED}已停止${PLAIN}")
    local ENABLE=$(systemctl is-enabled --quiet sing-box 2>/dev/null && echo -e "${GREEN}已启用${PLAIN}" || echo -e "${RED}已禁用${PLAIN}")
    local VER=$($SB_BIN version 2>/dev/null | awk '/version/ {print $3}')
    local MEM=$(ps -o rss= -p "$PID" 2>/dev/null | awk '{printf "%.2fMB", $1/1024}' || echo "0MB")

    echo -e "${YELLOW}--- 服务监控 ---${PLAIN}"
    echo -e "运行状态: $STATUS\t\t开机自启: $ENABLE"
    echo -e "版本信息: ${BLUE}${VER:-未知}${PLAIN}\t\t内存占用: ${CYAN}${MEM}${PLAIN}"
    echo -e "----------------"
}

# ============================================================
# [修复4] 日志查看：新增独立函数
# ============================================================
view_logs() {
    while true; do
        clear
        echo -e "${YELLOW}--- 日志查看 ---${PLAIN}"
        echo "1. 查看最近 50 条日志"
        echo "2. 查看最近 200 条日志"
        echo "3. 实时跟踪日志 (Ctrl+C 退出)"
        echo "4. 查看错误日志 (仅 error/warn)"
        echo "5. 导出日志到文件 (/root/singbox_$(date +%Y%m%d).log)"
        echo "0. 返回"
        read -p "请选择: " log_choice

        case $log_choice in
            1)
                echo -e "\n${CYAN}--- 最近 50 条日志 ---${PLAIN}"
                journalctl -u sing-box -n 50 --no-pager
                pause
                ;;
            2)
                echo -e "\n${CYAN}--- 最近 200 条日志 ---${PLAIN}"
                journalctl -u sing-box -n 200 --no-pager | less
                ;;
            3)
                echo -e "\n${CYAN}--- 实时日志 (Ctrl+C 退出) ---${PLAIN}"
                journalctl -u sing-box -f
                ;;
            4)
                echo -e "\n${CYAN}--- 错误/警告日志 ---${PLAIN}"
                journalctl -u sing-box -n 200 --no-pager -p warning
                pause
                ;;
            5)
                local LOG_FILE="/root/singbox_$(date +%Y%m%d).log"
                journalctl -u sing-box --no-pager > "$LOG_FILE"
                echo -e "${GREEN}✔ 日志已导出至: ${BLUE}$LOG_FILE${PLAIN}"
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}无效输入${PLAIN}"; sleep 1 ;;
        esac
    done
}

# --- 功能模块 ---

apply_cert() {
    echo -e "${YELLOW}--- ACME 域名证书申请 ---${PLAIN}"
    read -p "请输入解析到本机的域名: " domain
    [[ -z "$domain" ]] && echo -e "${RED}✘ 错误：域名不能为空${PLAIN}" && pause && return

    echo -e "${CYAN}正在安装/检查必要依赖...${PLAIN}"
    if [[ -n $(command -v apt) ]]; then
        apt update && apt install -y socat cron curl uuid-runtime
    elif [[ -n $(command -v yum) ]]; then
        yum install -y socat crontabs curl util-linux
    elif [[ -n $(command -v dnf) ]]; then
        dnf install -y socat crontabs curl util-linux
    fi

    local ACME_BIN="$HOME/.acme.sh/acme.sh"
    if [ ! -f "$ACME_BIN" ]; then
        echo -e "${CYAN}正在安装 acme.sh 核心组件...${PLAIN}"
        curl https://get.acme.sh | sh -s email=admin@$domain
    fi

    local port_80_pid=$(lsof -i:80 -t 2>/dev/null)
    if [[ -n "$port_80_pid" ]]; then
        echo -e "${YELLOW}检测到 80 端口被占用，尝试临时释放...${PLAIN}"
        systemctl stop nginx 2>/dev/null
        systemctl stop apache2 2>/dev/null
        systemctl stop sing-box 2>/dev/null
        [[ -n $(lsof -i:80 -t 2>/dev/null) ]] && kill -9 $(lsof -i:80 -t 2>/dev/null) 2>/dev/null
    fi

    echo -e "${YELLOW}正在通过 Let's Encrypt 申请证书...${PLAIN}"
    "$ACME_BIN" --issue -d "$domain" --standalone --server letsencrypt --log

    if [ $? -eq 0 ]; then
        local target_dir="$CERT_DIR/$domain"
        mkdir -p "$target_dir"
        "$ACME_BIN" --install-cert -d "$domain" \
            --key-file "$target_dir/server.key" \
            --fullchain-file "$target_dir/server.crt"
        echo -e "${GREEN}✔ 证书安装成功！${PLAIN}"
        echo -e "路径: ${BLUE}$target_dir${PLAIN}"
    else
        echo -e "${RED}✘ 申请失败，原因可能如下：${PLAIN}"
        echo -e "1. 域名解析未生效（请检查 DNS 是否指向本机）"
        echo -e "2. 80 端口被防火墙拦截（请检查云平台安全组设置）"
        echo -e "3. 申请频率过快（Let's Encrypt 有频次限制）"
    fi

    systemctl start sing-box 2>/dev/null
    pause
}

auto_backup() {
    mkdir -p "$BACKUP_DIR"
    local TIME=$(date +%Y%m%d_%H%M%S)
    local B_NAME="auto_bak_before_update_$TIME.tar.gz"
    
    mkdir -p "/tmp/sb_auto_bak"
    [[ -f "/usr/local/bin/sing-box" ]] && cp "/usr/local/bin/sing-box" "/tmp/sb_auto_bak/"
    [[ -d "/etc/sing-box" ]] && cp -r /etc/sing-box/* "/tmp/sb_auto_bak/"
    
    tar -czf "$BACKUP_DIR/$B_NAME" -C "/tmp/sb_auto_bak" . >/dev/null 2>&1
    rm -rf "/tmp/sb_auto_bak"
    echo -e "${YELLOW}[自动快照] 更新前已备份至: $B_NAME${PLAIN}"
}

backup_restore() {
    clear
    echo -e "${YELLOW}--- 备份与还原 ---${PLAIN}"
    echo "1. 立即备份 (内核 + 配置)"
    echo "2. 还原备份"
    echo "0. 返回"
    read -p "选择: " br_choice
    [[ "$br_choice" == "0" ]] && return
    
    mkdir -p "$BACKUP_DIR"
    if [[ "$br_choice" == "1" ]]; then
        local TIME=$(date +%Y%m%d_%H%M%S)
        mkdir -p "/tmp/sb_bak"
        [[ -f "/usr/local/bin/sing-box" ]] && cp /usr/local/bin/sing-box "/tmp/sb_bak/"
        [[ -d "/etc/sing-box" ]] && cp -r /etc/sing-box "/tmp/sb_bak/"
        tar -czf "$BACKUP_DIR/singbox_full_$TIME.tar.gz" -C "/tmp/sb_bak" .
        rm -rf "/tmp/sb_bak"
        echo -e "${GREEN}备份完成: singbox_full_$TIME.tar.gz${PLAIN}"
    elif [[ "$br_choice" == "2" ]]; then
        local files=($(ls "$BACKUP_DIR" | grep ".tar.gz"))
        if [ ${#files[@]} -eq 0 ]; then
            echo -e "${RED}没有找到备份文件${PLAIN}"
        else
            ls "$BACKUP_DIR" | grep ".tar.gz" | cat -n
            read -p "选择要还原的序号: " r_idx
            # [修复2] 越界保护
            if ! validate_index "$r_idx" "${#files[@]}"; then pause; return; fi
            local R_FILE=${files[$((r_idx-1))]}
            if [[ -n "$R_FILE" ]]; then
                systemctl stop sing-box
                tar -xzf "$BACKUP_DIR/$R_FILE" -C /tmp/
                [[ -f /tmp/sing-box ]] && cp /tmp/sing-box /usr/local/bin/sing-box
                [[ -d /tmp/sing-box ]] && cp -r /tmp/sing-box/* /etc/sing-box/
                systemctl restart sing-box
                echo -e "${GREEN}备份 $R_FILE 还原成功${PLAIN}"
            fi
        fi
    fi
    pause
}

install_base() {
    echo -e "${GREEN}>>> 正在安装依赖并检测架构...${PLAIN}"

    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl jq tar wget uuid-runtime
    elif command -v yum &>/dev/null; then
        yum install -y curl jq tar wget util-linux
    else
        echo -e "${RED}不支持的包管理器，请手动安装依赖${PLAIN}"
        pause && return
    fi

    local arch=""
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"; pause; return ;;
    esac

    echo -e "${CYAN}获取 sing-box 最新版本...${PLAIN}"
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    if [[ -z "$TAG" ]]; then
        echo -e "${RED}无法获取最新版本号，请检查网络或 GitHub API 限制${PLAIN}"
        pause && return
    fi
    echo -e "${CYAN}检测到架构: $arch, 即将下载版本: $TAG${PLAIN}"

    local TMP_DIR=$(mktemp -d)
    local url="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${arch}.tar.gz"

    wget -q --show-progress -O "$TMP_DIR/sing-box.tar.gz" "$url" || {
        echo -e "${RED}下载失败，请检查版本或网络${PLAIN}"
        rm -rf "$TMP_DIR"
        pause && return
    }

    tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR" || {
        echo -e "${RED}解压失败${PLAIN}"
        rm -rf "$TMP_DIR"
        pause && return
    }

    local BIN=$(find "$TMP_DIR" -type f -name "sing-box" -executable | head -1)
    if [[ -z "$BIN" ]]; then
        echo -e "${RED}未找到 sing-box 可执行文件${PLAIN}"
        rm -rf "$TMP_DIR"
        pause && return
    fi

    cp "$BIN" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "$TMP_DIR"

    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="/etc/sing-box/config.json"
        echo -e "${YELLOW}CONFIG_FILE 未定义，已默认使用 $CONFIG_FILE${PLAIN}"
    fi

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box

    if declare -F init_config &>/dev/null; then
        init_config
    else
        mkdir -p "$(dirname "$CONFIG_FILE")"
        echo -e "${YELLOW}init_config 函数未定义，已创建配置目录${PLAIN}"
    fi

    if [[ "$0" != "/usr/local/bin/ssb" ]]; then
        cp "$0" /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
        echo -e "${GREEN}安装到目录${PLAIN}"
    fi

    systemctl start sing-box
    echo -e "${GREEN}安装完成${PLAIN}"
    pause
}

add_node() {
    if [[ ! -f "$SB_BIN" ]] && ! command -v sing-box &> /dev/null; then
        echo -e "${RED}✘ 错误: 未检测到 sing-box 程序。请先执行安装脚本后再配置节点！${PLAIN}"
        pause; return
    fi

    clear
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}\n1. VLESS + Reality\n2. TUIC v5\n3. Hysteria2\n4. Shadowsocks\n5. VLESS + WS + CF\n6. Socks5\n7. HTTPS Proxy\n8. Trojan\n0. 返回"
    read -p "请选择 [0-8]: " choice

    [[ "$choice" == "0" || -z "$choice" ]] && return

    local IP=$(get_ip)
    local UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    local LINK="" TAG=""

    gen_pass() { openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12; }

    case $choice in
        1) # VLESS + Reality
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            # [修复3] 端口占用检测
            if ! check_port "$PORT"; then pause; return; fi
            read -p "目标 SNI (默认 music.apple.com): " SNI; SNI=${SNI:-"music.apple.com"}
            TAG="reality-${PORT}"
            KEYS=$($SB_BIN generate reality-keypair)
            PRIVATE=$(echo "$KEYS" | awk -F': ' '/Private/ {print $2}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS" | awk -F': ' '/Public/ {print $2}' | tr -d '[:space:]')
            SID=$(openssl rand -hex 8)
            # [修复1] 使用 mktemp
            make_tmp
            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg priv "$PRIVATE" --arg sid "$SID" --arg tag "$TAG" \
               '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}]' \
               "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SID&type=tcp&flow=xtls-rprx-vision#$TAG"
            ;;
        2|3|7|8) # 需要证书的协议
            local p_type def_p usr_json tls_json
            case $choice in 2) p_type="tuic"; def_p="8443" ;; 3) p_type="hysteria2"; def_p="443" ;; 7) p_type="http"; def_p="443" ;; 8) p_type="trojan"; def_p="443" ;; esac
            read -p "端口 (默认 $def_p): " PORT; PORT=${PORT:-$def_p}
            # [修复3] 端口占用检测
            if ! check_port "$PORT"; then pause; return; fi
            read -p "密码 (回车随机生成): " PASS; PASS=${PASS:-$(gen_pass)}
            TAG="${p_type}-${PORT}"
            echo -e "1. 自签名证书 | 2. 自动检测 ACME 证书 ($CERT_DIR)"
            read -p "证书类型: " c_choice
            if [[ "$c_choice" == "2" ]]; then
                read -p "对应域名: " domain; find_certs "$domain"
                [[ -z "$CERT_PATH" ]] && { echo -e "${RED}✘ 错误: 未找到证书${PLAIN}"; pause; return; }
                SNI_NAME="$domain"; ALLOW_INS="0"
            else
                CERT_PATH="/etc/sing-box/${p_type}.crt"; KEY_PATH="/etc/sing-box/${p_type}.key"
                [[ ! -f "$CERT_PATH" ]] && openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=amazon.com" -days 3650 2>/dev/null
                SNI_NAME="amazon.com"; ALLOW_INS="1"
            fi
            tls_json="{\"enabled\":true,\"certificate_path\":\"$CERT_PATH\",\"key_path\":\"$KEY_PATH\"}"
            case "$p_type" in
                tuic) usr_json="[{\"uuid\":\"$UUID\",\"password\":\"$PASS\"}]"; tls_json="{\"enabled\":true,\"certificate_path\":\"$CERT_PATH\",\"key_path\":\"$KEY_PATH\",\"alpn\":[\"h3\"]}"
                      LINK="tuic://$UUID:$PASS@$IP:$PORT?sni=$SNI_NAME&alpn=h3&allow_insecure=$ALLOW_INS&congestion_control=bbr#$TAG" ;;
                hysteria2) usr_json="[{\"password\":\"$PASS\"}]"; LINK="hysteria2://$PASS@$IP:$PORT?insecure=$ALLOW_INS&sni=$SNI_NAME#$TAG" ;;
                trojan) usr_json="[{\"password\":\"$PASS\"}]"; LINK="trojan://$PASS@$IP:$PORT?security=tls&sni=$SNI_NAME&allowInsecure=$ALLOW_INS#$TAG" ;;
                http) usr_json="[{\"username\":\"$PASS\",\"password\":\"$PASS\"}]"; LINK="https://$PASS:$PASS@$IP:$PORT?security=tls&sni=$SNI_NAME&allowInsecure=$ALLOW_INS#$TAG" ;;
            esac
            # [修复1] 使用 mktemp
            make_tmp
            jq --arg port "$PORT" --arg type "$p_type" --arg tag "$TAG" --argjson users "$usr_json" --argjson tls "$tls_json" \
               '.inbounds += [{"type":$type,"tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":$users,"tls":$tls}]' "$CONFIG_FILE" > "$_TMP_JSON"
            ;;
        4) # Shadowsocks
            read -p "端口 (默认 8388): " PORT; PORT=${PORT:-8388}
            # [修复3] 端口占用检测
            if ! check_port "$PORT"; then pause; return; fi
            PASS=$(openssl rand -base64 16); METHOD="2022-blake3-aes-128-gcm"; TAG="ss-${PORT}"
            make_tmp
            jq --arg port "$PORT" --arg pass "$PASS" --arg method "$METHOD" --arg tag "$TAG" \
               '.inbounds += [{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$PORT#$TAG"
            ;;
        5) # VLESS + WS + CF
            read -p "域名: " domain; find_certs "$domain"; [[ -z "$CERT_PATH" ]] && { echo -e "${RED}✘ 错误: 证书不存在${PLAIN}"; pause; return; }
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            # [修复3] 端口占用检测
            if ! check_port "$PORT"; then pause; return; fi
            read -p "路径 (默认 /video): " WSPATH; WSPATH=${WSPATH:-"/video"}; TAG="vless-ws-${PORT}"
            make_tmp
            jq --arg port "$PORT" --arg uuid "$UUID" --arg path "$WSPATH" --arg domain "$domain" --arg tag "$TAG" --arg cert "$CERT_PATH" --arg key "$KEY_PATH" \
               '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":$path},"tls":{"enabled":true,"server_name":$domain,"certificate_path":$cert,"key_path":$key}}]' "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="vless://$UUID@$domain:$PORT?encryption=none&security=tls&type=ws&path=${WSPATH//\//%2F}#$TAG"
            ;;
        6) # Socks5
            read -p "端口: " PORT
            # [修复3] 端口占用检测
            if ! check_port "$PORT"; then pause; return; fi
            read -p "用户: " USER; read -p "密码: " PASS; TAG="socks-${PORT}"
            make_tmp
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" --arg tag "$TAG" \
               '.inbounds += [{"type":"socks","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}]}]' "$CONFIG_FILE" > "$_TMP_JSON"
            LINK="socks5://$USER:$PASS@$IP:$PORT#$TAG"
            ;;
    esac

    if [[ -n "$_TMP_JSON" && -f "$_TMP_JSON" ]]; then
        if save_and_restart; then
            [[ -n "$LINK" ]] && echo "$LINK" > "$LINK_DIR/${TAG}.link"
            echo -e "${GREEN}✔ 节点添加成功！${PLAIN}\n分享链接: ${BLUE}$LINK${PLAIN}"
        fi
    fi
    pause
}

manage_configs() {
    clear
    echo -e "${YELLOW}--- 节点配置查看 ---${PLAIN}"
    local count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择要查看的序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return

    # [修复2] 越界保护
    if ! validate_index "$idx" "$count"; then pause; return; fi

    local TAG=$(jq -r ".inbounds[$(($idx-1))].tag" "$CONFIG_FILE")
    local CONF=$(jq -c ".inbounds[$(($idx-1))]" "$CONFIG_FILE")
    local TYPE=$(echo "$CONF" | jq -r .type)
    local PORT=$(echo "$CONF" | jq -r .listen_port)
    local IP=$(get_ip)

    echo -e "\n${GREEN}================ 原始 JSON 配置 ================${PLAIN}"
    echo "$CONF" | jq .
    echo -e "${GREEN}===============================================${PLAIN}"

    echo -e "\n${YELLOW}>>>> 节点分享链接 <<<<${PLAIN}"
    
    if [[ -f "$LINK_DIR/${TAG}.link" ]]; then
        echo -e "${BLUE}$(cat "$LINK_DIR/${TAG}.link")${PLAIN}"
    else
        echo -e "${RED}未找到持久化链接文件，尝试根据当前配置生成...${PLAIN}"
        
        local SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')
        local HOST=${SNI:-$IP}

        case $TYPE in
            vless)
                local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                if [[ -n "$SID" ]]; then
                    echo -e "${RED}Reality 节点的公钥不存储在配置文件中，无法生成完整链接。${PLAIN}"
                else
                    local WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
                    echo -e "${BLUE}vless://$UUID@$HOST:$PORT?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$TAG${PLAIN}"
                fi
                ;;
            tuic)
                local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                echo -e "${BLUE}tuic://$UUID:$PASS@$HOST:$PORT?congestion_control=bbr&sni=$SNI&alpn=h3#$TAG${PLAIN}"
                ;;
            hysteria2)
                local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                echo -e "${BLUE}hysteria2://$PASS@$HOST:$PORT?sni=$SNI#$TAG${PLAIN}"
                ;;
            shadowsocks)
                local METHOD=$(echo "$CONF" | jq -r .method); local PASS=$(echo "$CONF" | jq -r .password)
                local SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
                echo -e "${BLUE}ss://$SS_BASE64@$IP:$PORT#$TAG${PLAIN}"
                ;;
            http)
                local USER=$(echo "$CONF" | jq -r '.users[0].username // ""')
                local PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                if [[ -n "$USER" ]]; then
                    echo -e "${BLUE}https://$USER:$PASS@$HOST:$PORT#$TAG${PLAIN}"
                else
                    echo -e "${BLUE}https://$HOST:$PORT#$TAG${PLAIN}"
                fi
                ;;
            trojan)
                local PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                local INSECURE=$(echo "$CONF" | jq -r '.tls.insecure // false')
                local INS_VAL="0"; [[ "$INSECURE" == "true" ]] && INS_VAL="1"
                echo -e "${BLUE}trojan://$PASS@$HOST:$PORT?security=tls&sni=$SNI&allowInsecure=$INS_VAL#$TAG${PLAIN}"
                ;;
            *)
                echo -e "${RED}暂不支持该协议 ($TYPE) 的链接还原${PLAIN}"
                ;;
        esac
    fi
    echo ""
    pause
}

edit_node() {
    if [[ ! -f "$SB_BIN" ]] && ! command -v sing-box &> /dev/null; then
        echo -e "${RED}✘ 错误: 未检测到 sing-box，请先安装${PLAIN}"; pause; return
    fi

    clear
    echo -e "${YELLOW}--- 修改/删除节点配置 ---${PLAIN}"
    local count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q返回): " idx
    [[ "$idx" == "q" || -z "$idx" ]] && return

    # [修复2] 越界保护
    if ! validate_index "$idx" "$count"; then pause; return; fi
    
    local i=$(($idx-1))
    local TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
    local TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")

    [[ "$TAG" == "null" ]] && { echo -e "${RED}选择无效${PLAIN}"; pause; return; }

    echo -e "\n${CYAN}当前节点: $TAG ($TYPE)${PLAIN}"
    echo "1. 修改端口"
    echo "2. 修改 UUID / 密码"
    echo "3. 修改 SNI (域名)"
    echo "4. 删除此节点 (自动清理关联路由)"
    echo "0. 返回"
    read -p "请选择操作: " op

    case $op in
        1)
            read -p "请输入新端口: " NEW_PORT
            [[ -z "$NEW_PORT" ]] && return
            # [修复3] 修改端口时也检测占用
            if ! check_port "$NEW_PORT"; then pause; return; fi
            make_tmp
            jq ".inbounds[$i].listen_port = ($NEW_PORT|tonumber)" "$CONFIG_FILE" > "$_TMP_JSON"
            ;;
        2)
            local AUTH_FIELD=".users[0].uuid"
            [[ "$TYPE" =~ ^(trojan|hysteria2|http|tuic)$ ]] && AUTH_FIELD=".users[0].password"
            [[ "$TYPE" == "shadowsocks" ]] && AUTH_FIELD=".password" 
            
            read -p "请输入新的身份凭证: " NEW_AUTH
            [[ -z "$NEW_AUTH" ]] && return
            make_tmp
            jq ".inbounds[$i]$AUTH_FIELD = \"$NEW_AUTH\"" "$CONFIG_FILE" > "$_TMP_JSON"
            ;;
        3)
            read -p "请输入新的 SNI: " NEW_SNI
            [[ -z "$NEW_SNI" ]] && return
            make_tmp
            jq ".inbounds[$i].tls.server_name = \"$NEW_SNI\" | 
                if .inbounds[$i].tls.reality then .inbounds[$i].tls.reality.handshake.server = \"$NEW_SNI\" else . end" "$CONFIG_FILE" > "$_TMP_JSON"
            ;;
        4)
            read -p "确定删除 $TAG 及其关联路由吗？(y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                make_tmp
                jq --arg tag "$TAG" '
                    (if .route.rules then 
                        del(.route.rules[] | select(.inbound == $tag or (if .inbound|type=="array" then .inbound|any(. == $tag) else false end))) 
                    else . end) | 
                    del(.inbounds[] | select(.tag == $tag))
                ' "$CONFIG_FILE" > "$_TMP_JSON"
                
                if save_and_restart; then
                    rm -f "$LINK_DIR/${TAG}.link"
                    echo -e "${GREEN}✔ 节点及所有关联路由规则已删除${PLAIN}"
                fi
            fi
            pause && return
            ;;
        *) return ;;
    esac

    if [[ -n "$_TMP_JSON" && -f "$_TMP_JSON" ]]; then
        if save_and_restart; then
            echo -e "${GREEN}✔ 配置已更新！${PLAIN}"
            
            local CONF=$(jq -c ".inbounds[] | select(.tag == \"$TAG\")" "$CONFIG_FILE")
            [[ -z "$CONF" ]] && return

            local PORT=$(echo "$CONF" | jq -r .listen_port)
            local IP=$(get_ip)
            local SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')
            local NEW_LINK=""

            case $TYPE in
                vless)
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                    local FLOW=$(echo "$CONF" | jq -r '.users[0].flow // ""')
                    NEW_LINK="vless://$UUID@$IP:$PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$(echo "$CONF" | jq -r '.tls.reality.public_key // ""')&sid=$SID&type=tcp&flow=$FLOW#$TAG"
                    ;;
                trojan)
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="trojan://$PASS@$IP:$PORT?security=tls&sni=$SNI&allowInsecure=1#$TAG"
                    ;;
                hysteria2)
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="hysteria2://$PASS@$IP:$PORT?sni=$SNI&insecure=1#$TAG"
                    ;;
                tuic)
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid'); local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="tuic://$UUID:$PASS@$IP:$PORT?congestion_control=bbr&sni=$SNI&alpn=h3&allow_insecure=1#$TAG"
                    ;;
                shadowsocks)
                    local METHOD=$(echo "$CONF" | jq -r .method); local PASS=$(echo "$CONF" | jq -r .password)
                    NEW_LINK="ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$PORT#$TAG"
                    ;;
            esac

            if [[ -n "$NEW_LINK" ]]; then
                echo "$NEW_LINK" > "$LINK_DIR/${TAG}.link"
                echo -e "${BLUE}新分享链接: $NEW_LINK${PLAIN}"
            fi
        fi
    fi
    pause
}


# ==============================================================
# parse_proxy_link — 全协议解析
#
# 支持: ss:// socks5:// https:// vless:// trojan:// hysteria2:// tuic://
#
# 输出全局变量:
#   hop_type  — 1=SS 2=Socks5 3=HTTP 4=VLESS 5=Trojan 6=Hysteria2 7=TUIC
#   R_ADDR    — 服务器地址
#   R_PORT    — 端口
#   R_PASS    — 密码 / UUID（ss为密码，vless/tuic为UUID）
#   R_USER    — 用户名（socks5/http用）
#   R_METHOD  — 加密方式（ss专用）
#   R_UUID    — UUID（vless / tuic 专用）
#   R_SNI     — TLS server_name
#   R_FLOW    — vless flow（如 xtls-rprx-vision）
#   R_PBK     — reality public_key
#   R_SID     — reality short_id
#   R_ALPN    — ALPN（tuic 用，逗号分隔字符串）
#   R_TLS_INSECURE — 0/1
#   R_TRANSPORT    — 传输层类型 (ws/grpc/tcp 等)
#   R_WS_PATH      — WebSocket path
#   R_NAME         — 节点备注（# 后的内容）
# ==============================================================
parse_proxy_link() {
    local link=$1
    local content qs host_port user_info

    # 清空所有输出变量
    hop_type="" R_ADDR="" R_PORT="" R_PASS="" R_USER="" R_METHOD=""
    R_UUID="" R_SNI="" R_FLOW="" R_PBK="" R_SID="" R_ALPN=""
    R_TLS_INSECURE="0" R_TRANSPORT="tcp" R_WS_PATH="" R_NAME=""

    # 提取 # 后的备注
    R_NAME=$(echo "$link" | grep -oP '(?<=#)[^#]*$' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "")

    # 工具函数：URL 解码
    _urldecode() { python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "$1"; }

    # 工具函数：从查询串取值  _qs_get <qs> <key>
    _qs_get() { echo "$1" | tr '&' '\n' | grep -i "^${2}=" | head -1 | cut -d= -f2- | _urldecode; }

    # ---------- Shadowsocks ----------
    if [[ "$link" =~ ^ss:// ]]; then
        hop_type=1
        content=$(echo "${link}" | sed 's|ss://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            local b64_part=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'/' -f1 | cut -d'?' -f1)
            local decoded=$(echo "$b64_part" | tr '_-' '/+' | \
                awk '{l=length($0)%4; if(l==2) $0=$0"=="; else if(l==3) $0=$0"="; print}' | \
                base64 -d 2>/dev/null)
            R_METHOD=$(echo "$decoded" | cut -d':' -f1)
            R_PASS=$(echo "$decoded"   | cut -d':' -f2-)
        else
            local decoded=$(echo "$content" | tr '_-' '/+' | \
                awk '{l=length($0)%4; if(l==2) $0=$0"=="; else if(l==3) $0=$0"="; print}' | \
                base64 -d 2>/dev/null)
            if [[ "$decoded" =~ ^(.+):(.+)@(.+):([0-9]+) ]]; then
                R_METHOD="${BASH_REMATCH[1]}"; R_PASS="${BASH_REMATCH[2]}"
                host_port="${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
            fi
        fi
        R_ADDR=$(echo "$host_port" | cut -d':' -f1)
        R_PORT=$(echo "$host_port" | cut -d':' -f2)

    # ---------- Socks5 ----------
    elif [[ "$link" =~ ^socks5?:// ]]; then
        hop_type=2
        content=$(echo "$link" | sed 's|socks5\?://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'/' -f1 | cut -d'?' -f1)
            R_USER=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2-)
        else
            host_port=$(echo "$content" | cut -d'/' -f1 | cut -d'?' -f1)
        fi
        R_ADDR=$(echo "$host_port" | cut -d':' -f1)
        R_PORT=$(echo "$host_port" | cut -d':' -f2)

    # ---------- HTTPS 代理 ----------
    elif [[ "$link" =~ ^https:// ]]; then
        hop_type=3
        content=$(echo "$link" | sed 's|https://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'/' -f1 | cut -d'?' -f1)
            R_USER=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2-)
        else
            host_port=$(echo "$content" | cut -d'/' -f1 | cut -d'?' -f1)
        fi
        R_ADDR=$(echo "$host_port" | cut -d':' -f1)
        R_PORT=$(echo "$host_port" | cut -d':' -f2)

    # ---------- VLESS ----------
    elif [[ "$link" =~ ^vless:// ]]; then
        hop_type=4
        content=$(echo "$link" | sed 's|vless://||' | cut -d'#' -f1)
        R_UUID=$(echo "$content" | cut -d'@' -f1)
        host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        # IPv6 地址处理  [::1]:port
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni")
        [[ -z "$R_SNI" ]] && R_SNI=$(_qs_get "$qs" "host")
        R_FLOW=$(_qs_get "$qs" "flow")
        R_PBK=$(_qs_get "$qs" "pbk")
        R_SID=$(_qs_get "$qs" "sid")
        R_TRANSPORT=$(_qs_get "$qs" "type"); R_TRANSPORT=${R_TRANSPORT:-tcp}
        R_WS_PATH=$(_qs_get "$qs" "path")
        local ins=$(_qs_get "$qs" "allowInsecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"
        R_PASS="$R_UUID"   # 统一 R_PASS 以兼容路由模块

    # ---------- Trojan ----------
    elif [[ "$link" =~ ^trojan:// ]]; then
        hop_type=5
        content=$(echo "$link" | sed 's|trojan://||' | cut -d'#' -f1)
        R_PASS=$(echo "$content" | cut -d'@' -f1)
        host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni")
        [[ -z "$R_SNI" ]] && R_SNI=$(_qs_get "$qs" "host")
        R_TRANSPORT=$(_qs_get "$qs" "type"); R_TRANSPORT=${R_TRANSPORT:-tcp}
        R_WS_PATH=$(_qs_get "$qs" "path")
        local ins=$(_qs_get "$qs" "allowInsecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"

    # ---------- Hysteria2 ----------
    elif [[ "$link" =~ ^(hysteria2|hy2):// ]]; then
        hop_type=6
        content=$(echo "$link" | sed 's|hysteria2://||;s|hy2://||' | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            R_PASS=$(echo "$content" | cut -d'@' -f1)
            host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        else
            host_port=$(echo "$content" | cut -d'?' -f1)
        fi
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni")
        local ins=$(_qs_get "$qs" "insecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"

    # ---------- TUIC ----------
    elif [[ "$link" =~ ^tuic:// ]]; then
        hop_type=7
        content=$(echo "$link" | sed 's|tuic://||' | cut -d'#' -f1)
        # tuic://UUID:PASSWORD@host:port?...
        local auth_part=$(echo "$content" | cut -d'@' -f1)
        host_port=$(echo "$content" | cut -d'@' -f2 | cut -d'?' -f1)
        qs=$(echo "$content" | grep -o '?.*' | cut -c2-)
        R_UUID=$(echo "$auth_part" | cut -d':' -f1)
        R_PASS=$(echo "$auth_part" | cut -d':' -f2-)
        if [[ "$host_port" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
            R_ADDR="${BASH_REMATCH[1]}"; R_PORT="${BASH_REMATCH[2]}"
        else
            R_ADDR=$(echo "$host_port" | cut -d':' -f1)
            R_PORT=$(echo "$host_port" | cut -d':' -f2)
        fi
        R_SNI=$(_qs_get "$qs" "sni")
        R_ALPN=$(_qs_get "$qs" "alpn")
        local ins=$(_qs_get "$qs" "allow_insecure")
        [[ "$ins" == "1" || "$ins" == "true" ]] && R_TLS_INSECURE="1"
    fi
}

# ==============================================================
# link_to_outbound_json — 把 parse_proxy_link 的结果转为出站 JSON
# 用法: link_to_outbound_json <tag>
# 成功输出 JSON 字符串到 stdout，失败输出空
# ==============================================================
link_to_outbound_json() {
    local tag=${1:-"node-$(date +%s)"}
    local json=""

    case "$hop_type" in
        1) # Shadowsocks
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg m "$R_METHOD" --arg pw "$R_PASS" \
                '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pw}')
            ;;
        2) # Socks5
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg u "$R_USER" --arg pw "$R_PASS" \
                '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"}
                 + (if $u != "" then {"username":$u,"password":$pw} else {} end)')
            ;;
        3) # HTTP/HTTPS 代理
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg u "$R_USER" --arg pw "$R_PASS" \
                '{"type":"http","tag":$t,"server":$s,"server_port":($p|tonumber),"tls":{"enabled":true}}
                 + (if $u != "" then {"username":$u,"password":$pw} else {} end)')
            ;;
        4) # VLESS
            local tls_obj
            if [[ -n "$R_PBK" ]]; then
                # Reality
                tls_obj=$(jq -n \
                    --arg sni "$R_SNI" --arg pbk "$R_PBK" --arg sid "$R_SID" \
                    --argjson ins "$R_TLS_INSECURE" \
                    '{"enabled":true,"server_name":$sni,"insecure":($ins=="1"),
                      "reality":{"enabled":true,"public_key":$pbk,"short_id":$sid}}')
            else
                tls_obj=$(jq -n \
                    --arg sni "$R_SNI" --argjson ins "$([ "$R_TLS_INSECURE" = "1" ] && echo true || echo false)" \
                    '{"enabled":true,"server_name":$sni,"insecure":$ins}')
            fi
            local transport_obj="{}"
            if [[ "$R_TRANSPORT" == "ws" ]]; then
                transport_obj=$(jq -n --arg p "$R_WS_PATH" '{"type":"ws","path":$p}')
            elif [[ "$R_TRANSPORT" == "grpc" ]]; then
                transport_obj=$(jq -n --arg p "$R_WS_PATH" '{"type":"grpc","service_name":$p}')
            fi
            local flow_part="{}"
            [[ -n "$R_FLOW" ]] && flow_part=$(jq -n --arg f "$R_FLOW" '{"flow":$f}')
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg uuid "$R_UUID" \
                --argjson tls "$tls_obj" \
                --argjson tr "$transport_obj" \
                --argjson fl "$flow_part" \
                '{"type":"vless","tag":$t,"server":$s,"server_port":($p|tonumber),
                  "uuid":$uuid,"tls":$tls}
                 + (if $tr != {} then {"transport":$tr} else {} end)
                 + $fl')
            ;;
        5) # Trojan
            local tls_obj
            tls_obj=$(jq -n \
                --arg sni "$R_SNI" --argjson ins "$([ "$R_TLS_INSECURE" = "1" ] && echo true || echo false)" \
                '{"enabled":true,"server_name":$sni,"insecure":$ins}')
            local transport_obj="{}"
            if [[ "$R_TRANSPORT" == "ws" ]]; then
                transport_obj=$(jq -n --arg p "$R_WS_PATH" '{"type":"ws","path":$p}')
            fi
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg pw "$R_PASS" \
                --argjson tls "$tls_obj" \
                --argjson tr "$transport_obj" \
                '{"type":"trojan","tag":$t,"server":$s,"server_port":($p|tonumber),
                  "password":$pw,"tls":$tls}
                 + (if $tr != {} then {"transport":$tr} else {} end)')
            ;;
        6) # Hysteria2
            local tls_obj
            tls_obj=$(jq -n \
                --arg sni "$R_SNI" --argjson ins "$([ "$R_TLS_INSECURE" = "1" ] && echo true || echo false)" \
                '{"enabled":true,"server_name":$sni,"insecure":$ins}')
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg pw "$R_PASS" --argjson tls "$tls_obj" \
                '{"type":"hysteria2","tag":$t,"server":$s,"server_port":($p|tonumber),
                  "password":$pw,"tls":$tls}')
            ;;
        7) # TUIC
            local alpn_json="[]"
            [[ -n "$R_ALPN" ]] && alpn_json=$(echo "$R_ALPN" | tr ',' '\n' | jq -R . | jq -s .)
            local tls_obj
            tls_obj=$(jq -n \
                --arg sni "$R_SNI" \
                --argjson alpn "$alpn_json" \
                --argjson ins "$([ "$R_TLS_INSECURE" = "1" ] && echo true || echo false)" \
                '{"enabled":true,"server_name":$sni,"insecure":$ins,"alpn":$alpn}')
            json=$(jq -n \
                --arg t "$tag" --arg s "$R_ADDR" --arg p "$R_PORT" \
                --arg uuid "$R_UUID" --arg pw "$R_PASS" \
                --argjson tls "$tls_obj" \
                '{"type":"tuic","tag":$t,"server":$s,"server_port":($p|tonumber),
                  "uuid":$uuid,"password":$pw,"congestion_control":"bbr","tls":$tls}')
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
    echo "$json"
}

manage_routing() {
    local rt_choice IN_TAGS OUT_TAG OUT_JSON RULE_JSON
    local idx LOCAL_TAG RAW_LINK R_ADDR R_PORT R_METHOD R_PASS R_USER
    local hop_type SKIP_TLS CURRENT_OUTBOUND NEW_RULE_JSON
    
    while true; do
        clear
        echo -e "${YELLOW}================================================${PLAIN}"
        echo -e "${YELLOW}         路由分流与链式代理管理         ${PLAIN}"
        echo -e "${YELLOW}================================================${PLAIN}"
        echo -e "${CYAN}--- 常规网站分流 ---${PLAIN}"
        echo " 1. 添加分流规则(入站➡️跳板➡️分流 先加跳转节点)"
        echo " 2. 查看当前分流规则"
        echo " 3. 删除特定分流规则"
        echo -e "\n${CYAN}--- 链式代理与跳板 ---${PLAIN}"
        echo " 4. 添加跳转节点 (可配合分流使用)"
        echo " 5. 查看当前活跃链式链路"
        echo " 6. 重置入站规则 (取消链式，恢复直连)"
        echo "------------------------------------------------"
        echo " 0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " rt_choice

        case $rt_choice in
            1)
                echo -e "\n${CYAN}1. 请选择来源入站:${PLAIN}"
                local in_count=$(jq '.inbounds | length' "$CONFIG_FILE")
                [[ "$in_count" -eq 0 ]] && echo -e "${RED}无入站配置${PLAIN}" && pause && continue
                
                jq -r '.inbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                read -p "选择序号 (逗号隔开, 回车代表全部): " in_idxs
                if [[ -z "$in_idxs" ]]; then 
                    IN_TAGS="null"
                else
                    # [修复2] 验证每个分割出的序号
                    local invalid=0
                    while IFS= read -r i; do
                        if ! validate_index "$i" "$in_count" 2>/dev/null; then invalid=1; fi
                    done < <(echo "$in_idxs" | tr ',' '\n')
                    [[ "$invalid" -eq 1 ]] && pause && continue
                    IN_TAGS=$(echo "$in_idxs" | tr ',' '\n' | while read -r i; do jq -r ".inbounds[$((i-1))].tag" "$CONFIG_FILE"; done | jq -R . | jq -s . -c)
                fi

                echo -e "\n${CYAN}2. 请选择匹配的目标:${PLAIN}"
                echo "1) 全部流量 | 2) 域名匹配 | 3) GeoSite | 4) IP/CIDR"
                read -p "选择 [1-4]: " target_type
                local RULE_PART="{}"
                case $target_type in
                    2) read -p "域名: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"domain": .}' -c) ;;
                    3) read -p "GeoSite: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"geosite": .}' -c) ;;
                    4) read -p "IP/CIDR: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"ip_cidr": .}' -c) ;;
                esac

                echo -e "\n${CYAN}3. 请配置目标出站:${PLAIN}"
                echo "1) 粘贴链接 | 2) 手动输入 | 3) 自动优选 | 4) 轮询分流"
                read -p "选择 [1-4]: " out_mode
                 
                OUT_TAG="route-out-$(date +%s)"
                OUT_JSON=""

                if [[ "$out_mode" == "1" ]]; then
                    R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; 
                    read -p "输入链接: " RAW_LINK; parse_proxy_link "$RAW_LINK"
                    [[ -z "$R_ADDR" ]] && echo -e "${RED}解析失败${PLAIN}" && pause && continue
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" \
                        '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}')
                elif [[ "$out_mode" == "2" ]]; then
                    echo -e "1) SS | 2) Socks5 | 3) HTTP/HTTPS"
                    read -p "协议: " h_type
                    read -p "地址: " R_ADDR
                    read -p "端口: " R_PORT
                    case $h_type in
                        1) read -p "加密: " R_METHOD; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}') ;;
                        2) read -p "用户: " R_USER; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"} + (if $u != "" then {"username":$u,"password":$pass} else {} end)') ;;
                        3) 
                           read -p "用户: " R_USER; read -p "密码: " R_PASS;
                           read -p "是否跳过证书验证 (Insecure)? [y/N]: " SKIP_TLS
                           SKIP_TLS=${SKIP_TLS:-n}
                           OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" --arg skip "$SKIP_TLS" '{"type":"http","tag":$t,"server":$s,"server_port":($p|tonumber),"tls":{"enabled":true, "insecure": ($skip == "y" or $skip == "Y")}} + (if $u != "" then {"username":$u,"password":$pass} else {} end)') ;;
                    esac
                elif [[ "$out_mode" == "3" || "$out_mode" == "4" ]]; then
                    echo -e "\n${YELLOW}选择代理成员 (多选用逗号):${PLAIN}"
                    jq -r '.outbounds | keys[] as $i | select(.[$i].type != "direct" and .[$i].type != "dns" and .[$i].type != "block") | "\($i+1)) [\(.[$i].type)] \(.[$i].tag)"' "$CONFIG_FILE"
                    read -p "序号: " m_idxs
                    [[ -z "$m_idxs" ]] && continue
                    MEMBER_TAGS=$(echo "$m_idxs" | tr ',' '\n' | while read -r i; do jq -r ".outbounds[$((i-1))].tag" "$CONFIG_FILE"; done | jq -R . | jq -s . -c)
                    OUT_TAG="group-out-$(date +%s)"
                    if [[ "$out_mode" == "3" ]]; then
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" '{"type":"urltest","tag":$t,"outbounds":$m,"url":"https://www.gstatic.com/generate_204","interval":"3m0s"}')
                    else
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" '{"type":"selector","tag":$t,"outbounds":$m}')
                    fi
                fi

                RULE_JSON=$(echo "$RULE_PART" | jq --arg ot "$OUT_TAG" --argjson it "$IN_TAGS" '. + {"outbound": $ot} + (if $it != null then {"inbound": $it} else {} end)' -c)
                
                make_tmp
                jq --argjson out_obj "$OUT_JSON" --argjson rule_obj "$RULE_JSON" \
                   '.outbounds += [$out_obj] | .route.rules = [$rule_obj] + .route.rules' "$CONFIG_FILE" > "$_TMP_JSON"
                
                if save_and_restart; then
                    echo -e "${GREEN}✔ 添加成功，配置已生效！${PLAIN}"
                else
                    echo -e "${RED}✖ 配置语法检查失败！${PLAIN}"
                fi
                pause ;;
                
            2)
                echo -e "\n${CYAN}当前分流规则:${PLAIN}"
                jq -r '.route.rules | keys[] as $i | "\($i+1)) [\(.[$i].inbound // "全部")] -> [\(.[$i].outbound)]"' "$CONFIG_FILE"
                pause ;;
                
            3)
                echo -e "\n${YELLOW}删除分流规则序号 (all 代表全部):${PLAIN}"
                jq -r '.route.rules | keys[] as $i | "\($i+1)) \(.[$i].outbound)"' "$CONFIG_FILE"
                read -p "> " d_choice
                make_tmp
                if [[ "$d_choice" == "all" ]]; then
                    jq '.route.rules = [] | .outbounds |= map(select(.tag | (startswith("route-out-") or startswith("group-out-")) | not))' "$CONFIG_FILE" > "$_TMP_JSON"
                else
                    local rule_count=$(jq '.route.rules | length' "$CONFIG_FILE")
                    local j_idxs=$(echo "$d_choice" | tr ',' '\n' | awk '{print $1-1}' | jq -R . | jq -s . -c)
                    jq --argjson idxs "$j_idxs" 'del(.route.rules[$idxs[]])' "$CONFIG_FILE" > /tmp/sb_del_s.json
                    jq '.outbounds |= map(select(((.tag | (startswith("route-out-") or startswith("group-out-"))) | not) or (.tag as $t | any(.route.rules[]; .outbound == $t))))' /tmp/sb_del_s.json > "$_TMP_JSON"
                    rm -f /tmp/sb_del_s.json
                fi
                
                if save_and_restart; then
                    echo -e "${GREEN}✔ 已更新${PLAIN}"
                else
                    echo -e "${RED}✖ 语法检查失败！${PLAIN}"
                fi
                pause ;;

            4)
                # =====================================================
                # 链式代理 — 正确的多跳模型
                #
                # sing-box detour 规则：
                #   每个节点的 detour 指向「下一跳」tag
                #   最后一跳（落地）无 detour，直接出互联网
                #
                # 结构示例（3跳）:
                #   路由规则: 入站 → hop1
                #   hop1 { detour: hop2 }
                #   hop2 { detour: land-group }
                #   land-group { urltest/selector, 成员无 detour }
                #
                # 本脚本流程:
                #   [步骤1] 选入站
                #   [步骤2] 配置落地（最后一跳）— 单节点/自动优选/轮询
                #   [步骤3] 逐跳添加中间跳板（可循环添加多个）
                #   [步骤4] 写入配置
                # =====================================================
                clear
                echo -e "${YELLOW}━━━ 链式代理配置 ━━━${PLAIN}"
                echo -e "${CYAN}正确架构: 入站 ──▶ 跳板1 ──▶ [跳板2...] ──▶ 落地组 ──▶ 互联网"
                echo -e "每跳 detour 指向下一跳，最后一跳（落地）无 detour${PLAIN}\n"

                # ── 步骤 1：选择入站 ─────────────────────────────────
                echo -e "${YELLOW}[步骤1] 选择流量来源入站:${PLAIN}"
                local in_count=$(jq '.inbounds | length' "$CONFIG_FILE")
                [[ "$in_count" -eq 0 ]] && echo -e "${RED}无入站配置${PLAIN}" && pause && continue
                jq -r '.inbounds | keys[] as $i |
                    "  \($i+1)) \(.[$i].tag)  [\(.[$i].type):\(.[$i].listen_port)]"' "$CONFIG_FILE"
                read -p "选择序号: " idx
                [[ -z "$idx" ]] && continue
                if ! validate_index "$idx" "$in_count"; then pause; continue; fi
                LOCAL_TAG=$(jq -r ".inbounds[$((idx-1))].tag" "$CONFIG_FILE")
                echo -e "  ✔ 入站: ${GREEN}$LOCAL_TAG${PLAIN}\n"

                # ── 步骤 2：配置落地（最后一跳）────────────────────────
                # 落地节点不带 detour，直接出互联网
                # 支持：单节点 / urltest自动优选 / selector轮询
                echo -e "${YELLOW}[步骤2] 配置落地节点（最后出口，无 detour）:${PLAIN}"

                # 辅助：列出基础出站（排除 direct/dns/block/urltest/selector）
                _list_base_outbounds() {
                    jq -r '[.outbounds[] | select(
                        .type != "direct" and .type != "dns" and
                        .type != "block" and .type != "urltest" and .type != "selector"
                    )] | keys[] as $i |
                    "  \($i+1)) [\(.[$i].type)] \(.[$i].tag)  \(.[$i].server // ""):\(.[$i].server_port // "")"' "$CONFIG_FILE"
                }
                _count_base_outbounds() {
                    jq '[.outbounds[] | select(
                        .type != "direct" and .type != "dns" and
                        .type != "block" and .type != "urltest" and .type != "selector"
                    )] | length' "$CONFIG_FILE"
                }
                _get_base_outbound_tag() {
                    jq -r "[.outbounds[] | select(
                        .type != \"direct\" and .type != \"dns\" and
                        .type != \"block\" and .type != \"urltest\" and .type != \"selector\"
                    )] | .[$(($1-1))].tag" "$CONFIG_FILE"
                }

                local base_out_count
                base_out_count=$(_count_base_outbounds)
                if [[ "$base_out_count" -eq 0 ]]; then
                    echo -e "${RED}✘ 无可用出站节点，请先在「添加出站节点」中导入${PLAIN}"
                    pause; continue
                fi
                _list_base_outbounds

                echo -e "\n  落地模式:"
                echo "  A) 单节点  — 选 1 个，固定落地"
                echo "  B) 自动优选 — 选多个，urltest 自动选最低延迟"
                echo "  C) 轮询    — 选多个，selector 手动/负载切换"
                read -p "  模式 [A/B/C]: " land_mode
                land_mode=$(echo "$land_mode" | tr 'abc' 'ABC')

                # LAND_FINAL_TAG : 落地的最终 tag（上一跳的 detour 指向它）
                # LAND_NEW_JSON  : 若需新建组节点，此处存 JSON；单节点模式为空
                local LAND_FINAL_TAG="" LAND_NEW_JSON=""
                local member_tags_arr=()

                if [[ "$land_mode" == "A" ]]; then
                    read -p "  选择序号: " l_idx
                    if ! validate_index "$l_idx" "$base_out_count"; then pause; continue; fi
                    LAND_FINAL_TAG=$(_get_base_outbound_tag "$l_idx")
                    echo -e "  ✔ 落地: ${GREEN}$LAND_FINAL_TAG${PLAIN}"

                elif [[ "$land_mode" == "B" || "$land_mode" == "C" ]]; then
                    read -p "  选择序号 (逗号隔开): " m_idxs
                    [[ -z "$m_idxs" ]] && continue
                    local bad=0
                    while IFS= read -r mi; do
                        mi=$(echo "$mi" | tr -d ' ')
                        if ! validate_index "$mi" "$base_out_count" 2>/dev/null; then
                            echo -e "${RED}  序号 $mi 无效${PLAIN}"; bad=1; break
                        fi
                        member_tags_arr+=( "$(_get_base_outbound_tag "$mi")" )
                    done < <(echo "$m_idxs" | tr ',' '\n')
                    [[ "$bad" -eq 1 ]] && pause && continue
                    if [[ ${#member_tags_arr[@]} -lt 2 ]]; then
                        echo -e "${RED}  至少选 2 个节点${PLAIN}"; pause; continue
                    fi
                    local MEMBER_JSON
                    MEMBER_JSON=$(printf '%s\n' "${member_tags_arr[@]}" | jq -R . | jq -s .)
                    LAND_FINAL_TAG="land-$(date +%s)"

                    if [[ "$land_mode" == "B" ]]; then
                        read -p "  测速 URL (回车默认): " test_url
                        test_url=${test_url:-"https://www.gstatic.com/generate_204"}
                        read -p "  测速间隔 (回车默认 3m): " test_iv
                        test_iv=${test_iv:-"3m0s"}
                        read -p "  容差 ms (回车默认 50): " tol
                        tol=${tol:-50}
                        # 确保 tolerance 是纯数字
                        [[ ! "$tol" =~ ^[0-9]+$ ]] && tol=50
                        LAND_NEW_JSON=$(jq -n \
                            --arg t "$LAND_FINAL_TAG" --argjson m "$MEMBER_JSON" \
                            --arg url "$test_url" --arg iv "$test_iv" --argjson tol "$tol" \
                            '{"type":"urltest","tag":$t,"outbounds":$m,
                              "url":$url,"interval":$iv,"tolerance":$tol}')
                        echo -e "  ✔ 自动优选组: ${GREEN}$LAND_FINAL_TAG${PLAIN} (${#member_tags_arr[@]} 节点)"
                    else
                        LAND_NEW_JSON=$(jq -n \
                            --arg t "$LAND_FINAL_TAG" --argjson m "$MEMBER_JSON" \
                            '{"type":"selector","tag":$t,"outbounds":$m,"default":($m[0])}')
                        echo -e "  ✔ 轮询选择组: ${GREEN}$LAND_FINAL_TAG${PLAIN} (${#member_tags_arr[@]} 节点)"
                    fi
                else
                    echo -e "${RED}无效输入${PLAIN}"; pause; continue
                fi

                # ── 步骤 3：逐跳添加中间跳板 ────────────────────────
                # 每跳 detour 指向下一跳；第一个添加的跳板 detour 指向 LAND_FINAL_TAG
                # 用户可以反复添加，最后添加的是第一跳（路由规则指向它）
                #
                # 内部用 chain_tags 数组存跳板顺序（倒序），写入时正序链接
                # chain_tags[0] = 最后添加的跳板（第一跳）
                # chain_tags[-1]= 最先添加的跳板（倒数第二跳，detour→落地）
                echo -e "\n${YELLOW}[步骤3] 配置跳板节点（从最靠近落地的一跳开始添加）:${PLAIN}"
                echo -e "  ${CYAN}提示: 先加离落地最近的一跳，最后加离入站最近的一跳${PLAIN}"
                echo -e "  ${CYAN}例如三跳: 先加跳板2，再加跳板1${PLAIN}\n"

                # 存所有跳板 JSON 和 tag（按添加顺序，即从靠近落地→靠近入站）
                local hop_tags=()       # 所有跳板 tag（按添加顺序）
                local hop_jsons=()      # 对应 JSON（空字符串=已有节点）
                # 第一个跳板的 next_tag 是落地组
                local next_tag="$LAND_FINAL_TAG"

                while true; do
                    local hop_num=$(( ${#hop_tags[@]} + 1 ))
                    echo -e "  ${YELLOW}── 跳板 #$hop_num (detour → ${next_tag}) ──${PLAIN}"
                    echo "  1) 粘贴链接"
                    echo "  2) 从已有出站选择"
                    echo "  3) 手动输入"
                    echo "  0) 完成，不再添加跳板"
                    read -p "  选择: " hop_src

                    [[ "$hop_src" == "0" ]] && break

                    local CUR_HOP_TAG="" CUR_HOP_JSON=""

                    if [[ "$hop_src" == "1" ]]; then
                        read -p "  链接: " RAW_LINK
                        parse_proxy_link "$RAW_LINK"
                        if [[ -z "$R_ADDR" ]]; then
                            echo -e "${RED}  解析失败，请重试${PLAIN}"; continue
                        fi
                        local ns=$(echo "$R_NAME" | tr ' ' '_' | tr -dc 'a-zA-Z0-9._-')
                        CUR_HOP_TAG="hop${hop_num}-${ns:-$(date +%s)}"
                        # 解析完立刻加上 detour 指向下一跳
                        CUR_HOP_JSON=$(link_to_outbound_json "$CUR_HOP_TAG" | \
                            jq --arg d "$next_tag" '. + {"detour":$d}')

                    elif [[ "$hop_src" == "2" ]]; then
                        echo -e "  可用出站:"
                        local ao_count
                        ao_count=$(jq '[.outbounds[] | select(.type != "direct" and .type != "dns" and .type != "block")] | length' "$CONFIG_FILE")
                        jq -r '[.outbounds[] | select(.type != "direct" and .type != "dns" and .type != "block")] |
                            keys[] as $i | "  \($i+1)) [\(.[$i].type)] \(.[$i].tag)  detour=\(.[$i].detour // "无")"' "$CONFIG_FILE"
                        read -p "  序号: " h_idx
                        if ! validate_index "$h_idx" "$ao_count"; then continue; fi
                        CUR_HOP_TAG=$(jq -r "[.outbounds[] | select(.type != \"direct\" and .type != \"dns\" and .type != \"block\")] | .[$(($h_idx-1))].tag" "$CONFIG_FILE")
                        # 标记为已有节点，JSON 为空，写入时就地更新 detour
                        CUR_HOP_JSON=""

                    elif [[ "$hop_src" == "3" ]]; then
                        echo "  1) SS  2) Socks5  3) HTTPS"
                        read -p "  协议: " hop_type
                        read -p "  地址: " R_ADDR; read -p "  端口: " R_PORT
                        CUR_HOP_TAG="hop${hop_num}-$(date +%s)"
                        case $hop_type in
                            1) read -p "  加密: " R_METHOD; read -p "  密码: " R_PASS ;;
                            2) read -p "  用户: " R_USER;   read -p "  密码: " R_PASS ;;
                            3) read -p "  用户: " R_USER;   read -p "  密码: " R_PASS ;;
                            *) echo -e "${RED}无效${PLAIN}"; continue ;;
                        esac
                        CUR_HOP_JSON=$(link_to_outbound_json "$CUR_HOP_TAG" | \
                            jq --arg d "$next_tag" '. + {"detour":$d}')
                    else
                        echo -e "${RED}无效输入${PLAIN}"; continue
                    fi

                    [[ -z "$CUR_HOP_TAG" ]] && continue

                    hop_tags+=("$CUR_HOP_TAG")
                    hop_jsons+=("$CUR_HOP_JSON")
                    next_tag="$CUR_HOP_TAG"   # 下一个跳板的 next 指向当前跳板
                    echo -e "  ✔ 跳板 #$hop_num: ${GREEN}$CUR_HOP_TAG${PLAIN} ──▶ detour → ${YELLOW}$([ "${#hop_tags[@]}" -eq 1 ] && echo "$LAND_FINAL_TAG" || echo "${hop_tags[-2]}")${PLAIN}"
                    echo ""
                done

                if [[ ${#hop_tags[@]} -eq 0 ]]; then
                    echo -e "${RED}✘ 至少需要一个跳板节点${PLAIN}"; pause; continue
                fi

                # hop_tags 最后一个是第一跳（路由规则指向它）
                local FIRST_HOP_TAG="${hop_tags[-1]}"

                # ── 步骤 4：写入配置 ─────────────────────────────────
                echo -e "\n${YELLOW}[步骤4] 写入配置...${PLAIN}"

                # 打印最终链路预览
                echo -ne "  链路预览: ${BLUE}$LOCAL_TAG${PLAIN}"
                # 倒序输出跳板（从入站近→落地近）
                for (( i=${#hop_tags[@]}-1; i>=0; i-- )); do
                    echo -ne " ──▶ ${GREEN}${hop_tags[$i]}${PLAIN}"
                done
                echo -e " ──▶ ${YELLOW}$LAND_FINAL_TAG${PLAIN} ──▶ 互联网"

                # 路由规则：入站 → 第一跳
                NEW_RULE_JSON=$(jq -n \
                    --arg itag "$LOCAL_TAG" --arg otag "$FIRST_HOP_TAG" \
                    '{"inbound":[$itag],"outbound":$otag}')

                make_tmp
                # 用 python3 把 bash 数组转成 jq 输入，避免长串参数
                # 思路：
                #   1. 先追加落地组（如果是新组）
                #   2. 逐跳：新节点追加；已有节点就地设 detour
                #   3. 更新路由规则
                local TMP_CFG="$_TMP_JSON"
                cp "$CONFIG_FILE" "$TMP_CFG"

                # 追加落地组
                if [[ -n "$LAND_NEW_JSON" ]]; then
                    jq --argjson obj "$LAND_NEW_JSON" '.outbounds += [$obj]' \
                        "$TMP_CFG" > "${TMP_CFG}.tmp" && mv "${TMP_CFG}.tmp" "$TMP_CFG"
                fi

                # 逐跳写入（按数组顺序：靠近落地→靠近入站）
                for (( i=0; i<${#hop_tags[@]}; i++ )); do
                    local htag="${hop_tags[$i]}"
                    local hjson="${hop_jsons[$i]}"
                    # next detour：i=0 指向落地，i>0 指向 hop_tags[i-1]
                    local hdetour
                    if [[ $i -eq 0 ]]; then
                        hdetour="$LAND_FINAL_TAG"
                    else
                        hdetour="${hop_tags[$((i-1))]}"
                    fi

                    if [[ -n "$hjson" ]]; then
                        # 新节点（JSON 里已含 detour），直接追加
                        jq --argjson obj "$hjson" '.outbounds += [$obj]' \
                            "$TMP_CFG" > "${TMP_CFG}.tmp" && mv "${TMP_CFG}.tmp" "$TMP_CFG"
                    else
                        # 已有节点：就地覆写 detour，防止保留旧 detour 造成环路
                        jq --arg tag "$htag" --arg det "$hdetour" \
                            '(.outbounds[] | select(.tag == $tag)) |= (. + {"detour":$det})' \
                            "$TMP_CFG" > "${TMP_CFG}.tmp" && mv "${TMP_CFG}.tmp" "$TMP_CFG"
                    fi
                done

                # 更新路由规则（替换该入站旧规则）
                jq --argjson rule "$NEW_RULE_JSON" --arg itag "$LOCAL_TAG" \
                    '.route.rules = (
                        [$rule] + [.route.rules[] | select(
                            if .inbound then
                                if (.inbound | type) == "array"
                                then (.inbound | contains([$itag])) | not
                                else .inbound != $itag end
                            else true end
                        )]
                    )' "$TMP_CFG" > "${TMP_CFG}.tmp" && mv "${TMP_CFG}.tmp" "$TMP_CFG"

                if $SB_BIN check -c "$TMP_CFG" > /dev/null 2>&1; then
                    mv "$TMP_CFG" "$CONFIG_FILE"
                    _TMP_JSON=""
                    systemctl restart sing-box
                    echo -e "\n${GREEN}✔ 链式配置成功，共 ${#hop_tags[@]} 跳！${PLAIN}"
                    if [[ "$land_mode" == "B" ]]; then
                        echo -e "  落地模式: ${CYAN}自动优选 (${#member_tags_arr[@]} 节点)${PLAIN}"
                    elif [[ "$land_mode" == "C" ]]; then
                        echo -e "  落地模式: ${CYAN}轮询选择 (${#member_tags_arr[@]} 节点)${PLAIN}"
                    fi
                else
                    echo -e "${RED}✖ 配置校验失败，已回滚${PLAIN}"
                    echo -e "${YELLOW}详细错误:${PLAIN}"
                    $SB_BIN check -c "$TMP_CFG" 2>&1 | head -20
                    rm -f "$TMP_CFG" "${TMP_CFG}.tmp"
                    _TMP_JSON=""
                fi
                pause ;;

            5)
                # 增强版链路可视化：追踪 detour 链，展示完整路径
                clear
                echo -e "${YELLOW}━━━ 当前链式链路 ━━━${PLAIN}\n"

                local rules_count
                rules_count=$(jq '[.route.rules[] | select(.inbound != null)] | length' "$CONFIG_FILE")
                if [[ "$rules_count" -eq 0 ]]; then
                    echo -e "  暂无链式规则"
                    pause; continue
                fi

                # 对每条有入站的路由规则，追踪完整 detour 链
                jq -r '.route.rules[] | select(.inbound != null) |
                    "\(.inbound | if type=="array" then join(",") else . end)|\(.outbound)"' \
                    "$CONFIG_FILE" | while IFS='|' read -r inbound first_out; do

                    echo -e "  ${BLUE}入站: $inbound${PLAIN}"
                    echo -ne "  路径: ${GREEN}$first_out${PLAIN}"

                    local cur="$first_out"
                    local visited="$first_out"
                    local depth=0

                    while true; do
                        (( depth++ ))
                        [[ $depth -gt 20 ]] && echo -ne " ${RED}[检测到可能的循环!]${PLAIN}" && break

                        local next
                        next=$(jq -r --arg t "$cur" \
                            '.outbounds[] | select(.tag == $t) | .detour // ""' \
                            "$CONFIG_FILE" 2>/dev/null | head -1)

                        [[ -z "$next" ]] && break

                        # 检测循环
                        if echo "$visited" | grep -qF "$next"; then
                            echo -ne " ──▶ ${RED}[$next ← 循环!]${PLAIN}"
                            break
                        fi
                        visited="$visited $next"

                        # 判断节点类型显示不同颜色
                        local node_type
                        node_type=$(jq -r --arg t "$next" \
                            '.outbounds[] | select(.tag == $t) | .type' \
                            "$CONFIG_FILE" 2>/dev/null | head -1)

                        case "$node_type" in
                            urltest)  echo -ne " ──▶ ${CYAN}$next[优选组]${PLAIN}" ;;
                            selector) echo -ne " ──▶ ${PURPLE}$next[轮询组]${PLAIN}" ;;
                            "")       echo -ne " ──▶ ${YELLOW}互联网${PLAIN}" ;;
                            *)        echo -ne " ──▶ ${GREEN}$next${PLAIN}" ;;
                        esac
                        cur="$next"
                    done

                    # 展开组成员
                    local members
                    members=$(jq -r --arg t "$cur" \
                        '.outbounds[] | select(.tag == $t) | .outbounds // [] | join(", ")' \
                        "$CONFIG_FILE" 2>/dev/null | head -1)
                    [[ -n "$members" ]] && echo -ne "\n  成员: ${YELLOW}$members${PLAIN}"

                    echo -e "\n"
                done
                pause ;;

            6)
                echo -e "\n${YELLOW}选择要重置为直连的入站:${PLAIN}"
                local in_tags=$(jq -r '.route.rules[] | select(.inbound != null) | .inbound | if type == "array" then .[0] else . end' "$CONFIG_FILE")
                echo "$in_tags" | cat -n
                read -p "选择序号: " del_idx
                local DEL_IN_TAG=$(echo "$in_tags" | sed -n "${del_idx}p")

                if [[ -n "$DEL_IN_TAG" ]]; then
                    jq --arg itag "$DEL_IN_TAG" '
                        .route.rules |= map(if (if .inbound | type == "array" then .inbound | contains([$itag]) else .inbound == $itag end) then .outbound = "direct" else . end)
                    ' "$CONFIG_FILE" > /tmp/sb_reset.json && mv /tmp/sb_reset.json "$CONFIG_FILE"
                    systemctl restart sing-box
                    echo -e "${GREEN}✔ 入站 [$DEL_IN_TAG] 已恢复直连。${PLAIN}"
                fi
                pause ;;

            0) 
                return 0 ;;
        esac
    done
}

add_outbound() {
    local node_type RAW_LINK OUT_TAG OUT_JSON

    # 内部函数：把一条已解析的链接写入配置，返回 0=成功
    _write_one_node() {
        local tag=$1
        local json=$2
        [[ -z "$json" ]] && return 1
        make_tmp
        jq --argjson obj "$json" '.outbounds += [$obj]' "$CONFIG_FILE" > "$_TMP_JSON"
        if save_and_restart; then
            echo -e "${GREEN}  ✔ [$tag] 写入成功${PLAIN}"
            return 0
        else
            echo -e "${RED}  ✖ [$tag] 语法校验失败，已跳过${PLAIN}"
            return 1
        fi
    }

    while true; do
        clear
        echo -e "${YELLOW}--- 添加出站节点 ---${PLAIN}"
        echo "1. 粘贴单条链接 (SS/Socks5/HTTPS/VLESS/Trojan/Hysteria2/TUIC)"
        echo "2. 手动输入配置 (SS / Socks5 / HTTPS)"
        echo "3. 订阅导入 (URL 或本地文件，批量解析)"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择 [0-3]: " node_type

        [[ "$node_type" == "0" ]] && break

        # ============================================================
        #  选项 1：单条链接解析
        # ============================================================
        if [[ "$node_type" == "1" ]]; then
            read -p "请输入节点链接: " RAW_LINK
            parse_proxy_link "$RAW_LINK"
            if [[ -z "$R_ADDR" ]]; then
                echo -e "${RED}✘ 链接解析失败，请检查格式！${PLAIN}"
                pause; continue
            fi
            # 用备注作 tag，备注为空则时间戳兜底
            local name_safe=$(echo "$R_NAME" | tr ' ' '_' | tr -dc 'a-zA-Z0-9._-')
            OUT_TAG="${name_safe:-hop-$(date +%s)}"
            OUT_JSON=$(link_to_outbound_json "$OUT_TAG")
            if [[ -z "$OUT_JSON" ]]; then
                echo -e "${RED}✘ 不支持的协议 (hop_type=$hop_type)${PLAIN}"
                pause; continue
            fi
            _write_one_node "$OUT_TAG" "$OUT_JSON"

        # ============================================================
        #  选项 2：手动输入
        # ============================================================
        elif [[ "$node_type" == "2" ]]; then
            echo -e "\n请选择协议: 1) SS  2) Socks5  3) HTTPS"
            read -p "选择: " proto_choice
            read -p "地址 (Domain/IP): " R_ADDR
            read -p "端口 (Port): " R_PORT
            OUT_TAG="hop-$(date +%s)"
            case $proto_choice in
                1)
                    read -p "加密方式 (如 aes-256-gcm): " R_METHOD
                    read -p "密码: " R_PASS
                    hop_type=1
                    OUT_JSON=$(link_to_outbound_json "$OUT_TAG")
                    ;;
                2)
                    read -p "用户名 (可选): " R_USER
                    read -p "密码 (可选): " R_PASS
                    hop_type=2
                    OUT_JSON=$(link_to_outbound_json "$OUT_TAG")
                    ;;
                3)
                    read -p "用户名 (可选): " R_USER
                    read -p "密码 (可选): " R_PASS
                    hop_type=3
                    OUT_JSON=$(link_to_outbound_json "$OUT_TAG")
                    ;;
                *) echo -e "${RED}非法输入${PLAIN}"; continue ;;
            esac
            _write_one_node "$OUT_TAG" "$OUT_JSON"

        # ============================================================
        #  选项 3：订阅导入
        # ============================================================
        elif [[ "$node_type" == "3" ]]; then
            clear
            echo -e "${YELLOW}--- 订阅导入 ---${PLAIN}"
            echo "1. 从 URL 拉取订阅"
            echo "2. 从本地文件导入"
            echo "0. 返回"
            read -p "请选择: " sub_mode
            [[ "$sub_mode" == "0" ]] && continue

            local raw_content=""

            if [[ "$sub_mode" == "1" ]]; then
                read -p "请输入订阅 URL: " SUB_URL
                [[ -z "$SUB_URL" ]] && continue
                echo -e "${CYAN}正在拉取订阅...${PLAIN}"
                raw_content=$(curl -sL --connect-timeout 10 --max-time 30 "$SUB_URL")
                if [[ -z "$raw_content" ]]; then
                    echo -e "${RED}✘ 拉取失败，请检查 URL 或网络连通性${PLAIN}"
                    pause; continue
                fi
            elif [[ "$sub_mode" == "2" ]]; then
                read -p "请输入本地文件路径: " SUB_FILE
                if [[ ! -f "$SUB_FILE" ]]; then
                    echo -e "${RED}✘ 文件不存在: $SUB_FILE${PLAIN}"
                    pause; continue
                fi
                raw_content=$(cat "$SUB_FILE")
            else
                continue
            fi

            # ---- 解码：判断内容是纯 Base64 还是明文链接列表 ----
            local link_list=""

            # 尝试 Base64 解码（订阅通常是 Base64 包裹的多行链接）
            local decoded
            decoded=$(echo "$raw_content" | tr -d '\r\n ' | \
                base64 -d 2>/dev/null)

            if echo "$decoded" | grep -qE '^(ss|socks5?|https|vless|trojan|hysteria2|hy2|tuic)://'; then
                # Base64 解码成功且含合法链接
                link_list="$decoded"
                echo -e "${CYAN}检测到 Base64 编码订阅，已解码${PLAIN}"
            elif echo "$raw_content" | grep -qE '^(ss|socks5?|https|vless|trojan|hysteria2|hy2|tuic)://'; then
                # 明文链接列表
                link_list="$raw_content"
                echo -e "${CYAN}检测到明文链接订阅${PLAIN}"
            else
                echo -e "${RED}✘ 无法识别订阅格式（既非 Base64 也非明文链接）${PLAIN}"
                pause; continue
            fi

            # ---- 逐行解析写入 ----
            local total=0 ok=0 fail=0
            while IFS= read -r line; do
                # 跳过空行和注释行
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                # 只处理已知协议前缀的行
                [[ ! "$line" =~ ^(ss|socks5?|https|vless|trojan|hysteria2|hy2|tuic):// ]] && continue
                ((total++))

                parse_proxy_link "$line"
                if [[ -z "$R_ADDR" ]]; then
                    echo -e "${RED}  [${total}] 解析失败: ${line:0:60}...${PLAIN}"
                    ((fail++)); continue
                fi

                # 生成不重复的 tag
                local name_safe=$(echo "$R_NAME" | tr ' ' '_' | tr -dc 'a-zA-Z0-9._-')
                local base_tag="${name_safe:-sub-${total}}"
                # 防止 tag 重名：如已存在则追加序号
                local final_tag="$base_tag"
                local dup=1
                while jq -e --arg t "$final_tag" '.outbounds[] | select(.tag == $t)' "$CONFIG_FILE" > /dev/null 2>&1; do
                    final_tag="${base_tag}-${dup}"; ((dup++))
                done

                local node_json
                node_json=$(link_to_outbound_json "$final_tag")
                if [[ -z "$node_json" ]]; then
                    echo -e "${YELLOW}  [${total}] 不支持协议(hop_type=$hop_type)，跳过: $R_ADDR${PLAIN}"
                    ((fail++)); continue
                fi

                # 批量写入：不重启，先累积到临时文件
                make_tmp
                jq --argjson obj "$node_json" '.outbounds += [$obj]' "$CONFIG_FILE" > "$_TMP_JSON"
                if $SB_BIN check -c "$_TMP_JSON" > /dev/null 2>&1; then
                    mv "$_TMP_JSON" "$CONFIG_FILE"
                    _TMP_JSON=""
                    echo -e "${GREEN}  [${total}] ✔ $final_tag ($R_ADDR:$R_PORT)${PLAIN}"
                    ((ok++))
                else
                    rm -f "$_TMP_JSON"; _TMP_JSON=""
                    echo -e "${RED}  [${total}] ✖ 校验失败，跳过: $R_ADDR${PLAIN}"
                    ((fail++))
                fi
            done <<< "$link_list"

            # ---- 全部写完后统一重启一次 ----
            echo -e "\n${YELLOW}共解析 $total 条，成功 ${GREEN}$ok${PLAIN}${YELLOW} 条，失败 ${RED}$fail${PLAIN}${YELLOW} 条${PLAIN}"
            if (( ok > 0 )); then
                echo -e "${CYAN}正在重启 sing-box...${PLAIN}"
                systemctl restart sing-box && \
                    echo -e "${GREEN}✔ 重启完成，$ok 个节点已生效${PLAIN}" || \
                    echo -e "${RED}✘ 重启失败，请检查配置${PLAIN}"
            fi
        fi

        pause
    done
}

update_kernel() {
    echo -e "${CYAN}正在执行更新前自动备份...${PLAIN}"
    auto_backup
    
    echo -e "${YELLOW}正在更新 sing-box 内核...${PLAIN}"
    if install_base; then
        local VER=$($SB_BIN version 2>/dev/null | awk '/version/ {print $3}')
        echo -e "${GREEN}✔ 更新成功！当前版本: ${VER:-未知}${PLAIN}"
    else
        echo -e "${RED}✘ 更新失败，请检查网络或进程状态${PLAIN}"
    fi
    pause
}

enable_bbr() {
    echo -e "${YELLOW}正在检查 BBR 状态...${PLAIN}"
    local kernel_version=$(uname -r | cut -d- -f1)
    if [[ $(echo -e "4.9\n$kernel_version" | sort -V | head -n1) == "4.9" ]]; then
        if lsmod | grep -q bbr; then
            echo -e "${GREEN}BBR 已经处于运行状态。${PLAIN}"
        else
            echo -e "${CYAN}正在开启 BBR...${PLAIN}"
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            if lsmod | grep -q bbr; then
                echo -e "${GREEN}BBR 成功开启！${PLAIN}"
            else
                echo -e "${RED}BBR 开启失败。${PLAIN}"
            fi
        fi
    else
        echo -e "${RED}内核版本过低 ($kernel_version)，不支持 BBR。${PLAIN}"
    fi
    pause
}

# --- 主菜单 ---
while true; do
    clear
    echo -e "==============================================="
    echo -e "          ${RED}Sing-box 综合管理脚本${PLAIN}"
    echo -e "==============================================="
    show_status
    echo -e "-----------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 安装/重装 sing-box"
    echo -e "  ${GREEN}2.${PLAIN} 节点快速配置"
    echo -e "  ${GREEN}3.${PLAIN} 配置/分享链接查看"
    echo -e "  ${GREEN}4.${PLAIN} 分流/落地/多跳转/设置/管理"
    echo -e "  ${GREEN}5.${PLAIN} 更新sing-box内核"
    echo -e "  ${GREEN}6.${PLAIN} 备份/还原配置"
    echo -e "  ${GREEN}7.${PLAIN} 开启 BBR 网络加速"
    echo -e "  ${GREEN}8.${PLAIN} 申请 SSL 域名证书 (ACME)"
    echo -e "  ${GREEN}9.${PLAIN} 添加出站/用于/自动优选/轮询"
    echo -e " ${GREEN}10.${PLAIN} 更改配置/删除"
    echo -e " ${GREEN}11.${PLAIN} 日志查看"
    echo -e "-----------------------------------------------"
    echo -e " ${GREEN}[88]${PLAIN} 启动  ${GREEN}[99]${PLAIN} 停止  ${GREEN}[66]${PLAIN} 重启  ${RED}[77]${PLAIN} 卸载  ${RED}[0]${PLAIN} 退出"
    echo -e "==============================================="
    read -p " 请输入对应数字选择: " choice
    
    case "$choice" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) manage_routing ;;
        5) update_kernel ;;
        6) backup_restore ;;
        7) enable_bbr ;;
        8) apply_cert ;;
        9) add_outbound ;;
        10) edit_node ;;
        11) view_logs ;;
        88)
            echo -e "${YELLOW}正在启动 Sing-box...${PLAIN}"
            systemctl start sing-box
            sleep 1
            ;;
        99)
            echo -e "${YELLOW}正在停止 Sing-box...${PLAIN}"
            systemctl stop sing-box
            sleep 1
            ;;
        66)
            echo -e "${YELLOW}正在重启 Sing-box...${PLAIN}"
            systemctl restart sing-box
            sleep 1
            ;;
        77)
            read -p "确定卸载吗？此操作不可逆！(y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                systemctl stop sing-box 2>/dev/null
                systemctl disable sing-box 2>/dev/null
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload
                rm -f /usr/local/bin/ssb /usr/local/bin/sing-box
                rm -rf /etc/sing-box
                echo -e "${GREEN}✔ Sing-box 及相关配置已彻底卸载。${PLAIN}"
                exit 0
            fi
            ;;
        0) 
            exit 0 
            ;;
        *) 
            echo -e "${RED}✘ 输入错误，请重新选择${PLAIN}"
            sleep 1
            ;;
    esac
done
