#!/bin/bash

# ========================================================
# sing-box 综合管理脚本 (ssb)
# ========================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
LINK_DIR="/etc/sing-box/links"
CERT_DIR="/etc/sing-box/certs"
BACKUP_DIR="/root/singbox_backup"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
SINGBOX_CONFIG="/etc/sing-box/config.json"
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# --- 辅助工具 ---
pause() {
    echo ""
    read -p "操作完成，按回车键继续..."
}

# 原子化写入配置并进行语法检查
save_and_restart() {
    local tmp_file="${1:-tmp.json}"

    if [[ ! -f "$tmp_file" ]]; then
        echo -e "${RED}错误: 临时配置文件 ${tmp_file} 不存在。${PLAIN}"
        return 1
    fi

    # 显示检查详情，不再隐藏输出
    if $SB_BIN check -c "$tmp_file"; then
        if cp "$tmp_file" "$CONFIG_FILE" && systemctl restart sing-box; then
            rm -f "$tmp_file"
            return 0
        else
            echo -e "${RED}✘ 替换配置或重启 sing-box 失败。${PLAIN}"
            return 1
        fi
    else
        echo -e "${RED}✘ 新配置语法检查失败，错误详情如上。旧配置已保留。${PLAIN}"
        rm -f "$tmp_file"
        return 1
    fi
}

init_config() {
    mkdir -p /etc/sing-box "$LINK_DIR" "$CERT_DIR"
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}

get_ip() {
    local ip4=$(curl -s4 --connect-timeout 5 icanhazip.com || curl -s4 --connect-timeout 5 ifconfig.me)
    local ip6=$(curl -s6 --connect-timeout 5 icanhazip.com || curl -s6 --connect-timeout 5 ifconfig.me)
    if [[ -n "$ip4" ]]; then echo "$ip4"; elif [[ -n "$ip6" ]]; then echo "[$ip6]"; else echo "127.0.0.1"; fi
}

show_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box 状态: ${GREEN}[运行中]${PLAIN}"
    else
        echo -e "sing-box 状态: ${RED}[未运行/已停止]${PLAIN}"
    fi
}

# --- 功能模块 ---

# 
CERT_DIR="/etc/sing-box/cert"
BACKUP_DIR="/etc/sing-box/backup"

apply_cert() {
    echo -e "${YELLOW}--- ACME 域名证书申请 (增强版) ---${PLAIN}"
    
    # 1. 基础检查
    [[ -z "$domain" ]] && read -p "请输入解析到本机的域名: " domain
    [[ -z "$domain" ]] && echo -e "${RED}域名不能为空${PLAIN}" && return

    # 2. 端口冲突预处理
    local web_services=("nginx" "apache2" "httpd")
    local stopped_services=()
    
    echo -e "${CYAN}正在检查端口占用...${PLAIN}"
    systemctl stop sing-box 2>/dev/null
    
    for svc in "${web_services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            systemctl stop "$svc"
            stopped_services+=("$svc")
        fi
    done

    # 3. 安装依赖与 acme.sh
    apt update && apt install -y socat cron uuid-runtime
    local ACME_BIN="$HOME/.acme.sh/acme.sh"
    
    if [ ! -f "$ACME_BIN" ]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
    fi

    # 4. 申请证书 (强制使用绝对路径)
    echo -e "${YELLOW}正在尝试申请证书...${PLAIN}"
    "$ACME_BIN" --issue -d "$domain" --standalone --server letsencrypt --force
    
    if [ $? -eq 0 ]; then
        local target_dir="$CERT_DIR/$domain"
        mkdir -p "$target_dir"
        "$ACME_BIN" --install-cert -d "$domain" \
            --key-file "$target_dir/server.key" \
            --fullchain-file "$target_dir/server.crt"
        echo -e "${GREEN}✔ 证书安装成功！路径: $target_dir${PLAIN}"
    else
        echo -e "${RED}✘ 申请失败！请检查: 1.域名解析是否生效 2.防火墙是否放行 80 端口${PLAIN}"
    fi

    # 5. 恢复环境 (原路启动)
    systemctl start sing-box 2>/dev/null
    for svc in "${stopped_services[@]}"; do
        systemctl start "$svc" 2>/dev/null
    done
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
            local R_FILE=${files[$((r_idx-1))]}
            if [[ -n "$R_FILE" ]]; then
                systemctl stop sing-box
                tar -xzf "$BACKUP_DIR/$R_FILE" -C /tmp/
                cp /tmp/sing-box /usr/local/bin/sing-box
                cp -r /tmp/sing-box/* /etc/sing-box/
                systemctl restart sing-box
                echo -e "${GREEN}备份 $R_FILE 还原成功${PLAIN}"
            fi
        fi
    fi
    pause
}

install_base() {
    echo -e "${GREEN}>>> 正在安装依赖并检测架构...${PLAIN}"
    apt update -y && apt install -y curl jq openssl tar util-linux wget uuid-runtime

    local arch=""
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"; pause; return ;;
    esac

    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    echo -e "${CYAN}检测到架构: $arch, 正在下载版本: $TAG...${PLAIN}"
    
    local url="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${arch}.tar.gz"
    wget -O sing-box.tar.gz "$url"
    tar -xzf sing-box.tar.gz
    mv sing-box-*/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box*

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
    init_config
    cp "$0" /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
    systemctl start sing-box
    echo -e "${GREEN}安装完成！请输入 ssb 管理。${PLAIN}"
    pause
}

add_node() {
    clear
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS + Reality"
    echo "2. TUIC v5"
    echo "3. Hysteria2"
    echo "4. Shadowsocks (2022-blake3)"
    echo "5. VLESS + WS + CF"
    echo "6. Socks5"
    echo "7. HTTPS (HTTP over TLS)"
    echo "8. Trojan"
    echo "0. 返回"
    read -p "请选择: " choice

    [[ "$choice" == "0" ]] && return

    IP=$(get_ip)
    local LINK=""
    local TAG=""
    local gen_uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    case $choice in
        1)
            UUID=$gen_uuid
            KEYS=$($SB_BIN generate reality-keypair)
            PRIVATE=$(echo "$KEYS" | awk -F': ' '/Private/ {print $2}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS" | awk -F': ' '/Public/ {print $2}' | tr -d '[:space:]')
            SHORT_ID=$(openssl rand -hex 8)
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            read -p "SNI (默认 music.apple.com): " SNI; SNI=${SNI:-"music.apple.com"}
            TAG="reality${PORT}"

            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg priv "$PRIVATE" --arg sid "$SHORT_ID" --arg tag "$TAG" \
               '.inbounds += [{
                    "type":"vless", "tag":$tag, "listen":"::", "listen_port":($port|tonumber),
                    "users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],
                    "tls":{
                        "enabled":true, "server_name":$sni,
                        "reality":{"enabled":true, "handshake":{"server":$sni,"server_port":443}, "private_key":$priv, "short_id":[$sid]}
                    }
                }]' "$CONFIG_FILE" > tmp.json
            
            if save_and_restart; then
                LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#$TAG"
            fi
            ;;
        2)
            UUID=$gen_uuid
            read -p "端口: " PORT; read -p "密码: " PASS; TAG="tuic${PORT}"
            echo -e "1. 自签名证书 | 2. ACME 真证书"
            read -p "选择: " cert_type
            if [[ "$cert_type" == "2" ]]; then
                read -p "真证书对应的域名: " domain
                CERT_PATH="$CERT_DIR/$domain/server.crt"; KEY_PATH="$CERT_DIR/$domain/server.key"
                [[ ! -f "$CERT_PATH" ]] && echo -e "${RED}错误: 未检测到证书，请先申请${PLAIN}" && pause && return
                ALLOW_INSECURE="0"; SNI_NAME="$domain"
            else
                CERT_PATH="/etc/sing-box/tuic.crt"; KEY_PATH="/etc/sing-box/tuic.key"
                openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=apple.com" -days 3650 2>/dev/null
                ALLOW_INSECURE="1"; SNI_NAME="apple.com"
            fi
            jq --arg port "$PORT" --arg uuid "$UUID" --arg pass "$PASS" --arg cert "$CERT_PATH" --arg key "$KEY_PATH" --arg tag "$TAG" \
               '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"password":$pass}],"tls":{"enabled":true,"certificate_path":$cert,"key_path":$key,"alpn":["h3"]}}]' "$CONFIG_FILE" > tmp.json
            if save_and_restart; then
                LINK="tuic://$UUID:$PASS@$IP:$PORT?sni=$SNI_NAME&alpn=h3&allow_insecure=$ALLOW_INSECURE&congestion_control=bbr#$TAG"
            fi
            ;;
        3)
            read -p "端口: " PORT; read -p "密码: " PASS; TAG="hy2${PORT}"
            echo -e "1. 自签名证书 | 2. ACME 真证书"
            read -p "选择: " cert_type
            if [[ "$cert_type" == "2" ]]; then
                read -p "真证书对应的域名: " domain
                CERT_PATH="$CERT_DIR/$domain/server.crt"; KEY_PATH="$CERT_DIR/$domain/server.key"
                [[ ! -f "$CERT_PATH" ]] && echo -e "${RED}错误: 未检测到证书，请先申请${PLAIN}" && pause && return
                IS_INSECURE="0"; SNI_NAME="$domain"
            else
                CERT_PATH="/etc/sing-box/hy2.crt"; KEY_PATH="/etc/sing-box/hy2.key"
                openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=amazon.com" -days 3650 2>/dev/null
                IS_INSECURE="1"; SNI_NAME="amazon.com"
            fi
            jq --arg port "$PORT" --arg pass "$PASS" --arg cert "$CERT_PATH" --arg key "$KEY_PATH" --arg tag "$TAG" \
               '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"password":$pass}],"tls":{"enabled":true,"certificate_path":$cert,"key_path":$key}}]' "$CONFIG_FILE" > tmp.json
            if save_and_restart; then
                LINK="hysteria2://$PASS@$IP:$PORT?insecure=$IS_INSECURE&sni=$SNI_NAME#$TAG"
            fi
            ;;
        4)
            read -p "端口: " PORT; PASS=$(openssl rand -base64 16); METHOD="2022-blake3-aes-128-gcm"; TAG="ss${PORT}"
            jq --arg port "$PORT" --arg pass "$PASS" --arg method "$METHOD" --arg tag "$TAG" \
               '.inbounds += [{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' "$CONFIG_FILE" > tmp.json
            if save_and_restart; then
                SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
                LINK="ss://$SS_BASE64@$IP:$PORT#$TAG"
            fi
            ;;
        5)
            read -p "域名: " DOMAIN
            CERT_PATH="$CERT_DIR/$DOMAIN/server.crt"; KEY_PATH="$CERT_DIR/$DOMAIN/server.key"
            if [[ ! -f "$CERT_PATH" ]]; then echo -e "${RED}错误: 未检测到 $DOMAIN 的 SSL 证书，请先申请${PLAIN}"; pause; return; fi
            read -p "端口: " PORT; read -p "WS路径: " WSPATH; WSPATH=${WSPATH:-"/video"}
            TAG="vless-ws-${PORT}"; UUID=$gen_uuid
            jq --arg port "$PORT" --arg uuid "$UUID" --arg path "$WSPATH" --arg domain "$DOMAIN" --arg tag "$TAG" --arg cert "$CERT_PATH" --arg key "$KEY_PATH" \
               '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":$path},"tls":{"enabled":true,"server_name":$domain,"certificate_path":$cert,"key_path":$key}}]' "$CONFIG_FILE" > tmp.json
            if save_and_restart; then
                LINK="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&path=$WSPATH#$TAG"
            fi
            ;;
        6)
            read -p "端口: " PORT; read -p "用户: " USER; read -p "密码: " PASS; TAG="socks${PORT}"
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" --arg tag "$TAG" \
               '.inbounds += [{"type":"socks","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}]}]' "$CONFIG_FILE" > tmp.json
            if save_and_restart; then
                LINK="socks5://$USER:$PASS@$IP:$PORT#$TAG"
            fi
            ;;
        7)
            # --- 新增: HTTPS (HTTP Proxy over TLS) ---
            read -p "端口: " PORT; read -p "用户名: " USER; read -p "密码: " PASS; TAG="https${PORT}"
            echo -e "1. 自签名证书 | 2. ACME 真证书"
            read -p "选择: " cert_type
            if [[ "$cert_type" == "2" ]]; then
                read -p "真证书对应的域名: " domain
                CERT_PATH="$CERT_DIR/$domain/server.crt"; KEY_PATH="$CERT_DIR/$domain/server.key"
                [[ ! -f "$CERT_PATH" ]] && echo -e "${RED}错误: 未检测到证书，请先申请${PLAIN}" && pause && return
                HOST_ADDR="$domain"
            else
                CERT_PATH="/etc/sing-box/https.crt"; KEY_PATH="/etc/sing-box/https.key"
                openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=bing.com" -days 3650 2>/dev/null
                HOST_ADDR="$IP"
            fi
            
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" --arg cert "$CERT_PATH" --arg key "$KEY_PATH" --arg tag "$TAG" \
               '.inbounds += [{"type":"http","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}],"tls":{"enabled":true,"certificate_path":$cert,"key_path":$key}}]' "$CONFIG_FILE" > tmp.json
            
            if save_and_restart; then
                # HTTPS 代理的标准 URI 格式
                LINK="https://$USER:$PASS@$HOST_ADDR:$PORT#$TAG"
            fi
            ;;
        8)
            # --- 新增: Trojan ---
            read -p "端口: " PORT; read -p "密码: " PASS; TAG="trojan${PORT}"
            echo -e "1. 自签名证书 | 2. ACME 真证书"
            read -p "选择: " cert_type
            if [[ "$cert_type" == "2" ]]; then
                read -p "真证书对应的域名: " domain
                CERT_PATH="$CERT_DIR/$domain/server.crt"; KEY_PATH="$CERT_DIR/$domain/server.key"
                [[ ! -f "$CERT_PATH" ]] && echo -e "${RED}错误: 未检测到证书，请先申请${PLAIN}" && pause && return
                SNI_NAME="$domain"; IS_INSECURE="0"; HOST_ADDR="$domain"
            else
                CERT_PATH="/etc/sing-box/trojan.crt"; KEY_PATH="/etc/sing-box/trojan.key"
                openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=amazon.com" -days 3650 2>/dev/null
                SNI_NAME="amazon.com"; IS_INSECURE="1"; HOST_ADDR="$IP"
            fi
            
            jq --arg port "$PORT" --arg pass "$PASS" --arg cert "$CERT_PATH" --arg key "$KEY_PATH" --arg tag "$TAG" \
               '.inbounds += [{"type":"trojan","tag":$tag,"listen":"::","listen_port":($port|tonumber),"users":[{"password":$pass}],"tls":{"enabled":true,"certificate_path":$cert,"key_path":$key}}]' "$CONFIG_FILE" > tmp.json
            
            if save_and_restart; then
                # Trojan 的标准 URI 格式，附带 sni 和不安全校验参数
                LINK="trojan://$PASS@$HOST_ADDR:$PORT?security=tls&sni=$SNI_NAME&allowInsecure=$IS_INSECURE#$TAG"
            fi
            ;;
    esac

    if [[ -n "$LINK" ]]; then
        echo "$LINK" > "$LINK_DIR/${TAG}.link"
        echo -e "${GREEN}节点添加成功并已保存链接！${PLAIN}"
        echo -e "分享链接: ${BLUE}$LINK${PLAIN}"
    fi
    pause
}

manage_configs() {
    clear
    echo -e "${YELLOW}--- 节点配置查看 ---${PLAIN}"
    local count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    # 1. 列表显示所有节点
    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择要查看的序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return

    # 2. 获取节点基本信息
    local TAG=$(jq -r ".inbounds[$(($idx-1))].tag" "$CONFIG_FILE")
    local CONF=$(jq -c ".inbounds[$(($idx-1))]" "$CONFIG_FILE")
    local TYPE=$(echo "$CONF" | jq -r .type)
    local PORT=$(echo "$CONF" | jq -r .listen_port)
    local IP=$(get_ip)

    # 3. 打印详情
    echo -e "\n${GREEN}================ 原始 JSON 配置 ================${PLAIN}"
    echo "$CONF" | jq .
    echo -e "${GREEN}===============================================${PLAIN}"

    echo -e "\n${YELLOW}>>>> 节点分享链接 <<<<${PLAIN}"
    
    # 优先使用持久化文件，不存在则动态生成
    if [[ -f "$LINK_DIR/${TAG}.link" ]]; then
        echo -e "${BLUE}$(cat "$LINK_DIR/${TAG}.link")${PLAIN}"
    else
        echo -e "${RED}未找到持久化链接文件，尝试根据当前配置生成...${PLAIN}"
        
        # 尝试从 TLS 配置中提取域名，如果提取不到则使用 IP
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
    clear
    echo -e "${YELLOW}--- 修改/删除节点配置 ---${PLAIN}"
    local count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    # 1. 列出节点
    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return
    
    local i=$(($idx-1))
    local TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
    local TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")

    echo -e "\n${CYAN}当前节点: $TAG ($TYPE)${PLAIN}"
    echo "1. 修改端口"
    echo "2. 修改 UUID / 密码"
    echo "3. 修改 SNI (域名)"
    echo "4. 删除此节点"
    echo "0. 返回"
    read -p "请选择操作: " op

    case $op in
        1)
            read -p "请输入新端口: " NEW_PORT
            [[ -z "$NEW_PORT" ]] && return
            jq ".inbounds[$i].listen_port = ($NEW_PORT|tonumber)" "$CONFIG_FILE" > tmp.json
            ;;
        2)
            # --- 身份凭据修改逻辑 ---
            local AUTH_FIELD=".users[0].uuid"
            # TUIC, Hy2, Trojan, HTTP 使用 password；VLESS 使用 uuid
            [[ "$TYPE" == "trojan" || "$TYPE" == "hysteria2" || "$TYPE" == "http" || "$TYPE" == "tuic" ]] && AUTH_FIELD=".users[0].password"
            [[ "$TYPE" == "shadowsocks" ]] && AUTH_FIELD=".password" 
            
            read -p "请输入新的身份凭证 (UUID/密码): " NEW_AUTH
            [[ -z "$NEW_AUTH" ]] && return
            
            # 如果是 TUIC，通常 UUID 和 Password 都会用到，这里我们默认修改 Password 字段
            # 如果你想同时改 TUIC 的 UUID，可以额外增加逻辑，但一般改 Password 即可生效
            jq ".inbounds[$i]$AUTH_FIELD = \"$NEW_AUTH\"" "$CONFIG_FILE" > tmp.json
            ;;
        3)
            read -p "请输入新的 SNI (域名): " NEW_SNI
            [[ -z "$NEW_SNI" ]] && return
            # 修改通用 TLS SNI
            jq ".inbounds[$i].tls.server_name = \"$NEW_SNI\" | 
                if .inbounds[$i].tls.reality then .inbounds[$i].tls.reality.handshake.server = \"$NEW_SNI\" else . end" "$CONFIG_FILE" > tmp.json
            ;;
        4)
            read -p "确定删除 $TAG 吗？(y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                jq "del(.inbounds[$i])" "$CONFIG_FILE" > tmp.json
                if save_and_restart; then
                    rm -f "$LINK_DIR/${TAG}.link"
                    echo -e "${GREEN}✔ 节点及持久化文件已删除${PLAIN}"
                fi
            fi
            pause && return
            ;;
        *) return ;;
    esac

    # 4. 保存并更新链接
    if [[ -f "tmp.json" ]]; then
        if save_and_restart; then
            echo -e "${GREEN}✔ 配置已更新！正在重新生成链接...${PLAIN}"
            
            local CONF=$(jq -c ".inbounds[$i]" "$CONFIG_FILE")
            local PORT=$(echo "$CONF" | jq -r .listen_port)
            local IP=$(get_ip)
            local SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')
            local HOST=${SNI:-$IP}
            local NEW_LINK=""

            case $TYPE in
                vless)
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                    local WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
                    NEW_LINK="vless://$UUID@$HOST:$PORT?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$TAG"
                    ;;
                tuic)
                    # --- 新增 TUIC 链接还原 ---
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="tuic://$UUID:$PASS@$HOST:$PORT?congestion_control=bbr&sni=$SNI&alpn=h3#$TAG"
                    ;;
                hysteria2)
                    # --- 新增 Hysteria2 链接还原 ---
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="hysteria2://$PASS@$HOST:$PORT?sni=$SNI#$TAG"
                    ;;
                shadowsocks)
                    local METHOD=$(echo "$CONF" | jq -r .method); local PASS=$(echo "$CONF" | jq -r .password)
                    local SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
                    NEW_LINK="ss://$SS_BASE64@$IP:$PORT#$TAG"
                    ;;
                trojan)
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password'); local INS=$(echo "$CONF" | jq -r '.tls.insecure // false')
                    local IVAL="0"; [[ "$INS" == "true" ]] && IVAL="1"
                    NEW_LINK="trojan://$PASS@$HOST:$PORT?security=tls&sni=$SNI&allowInsecure=$IVAL#$TAG"
                    ;;
                http)
                    local USER=$(echo "$CONF" | jq -r '.users[0].username // ""'); local PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                    NEW_LINK="https://$USER:$PASS@$HOST:$PORT#$TAG"
                    ;;
            esac

            # 更新持久化文件
            if [[ -n "$NEW_LINK" ]]; then
                echo "$NEW_LINK" > "$LINK_DIR/${TAG}.link"
                echo -e "${BLUE}新链接: $NEW_LINK${PLAIN}"
            fi
        fi
    fi
    pause
}

# 简单的解析函数：支持 ss:// 和 socks5://
parse_proxy_link() {
    local link=$1
    local content user_info server_info
    
    # 彻底清空全局变量，防止逻辑污染
    R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; R_USER=""; hop_type=""

    if [[ "$link" =~ ^ss:// ]]; then
        hop_type=1
        content=$(echo "${link#ss://}" | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            # SIP002 格式
            local user_info_b64=$(echo "$content" | cut -d'@' -f1)
            server_info=$(echo "$content" | cut -d'@' -f2)
            user_info=$(echo "$user_info_b64" | tr '_-' '/+' | awk '{printf "%s%s", $0, substr("===", 1, (4-length($0)%4)%4)}' | base64 -d 2>/dev/null)
            R_METHOD=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2)
            R_ADDR=$(echo "$server_info" | cut -d':' -f1)
            R_PORT=$(echo "$server_info" | cut -d':' -f2 | cut -d'/' -f1)
        else
            # 全包 Base64 格式
            local decoded=$(echo "$content" | tr '_-' '/+' | awk '{printf "%s%s", $0, substr("===", 1, (4-length($0)%4)%4)}' | base64 -d 2>/dev/null)
            if [[ "$decoded" =~ ^(.+):(.+)@(.+):([0-9]+) ]]; then
                R_METHOD="${BASH_REMATCH[1]}"; R_PASS="${BASH_REMATCH[2]}"
                R_ADDR="${BASH_REMATCH[3]}"; R_PORT="${BASH_REMATCH[4]}"
            fi
        fi
    elif [[ "$link" =~ ^socks5:// ]]; then
        hop_type=2
        content=${link#socks5://}; content=$(echo "$content" | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1); server_info=$(echo "$content" | cut -d'@' -f2)
            R_USER=$(echo "$user_info" | cut -d':' -f1); R_PASS=$(echo "$user_info" | cut -d':' -f2)
            R_ADDR=$(echo "$server_info" | cut -d':' -f1); R_PORT=$(echo "$server_info" | cut -d':' -f2)
        else
            R_ADDR=$(echo "$content" | cut -d':' -f1); R_PORT=$(echo "$content" | cut -d':' -f2)
        fi
    elif [[ "$link" =~ ^https:// ]]; then
        hop_type=3
        content=${link#https://}; content=$(echo "$content" | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1); server_info=$(echo "$content" | cut -d'@' -f2)
            R_USER=$(echo "$user_info" | cut -d':' -f1); R_PASS=$(echo "$user_info" | cut -d':' -f2)
            R_ADDR=$(echo "$server_info" | cut -d':' -f1); R_PORT=$(echo "$server_info" | cut -d':' -f2)
        else
            R_ADDR=$(echo "$content" | cut -d':' -f1); R_PORT=$(echo "$content" | cut -d':' -f2)
        fi
    fi
}

# --- 链式代理：链路管理与强制重定向 ---
chain_proxy() {
    local cp_choice idx LOCAL_TAG RAW_LINK R_ADDR R_PORT R_METHOD R_PASS R_USER \
          hop_type SKIP_TLS OUT_TAG OUT_JSON CURRENT_OUTBOUND NEW_RULE_JSON

    while true; do
        clear
        echo -e "${YELLOW}================================================${PLAIN}"
        echo -e "${YELLOW}           链式代理与链路管理           ${PLAIN}"
        echo -e "${YELLOW}================================================${PLAIN}"
        echo " 1. 添加跳转节点 链式)"
        echo " 2. 查看当前活跃链路"
        echo " 3. 重置入站规则 (恢复直连)"
        echo " 0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " cp_choice


        # --- 0. 退出逻辑 ---
        [[ "$cp_choice" == "0" ]] && return 0


        case $cp_choice in
            1)
                # --- A. 选择入站节点 ---
                echo -e "\n${CYAN}[步骤1] 选择流量进入的入站 (Inbound):${PLAIN}"
                jq -r '.inbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                read -p "选择序号: " idx
                [[ -z "$idx" ]] && continue
                LOCAL_TAG=$(jq -r ".inbounds[$((idx-1))].tag" "$CONFIG_FILE")
                
                # 精准获取当前出口 (兼容数组和字符串格式)
                CURRENT_OUTBOUND=$(jq -r --arg itag "$LOCAL_TAG" '
                    .route.rules[] | 
                    select(if .inbound | type == "array" then .inbound | contains([$itag]) else .inbound == $itag end) | 
                    .outbound' "$CONFIG_FILE" | head -n 1)


                # --- B. 获取新节点信息 ---
                echo -e "\n${CYAN}[步骤2] 配置出口节点 (Outbound):${PLAIN}"
                read -p "粘贴链接 (回车手动输入): " RAW_LINK
                
                # 清理旧变量
                R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; R_USER=""; hop_type=""

                if [[ -n "$RAW_LINK" ]]; then
                    parse_proxy_link "$RAW_LINK"
                fi

                if [[ -z "$R_ADDR" ]]; then
                    echo -e "\n${YELLOW}>> 手动输入模式:${PLAIN}"
                    echo "1) Shadowsocks  2) Socks5  3) HTTPS"
                    read -p "协议选择: " hop_type
                    case $hop_type in
                        1) read -p "地址: " R_ADDR; read -p "端口[8388]: " R_PORT; R_PORT=${R_PORT:-8388}
                           read -p "加密[aes-128-gcm]: " R_METHOD; R_METHOD=${R_METHOD:-aes-128-gcm}
                           read -p "密码: " R_PASS ;;
                        2) read -p "地址: " R_ADDR; read -p "端口[1080]: " R_PORT; R_PORT=${R_PORT:-1080}
                           read -p "用户: " R_USER; read -p "密码: " R_PASS ;;
                        3) read -p "地址: " R_ADDR; read -p "端口[443]: " R_PORT; R_PORT=${R_PORT:-443}
                           read -p "用户: " R_USER; read -p "密码: " R_PASS ;;
                    esac
                fi

                [[ -z "$R_ADDR" ]] && echo -e "${RED}输入无效${PLAIN}" && sleep 1 && continue


                # --- C. HTTPS 证书预处理 ---
                SKIP_TLS="n"
                if [[ "$hop_type" == "3" || "$RAW_LINK" =~ ^https:// ]]; then
                    read -p "是否跳过证书验证 (Insecure)? [y/N]: " SKIP_TLS
                    SKIP_TLS=${SKIP_TLS:-n}
                fi


                # --- D. 构造 JSON 对象 ---
                OUT_TAG="chain-$(date +%s)"

                # 构造节点 JSON
                OUT_JSON=$(jq -n \
                    --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    --arg m "$R_METHOD" --arg pass "$R_PASS" --arg u "$R_USER" \
                    --arg d "$CURRENT_OUTBOUND" --arg ht "$hop_type" --arg skip "$SKIP_TLS" \
                    '
                    (if $ht == "1" then
                        {type: "shadowsocks", tag: $t, server: $s, server_port: ($p|tonumber), method: $m, password: $pass}
                    elif $ht == "2" then
                        {type: "socks", tag: $t, server: $s, server_port: ($p|tonumber), version: "5"} + (if $u != "" then {username: $u, password: $pass} else {} end)
                    elif $ht == "3" then
                        {type: "http", tag: $t, server: $s, server_port: ($p|tonumber), tls: {enabled: true, insecure: ($skip == "y" or $skip == "Y")}} + (if $u != "" then {username: $u, password: $pass} else {} end)
                    else empty end) 
                    | if ($d != "" and $d != "null" and $d != "direct") then . + {detour: $d} else . end
                    ' -c)

                # 构造路由规则 JSON (强制为数组格式)
                NEW_RULE_JSON=$(jq -n --arg itag "$LOCAL_TAG" --arg otag "$OUT_TAG" '{"inbound": [$itag], "outbound": $otag}')


                # --- E. 物理写入与安全检查 ---
                echo -e "\n${CYAN}[步骤3] 正在应用配置...${PLAIN}"

                # 逻辑：先在 outbounds 添加节点，再重构 route.rules (新规则置顶 + 过滤掉该入站的旧规则)
                jq --argjson newNode "$OUT_JSON" --argjson newRule "$NEW_RULE_JSON" --arg itag "$LOCAL_TAG" '
                    .outbounds += [$newNode] |
                    .route.rules = (
                        [$newRule] + 
                        [ .route.rules[] | select(
                            if .inbound then 
                                (if .inbound | type == "array" then .inbound | contains([$itag]) | not else .inbound != $itag end)
                            else true end
                        ) ]
                    )
                ' "$CONFIG_FILE" > tmp.json

                if [[ -s tmp.json ]] && /usr/local/bin/sing-box check -c tmp.json > /dev/null 2>&1; then
                    mv tmp.json "$CONFIG_FILE"
                    systemctl restart sing-box
                    echo -e "${GREEN}✔ 配置成功！${PLAIN}"
                    echo -e "链路详情: ${BLUE}$LOCAL_TAG${PLAIN} -> ${GREEN}$OUT_TAG${PLAIN} -> ${YELLOW}${CURRENT_OUTBOUND:-"互联网"}${PLAIN}"
                else
                    echo -e "${RED}✖ 错误：配置校验失败，已回滚。${PLAIN}"
                    /usr/local/bin/sing-box check -c tmp.json
                    rm -f tmp.json
                fi
                pause
                ;;

            2)
                echo -e "\n${YELLOW}--- 当前活跃转发链路 ---${PLAIN}"
                jq -r '.route.rules[] | select(.inbound != null) | "入站: \(.inbound)  ==>  出口: \(.outbound)"' "$CONFIG_FILE"
                pause
                ;;

            3)
                echo -e "\n${YELLOW}选择要重置为直连的入站:${PLAIN}"
                # 提取所有有规则的入站标签
                local in_tags=$(jq -r '.route.rules[] | select(.inbound != null) | .inbound | if type == "array" then .[0] else . end' "$CONFIG_FILE")
                echo "$in_tags" | cat -n
                read -p "选择序号: " del_idx
                local DEL_IN_TAG=$(echo "$in_tags" | sed -n "${del_idx}p")

                if [[ -n "$DEL_IN_TAG" ]]; then
                    jq --arg itag "$DEL_IN_TAG" '
                        .route.rules |= map(if (if .inbound | type == "array" then .inbound | contains([$itag]) else .inbound == $itag end) then .outbound = "direct" else . end)
                    ' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
                    systemctl restart sing-box
                    echo -e "${GREEN}✔ 入站 [$DEL_IN_TAG] 已恢复直连。${PLAIN}"
                fi
                pause
                ;;
        esac
    done
}

manage_routing() {
    local rt_choice IN_TAGS OUT_TAG OUT_JSON RULE_JSON
    
    while true; do
        clear
        echo -e "${YELLOW}--- 网站分流/路由管理 ---${PLAIN}"
        echo "1. 添加分流规则 (入站 + 目标 -> 指定出站)"
        echo "2. 查看当前分流规则"
        echo "3. 删除特定分流规则"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " rt_choice

        case $rt_choice in
            1)
                # --- 1. 选择入站 ---
                echo -e "\n${CYAN}1. 请选择来源入站:${PLAIN}"
                local in_count=$(jq '.inbounds | length' "$CONFIG_FILE")
                [[ "$in_count" -eq 0 ]] && echo -e "${RED}无入站配置${PLAIN}" && pause && continue
                jq -r '.inbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                read -p "选择序号 (逗号隔开, 回车代表全部): " in_idxs
                if [[ -z "$in_idxs" ]]; then IN_TAGS="null"; else
                    IN_TAGS=$(echo "$in_idxs" | tr ',' '\n' | while read -r i; do jq -r ".inbounds[$((i-1))].tag" "$CONFIG_FILE"; done | jq -R . | jq -s . -c)
                fi

                # --- 2. 匹配目标 ---
                echo -e "\n${CYAN}2. 请选择匹配的目标:${PLAIN}"
                echo "1) 全部流量 | 2) 域名匹配 | 3) GeoSite | 4) IP/CIDR"
                read -p "选择 [1-4]: " target_type
                local RULE_PART="{}"
                case $target_type in
                    2) read -p "域名: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"domain": .}' -c) ;;
                    3) read -p "GeoSite: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"geosite": .}' -c) ;;
                    4) read -p "IP/CIDR: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"ip_cidr": .}' -c) ;;
                esac

                # --- 3. 出站配置 (移除引发报错的非法字段) ---
                echo -e "\n${CYAN}3. 请配置目标出站:${PLAIN}"
                echo "1) 粘贴链接 | 2) 手动输入 | 3) 自动优选 (URL-Test) | 4) 节点组 (Selector)"
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
                    echo -e "1) SS | 2) Socks5 | 3) HTTPS"; read -p "协议: " h_type
                    read -p "地址: " R_ADDR; read -p "端口: " R_PORT
                    case $h_type in
                        1) read -p "加密: " R_METHOD; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}') ;;
                        2) read -p "用户: " R_USER; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"} + (if $u != "" then {"username":$u,"password":$pass} else {} end)') ;;
                        3) read -p "用户: " R_USER; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" '{"type":"http","tag":$t,"server":$s,"server_port":($p|tonumber),"tls":{"enabled":true}} + (if $u != "" then {"username":$u,"password":$pass} else {} end)') ;;
                    esac
                elif [[ "$out_mode" == "3" || "$out_mode" == "4" ]]; then
                    echo -e "\n${YELLOW}选择代理成员 (多选用逗号):${PLAIN}"
                    # 过滤直连和系统节点
                    jq -r '.outbounds | keys[] as $i | select(.[$i].type != "direct" and .[$i].type != "dns" and .[$i].type != "block") | "\($i+1)) [\(.[$i].type)] \(.[$i].tag)"' "$CONFIG_FILE"
                    read -p "序号: " m_idxs
                    [[ -z "$m_idxs" ]] && continue
                    MEMBER_TAGS=$(echo "$m_idxs" | tr ',' '\n' | while read -r i; do jq -r ".outbounds[$((i-1))].tag" "$CONFIG_FILE"; done | jq -R . | jq -s . -c)
                    OUT_TAG="group-out-$(date +%s)"
                    if [[ "$out_mode" == "3" ]]; then
                        # URL-Test 测速自动切换
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" '{"type":"urltest","tag":$t,"outbounds":$m,"url":"https://www.gstatic.com/generate_204","interval":"3m0s"}')
                    else
                        # 真正的 Selector (删除了引发报错的 strategy 字段)
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" '{"type":"selector","tag":$t,"outbounds":$m}')
                    fi
                fi

                # --- 4. 写入配置并诊断 ---
                RULE_JSON=$(echo "$RULE_PART" | jq --arg ot "$OUT_TAG" --argjson it "$IN_TAGS" '. + {"outbound": $ot} + (if $it != null then {"inbound": $it} else {} end)' -c)
                
                jq --argjson out_obj "$OUT_JSON" --argjson rule_obj "$RULE_JSON" \
                   '.outbounds += [$out_obj] | .route.rules = [$rule_obj] + .route.rules' "$CONFIG_FILE" > tmp.json
                
                # 显式捕捉错误原因，替代静默失败
                if save_and_restart; then
                    echo -e "${GREEN}✔ 添加成功，配置已生效！${PLAIN}"
                else
                    echo -e "${RED}✖ 配置语法检查失败！核心错误信息如下：${PLAIN}"
                    $SB_BIN check -c tmp.json
                    rm -f tmp.json
                fi
                pause ;;

            2)
                echo -e "\n${CYAN}当前规则:${PLAIN}"
                jq -r '.route.rules | keys[] as $i | "\($i+1)) [\(.[$i].inbound // "全部")] -> [\(.[$i].outbound)]"' "$CONFIG_FILE"
                pause ;;

            3)
                echo -e "\n${YELLOW}删除序号 (all 代表全部):${PLAIN}"
                jq -r '.route.rules | keys[] as $i | "\($i+1)) \(.[$i].outbound)"' "$CONFIG_FILE"
                read -p "> " d_choice
                if [[ "$d_choice" == "all" ]]; then
                    jq '.route.rules = [] | .outbounds |= map(select(.tag | (startswith("route-out-") or startswith("group-out-")) | not))' "$CONFIG_FILE" > tmp.json
                else
                    local j_idxs=$(echo "$d_choice" | tr ',' '\n' | awk '{print $1-1}' | jq -R . | jq -s . -c)
                    jq --argjson idxs "$j_idxs" 'del(.route.rules[$idxs[]])' "$CONFIG_FILE" > tmp_s.json
                    jq '.outbounds |= map(select(((.tag | (startswith("route-out-") or startswith("group-out-"))) | not) or (.tag as $t | any(.route.rules[]; .outbound == $t))))' tmp_s.json > tmp.json
                    rm -f tmp_s.json
                fi
                
                if save_and_restart; then
                    echo -e "${GREEN}✔ 已更新${PLAIN}"
                else
                    echo -e "${RED}✖ 语法检查失败！核心错误信息如下：${PLAIN}"
                    $SB_BIN check -c tmp.json
                    rm -f tmp.json
                fi
                pause ;;
            0) return 0 ;;
        esac
    done
}

# --- 添加基础出站节点 ---
add_outbound() {
    local node_type R_ADDR R_PORT R_METHOD R_PASS R_USER RAW_LINK OUT_TAG OUT_JSON
    
    while true; do
        clear
        echo -e "${YELLOW}--- 添加基础出站节点 ---${PLAIN}"
        echo "1. 粘贴分享链接 (SS / Socks5)"
        echo "2. 手动输入配置 (SS / Socks5 / HTTPS)"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择 [0-2]: " node_type

        [[ "$node_type" == "0" ]] && break

        OUT_TAG="hop-$(date +%s)" # 自动生成节点标签
        R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; R_USER=""

        if [[ "$node_type" == "1" ]]; then
            # --- 链接解析模式 ---
            read -p "请输入节点链接: " RAW_LINK
            # 调用解析函数 (需确保脚本内有 parse_proxy_link 函数)
            parse_proxy_link "$RAW_LINK" 
            
            if [[ -z "$R_ADDR" ]]; then
                echo -e "${RED}错误：链接解析失败，请检查格式！${PLAIN}"
                pause && continue
            fi
        elif [[ "$node_type" == "2" ]]; then
            # --- 手动输入模式 ---
            echo -e "\n请选择协议: 1) SS  2) Socks5  3) HTTPS"
            read -p "选择: " proto_choice
            read -p "地址 (Domain/IP): " R_ADDR
            read -p "端口 (Port): " R_PORT
            
            case $proto_choice in
                1)
                    read -p "加密方式 (如 aes-256-gcm): " R_METHOD
                    read -p "密码: " R_PASS
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" \
                        '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}')
                    ;;
                2)
                    read -p "用户名 (可选): " R_USER
                    read -p "密码 (可选): " R_PASS
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" \
                        '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"} + (if $u != "" then {"username":$u,"password":$pass} else {} end)')
                    ;;
                3)
                    read -p "用户名 (可选): " R_USER
                    read -p "密码 (可选): " R_PASS
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" \
                        '{"type":"http","tag":$t,"server":$s,"server_port":($p|tonumber),"tls":{"enabled":true}} + (if $u != "" then {"username":$u,"password":$pass} else {} end)')
                    ;;
                *) echo -e "${RED}非法输入${PLAIN}"; continue ;;
            esac
        fi

        # 如果是链接解析过来的，需要根据解析结果构造 JSON
        if [[ -z "$OUT_JSON" && -n "$R_ADDR" ]]; then
            if [[ -n "$R_METHOD" ]]; then # SS
                OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" \
                    '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}')
            else # Socks5
                OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" \
                    '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"} + (if $u != "" then {"username":$u,"password":$pass} else {} end)')
            fi
        fi

        # --- 写入配置文件 ---
        if [[ -n "$OUT_JSON" ]]; then
            jq --argjson obj "$OUT_JSON" '.outbounds += [$obj]' "$CONFIG_FILE" > tmp.json
            
            if save_and_restart; then
                echo -e "${GREEN}✔ 节点 [$OUT_TAG] 添加成功！${PLAIN}"
            else
                echo -e "${RED}✖ 语法检查失败，节点未添加。${PLAIN}"
                $SB_BIN check -c tmp.json
                rm -f tmp.json
            fi
        fi
        pause
    done
}

# ========== 注册 WARP 账户 ==========
register_warp_account() {
    W_PRIV=""; W_V4=""; W_V6=""; W_RES_JSON=""

    # 1. 依赖检查与安装
    local deps=("wireguard-tools" "jq" "curl" "bsdmainutils")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "${dep%% *}" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}安装依赖: ${missing[*]}${PLAIN}"
        if command -v apt &>/dev/null; then
            apt update && apt install -y "${missing[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y "${missing[@]}"
        else
            echo -e "${RED}请手动安装: ${missing[*]}${PLAIN}"
            return 1
        fi
    fi

    # 2. 生成 WireGuard 密钥
    local priv pub
    priv=$(wg genkey) || { echo -e "${RED}生成私钥失败${PLAIN}"; return 1; }
    pub=$(echo "$priv" | wg pubkey) || { echo -e "${RED}生成公钥失败${PLAIN}"; return 1; }

    # 3. 调用 Cloudflare API（端点自愈）
    echo -e "${CYAN}正在通过 Cloudflare API 申请 WARP 账户...${PLAIN}"
    local tos_date
    if date -u +%FT%T.000Z >/dev/null 2>&1; then
        tos_date=$(date -u +%FT%T.000Z)
    else
        tos_date="2024-01-01T00:00:00.000Z"
    fi

    local api_endpoint="https://api.cloudflareclient.com/v0a2158/reg"
    local user_agent="okhttp/3.12.1"
    local response
    response=$(curl -s --connect-timeout 10 \
        -H "Content-Type: application/json" \
        -H "User-Agent: $user_agent" \
        -X POST "$api_endpoint" \
        -d "{\"install_id\":\"\",\"tos\":\"$tos_date\",\"key\":\"$pub\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")

    if [[ -z "$response" || "$response" != "{"* ]]; then
        api_endpoint="https://api.cloudflareclient.com/v0a2445/reg"
        response=$(curl -s --connect-timeout 10 \
            -H "Content-Type: application/json" \
            -H "User-Agent: $user_agent" \
            -X POST "$api_endpoint" \
            -d "{\"install_id\":\"\",\"tos\":\"$tos_date\",\"key\":\"$pub\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")
    fi

    # 4. 基础检查
    if [[ "$response" != *"token"* ]]; then
        echo -e "${RED}✘ WARP 注册失败${PLAIN}"
        echo -e "${RED}API 返回：${response:-<empty>}${PLAIN}"
        return 1
    fi

    # 5. 解析地址（自适应新旧路径）
    W_V4=$(echo "$response" | jq -r '(.config.interface.addresses.v4 // .config.interface.address.v4 // empty)' 2>/dev/null)
    W_V6=$(echo "$response" | jq -r '(.config.interface.addresses.v6 // .config.interface.address.v6 // empty)' 2>/dev/null)

    # 6. 提取 client_id（兼容 client_id / clientId）
    local client_id
    client_id=$(echo "$response" | jq -r '.config.client_id // .config.clientId // empty' 2>/dev/null)
    if [[ -z "$client_id" || "$client_id" == "null" ]]; then
        echo -e "${RED}✘ 无法提取客户端 ID${PLAIN}"
        echo -e "${YELLOW}调试信息：API 返回结构${PLAIN}"
        echo "$response" | jq .
        return 1
    fi

    # 7. 解码 reserved（兼容 od / hexdump）
    local decoded
    decoded=$(echo "$client_id" | base64 -d 2>/dev/null)
    if command -v od &>/dev/null; then
        W_RES_JSON=$(echo "$decoded" | od -An -t u1 --endian=big | tr -s ' ' ',' | sed 's/^,//' | awk '{print "["$0"]"}')
    else
        W_RES_JSON=$(echo "$decoded" | hexdump -v -e '/1 "%d,"' | sed 's/,$//' | awk '{print "["$0"]"}')
    fi

    if [[ -z "$W_RES_JSON" || "$W_RES_JSON" == "[]" ]]; then
        echo -e "${RED}✘ 解码 reserved 失败${PLAIN}"
        return 1
    fi

    # 8. 保存私钥
    W_PRIV="$priv"

    # 9. 结果确认（至少有一个地址）
    if [[ -z "$W_V4" && -z "$W_V6" ]]; then
        echo -e "${RED}✘ 解析 WARP 账户失败（无可用地址）${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}✔ WARP 账户申请成功！${PLAIN}"
    [[ -n "$W_V4" ]] && echo -e "   IPv4: ${W_V4}"
    [[ -n "$W_V6" ]] && echo -e "   IPv6: ${W_V6}"
    return 0
}

# ========== 添加 WARP 出站 ==========
add_warp_outbound_singbox() {
    # 检查必要变量
    if [[ -z "$W_V4" && -z "$W_V6" ]] || [[ -z "$W_RES_JSON" || -z "$W_PRIV" ]]; then
        echo -e "${RED}✘ 错误：缺少 WARP 账户数据，请先运行注册函数。${PLAIN}"
        return 1
    fi

    echo -e "${YELLOW}正在向 sing-box 配置添加 WARP 出站...${PLAIN}"

    # 构建带 CIDR 后缀的地址数组
    local addresses_json="["
    [[ -n "$W_V4" ]] && addresses_json+="\"${W_V4}/32\""
    [[ -n "$W_V4" && -n "$W_V6" ]] && addresses_json+=","
    [[ -n "$W_V6" ]] && addresses_json+="\"${W_V6}/128\""
    addresses_json+="]"

    # 使用 jq 注入正确格式的出站（peers 结构）
    jq --arg priv "$W_PRIV" \
       --argjson addresses "$addresses_json" \
       --argjson res "$W_RES_JSON" \
       '.outbounds += [{
            "type": "wireguard",
            "tag": "warp-out",
            "local_address": $addresses,
            "private_key": $priv,
            "peers": [{
                "address": "engage.cloudflareclient.com",
                "port": 2408,
                "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                "allowed_ips": ["0.0.0.0/0", "::/0"],
                "reserved": $res
            }],
            "mtu": 1280
        }]' "$CONFIG_FILE" > "/tmp/sing-box-tmp-$$.json"

    if [[ $? -eq 0 ]]; then
        if save_and_restart "/tmp/sing-box-tmp-$$.json"; then
            echo -e "${GREEN}✔ WARP 出站配置成功！${PLAIN}"
            return 0
        else
            echo -e "${RED}✘ 写入或重启失败。${PLAIN}"
        fi
    else
        echo -e "${RED}✘ jq 处理失败，请检查配置文件 JSON 格式。${PLAIN}"
    fi
    return 1
}

toggle_warp() {
    clear
    echo -e "${YELLOW}--- WARP 全局开关管理 ---${PLAIN}"

    # ---------- 1. 环境检查 ----------
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}配置文件 $CONFIG_FILE 不存在！${PLAIN}"
        return 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}配置文件 JSON 格式错误，请检查 $CONFIG_FILE${PLAIN}"
        return 1
    fi

    # 判断写权限，决定是否使用 sudo 写回（临时文件在 /tmp 不需要 sudo）
    local SUDO=""
    if [[ ! -w "$CONFIG_FILE" ]]; then
        if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
            SUDO="sudo"
        else
            echo -e "${RED}没有写入 $CONFIG_FILE 的权限，请使用 root 或配置 sudo${PLAIN}"
            return 1
        fi
    fi

    # ---------- 2. 检查 warp-out 出站 ----------
    local has_warp
    has_warp=$(jq -e '.outbounds[]? | select(.tag == "warp-out")' "$CONFIG_FILE" 2>/dev/null)
    if [[ -z "$has_warp" ]]; then
        echo -e "${YELLOW}未检测到 WARP 配置，正在初始化申请...${PLAIN}"
        if ! add_warp_outbound; then
            echo -e "${RED}初始化 WARP 失败，退出。${PLAIN}"
            return 1
        fi
    fi

    # ---------- 3. 读取当前默认出站 ----------
    local current_final
    current_final=$(jq -r '.route.final // "direct"' "$CONFIG_FILE")

    # ---------- 4. 交互开关 ----------
    if [[ "$current_final" == "warp-out" ]]; then
        echo -e "当前状态: ${GREEN}已开启 (全局走 WARP)${PLAIN}"
        read -p "是否关闭 WARP 全局代理？(y/n): " choice
        if [[ "$choice" == "y" ]]; then
            # 备份
            $SUDO cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
            local tmp_cfg="/tmp/sing-box-tmp-$$.json"
            # 生成新配置到临时文件
            if jq '.route.final = "direct"' "$CONFIG_FILE" > "$tmp_cfg"; then
                if save_and_restart "$tmp_cfg"; then
                    echo -e "${GREEN}✔ WARP 已关闭，流量直连 (direct)。${PLAIN}"
                else
                    echo -e "${RED}✘ 重启或配置检查失败，备份已保留。${PLAIN}"
                fi
            else
                echo -e "${RED}✘ 生成新配置失败。${PLAIN}"
                rm -f "$tmp_cfg"
            fi
        fi
    else
        echo -e "当前状态: ${RED}已关闭 (流量直连)${PLAIN}"
        echo -e "${CYAN}注：开启后，所有节点流量都将通过 WARP 落地出口。${PLAIN}"
        read -p "是否开启 WARP 全局代理？(y/n): " choice
        if [[ "$choice" == "y" ]]; then
            $SUDO cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
            local tmp_cfg="/tmp/sing-box-tmp-$$.json"
            if jq '.route.final = "warp-out"' "$CONFIG_FILE" > "$tmp_cfg"; then
                if save_and_restart "$tmp_cfg"; then
                    echo -e "${GREEN}✔ WARP 已开启，所有流量重定向至 warp-out。${PLAIN}"
                else
                    echo -e "${RED}✘ 重启或配置检查失败，备份已保留。${PLAIN}"
                fi
            else
                echo -e "${RED}✘ 生成新配置失败。${PLAIN}"
                rm -f "$tmp_cfg"
            fi
        fi
    fi

    pause 2>/dev/null || read -p "按回车键继续..."
}

update_all() {
    echo -e "${CYAN}请选择更新项:${PLAIN}"
    echo "1. 更新管理脚本 | 2. 更新 sing-box 内核 | 0. 返回"
    read -p "选择: " uc
    [[ "$uc" == "0" ]] && return
    if [ "$uc" == "1" ]; then
        curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb
        chmod +x /usr/local/bin/ssb
        echo -e "${GREEN}脚本更新完成${PLAIN}"
        exit 0
    else
        install_base
    fi
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
    echo -e "--- ${YELLOW}sing-box 综合管理脚本 (ssb)${PLAIN} ---"
    show_status
    echo "--------------------------------"
    echo "1. 安装 / 重装 sing-box"
    echo "2. 节点快速配置"
    echo "3. 配置/链接查看"
    echo "4. 链路管理（中转/落地/链式)"
    echo "5. 分流设置/管理"
    echo "6. 更新脚本或内核"
    echo "7. 备份 / 还原"
    echo "8. 开启 BBR 网络加速"
    echo "9. 申请 SSL 域名证书 (ACME)"
    echo "10. 添加出站/用于自动/负载"
    echo "11 更改配置/删除"
    echo "12 WARP注册"
    echo "13 一键开关WARP"
    echo "14 配置WARP出站"
    echo "77. 彻底卸载"
    echo -e " \033[1;32m  [88]  重启 sing-box 服务\033[0m"
    echo "0. 退出"
    read -p "选择 [0-88]: " num
    
    case "$num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy;;
        5) manage_routing ;;
        6) update_all ;;
        7) backup_restore ;;
        8) enable_bbr ;;
        9) apply_cert ;;
        10) add_outbound ;;
        11) edit_node ;;
        12) register_warp_account ;;
        13) toggle_warp ;;
        14) add_warp_outbound ;;
        77)
            read -p "确定卸载吗？此操作不可逆！(y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                systemctl stop sing-box
                systemctl disable sing-box
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload
                rm -f /usr/local/bin/ssb /usr/local/bin/sing-box
                rm -rf /etc/sing-box
                echo -e "${GREEN}sing-box 及相关配置已彻底卸载。${PLAIN}"
                exit 0
            fi
            ;;
        88)
            echo -e "${YELLOW}正在重启服务...${PLAIN}"
            systemctl restart sing-box
            sleep 1
            ;;
        0) 
            echo -e "${GREEN}脚本已退出。${PLAIN}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}输入错误，请重新选择${PLAIN}"
            sleep 1
            ;;
    esac
done
