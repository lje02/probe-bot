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
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# --- 辅助工具 ---
pause() {
    echo ""
    read -p "操作完成，按回车键继续..."
}

# --- 依赖函数：WARP 自动注册 ---
register_warp_account() {
    W_PRIV="" W_V4="" W_V6="" W_RES_JSON=""
    
    # 检查并安装依赖
    local need_install=0
    for dep in wireguard-tools jq curl bsdmainutils; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            need_install=1
            break
        fi
    done

    if [ "$need_install" -eq 1 ]; then
        echo -e "${YELLOW}正在安装必要依赖...${PLAIN}"
        apt update && apt install -y wireguard-tools jq curl bsdmainutils
    fi

    echo -e "${CYAN}正在通过 Cloudflare API 申请 WARP 账户...${PLAIN}"
    
    local priv=$(wg genkey)
    local pub=$(echo "$priv" | wg pubkey)
    
    local response=$(curl -s --connect-timeout 10 -X POST "https://api.cloudflareclient.com/v0a2445/reg" \
        -H "Content-Type: application/json" \
        -d "{\"install_id\":\"\",\"tos\":\"$(date -u +%FT%T.000Z)\",\"key\":\"$pub\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")

    if [[ "$response" != *"token"* ]]; then
        echo -e "${RED}✘ WARP 注册失败${PLAIN}"
        return 1
    fi

    W_PRIV="$priv"
    W_V4=$(echo "$response" | jq -r '.config.interface.address.v4')
    W_V6=$(echo "$response" | jq -r '.config.interface.address.v6')
    W_RES_JSON=$(echo "$response" | jq -r '.config.clientId' | base64 -d | hexdump -v -e '/1 "%d,"' | sed 's/,$//' | awk '{print "["$0"]"}')

    if [[ -z "$W_V4" || "$W_V4" == "null" ]]; then
        echo -e "${RED}✘ 解析 WARP 账户失败${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}✔ WARP 账户申请成功！${PLAIN}"
    return 0
}

# 原子化写入配置并进行语法检查
save_and_restart() {
    if [[ ! -f tmp.json ]]; then
        echo -e "${RED}错误: 临时配置文件生成失败。${PLAIN}"
        return 1
    fi

    if $SB_BIN check -c tmp.json > /dev/null 2>&1; then
        mv tmp.json "$CONFIG_FILE"
        systemctl restart sing-box
        return 0
    else
        echo -e "${RED}✘ 配置语法检查失败，请检查参数设置。旧配置已保留。${PLAIN}"
        rm -f tmp.json
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

apply_cert() {
    echo -e "${YELLOW}--- ACME 域名证书申请 ---${PLAIN}"
    read -p "请输入解析到本机的域名: " domain
    [[ -z "$domain" ]] && echo -e "${RED}域名不能为空${PLAIN}" && pause && return

    apt update && apt install -y socat cron uuid-runtime
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
        source ~/.bashrc
    fi

    echo -e "${YELLOW}正在尝试申请证书...${PLAIN}"
    systemctl stop sing-box 2>/dev/null
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --server letsencrypt
    
    if [ $? -eq 0 ]; then
        local target_dir="$CERT_DIR/$domain"
        mkdir -p "$target_dir"
        ~/.acme.sh/acme.sh --install-cert -d "$domain" \
            --key-file "$target_dir/server.key" \
            --fullchain-file "$target_dir/server.crt"
        echo -e "${GREEN}✔ 证书安装成功！路径: $target_dir${PLAIN}"
    else
        echo -e "${RED}✘ 申请失败，请确认 80 端口未被占用且域名解析正确。${PLAIN}"
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
    echo -e "${YELLOW}--- 管理节点配置 ---${PLAIN}"
    local count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return

    local TAG=$(jq -r ".inbounds[$(($idx-1))].tag" "$CONFIG_FILE")
    echo -e "\n1. 查看详情/链接 | 2. 修改端口 | 3. 删除配置"
    read -p "选择操作: " op
    case $op in
        1)
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
                case $TYPE in
                    vless)
                        local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                        local SNI=$(echo "$CONF" | jq -r '.tls.server_name')
                        local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                        if [[ -n "$SID" ]]; then
                            echo -e "${RED}Reality 节点的公钥不存储在配置文件中，无法生成完整链接。${PLAIN}"
                        else
                            local WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
                            echo -e "${BLUE}vless://$UUID@$IP:$PORT?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$TAG${PLAIN}"
                        fi
                        ;;
                    tuic)
                        local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                        local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                        echo -e "${BLUE}tuic://$UUID:$PASS@$IP:$PORT?congestion_control=bbr#$TAG${PLAIN}"
                        ;;
                    hysteria2)
                        local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                        echo -e "${BLUE}hysteria2://$PASS@$IP:$PORT#$TAG${PLAIN}"
                        ;;
                    shadowsocks)
                        local METHOD=$(echo "$CONF" | jq -r .method); local PASS=$(echo "$CONF" | jq -r .password)
                        local SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
                        echo -e "${BLUE}ss://$SS_BASE64@$IP:$PORT#$TAG${PLAIN}"
                        ;;
                esac
            fi
            pause
            ;;
        2)
            read -p "新端口: " NP
            jq ".inbounds[$(($idx-1))].listen_port = ($NP|tonumber)" "$CONFIG_FILE" > tmp.json
            if save_and_restart; then
                echo -e "${GREEN}端口已更新为 $NP。注意：原持久化链接中的端口信息已过期。${PLAIN}"
            fi
            pause
            ;;
        3)
            jq "del(.inbounds[$(($idx-1))])" "$CONFIG_FILE" > tmp.json
            if save_and_restart; then
                rm -f "$LINK_DIR/${TAG}.link"
                echo -e "${GREEN}配置及链接文件已删除${PLAIN}"
            fi
            pause
            ;;
    esac
}

# 简单的解析函数：支持 ss:// 和 socks5://
parse_proxy_link() {
    local link=$1
    R_ADDR="" R_PORT="" R_METHOD="" R_PASS="" R_USER=""
    
    if [[ "$link" =~ ^ss:// ]]; then
        # 去掉协议头和后缀
        local content=$(echo "${link#ss://}" | cut -d'#' -f1)
        
        # 处理可能的 SIP002 格式 (BASE64@HOST:PORT)
        if [[ "$content" == *"@"* ]]; then
            local user_info_b64=$(echo "$content" | cut -d'@' -f1)
            local server_info=$(echo "$content" | cut -d'@' -f2)
            
            # 解码用户信息 (method:password)
            local user_info=$(echo "$user_info_b64" | base64 -d 2>/dev/null)
            R_METHOD=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2)
            
            R_ADDR=$(echo "$server_info" | cut -d':' -f1)
            R_PORT=$(echo "$server_info" | cut -d':' -f2)
            hop_type=1
        fi
    elif [[ "$link" =~ ^socks5:// ]]; then
        # 格式: socks5://user:pass@host:port
        local content=${link#socks5://}
        if [[ "$content" == *"@"* ]]; then
            local user_info=$(echo "$content" | cut -d'@' -f1)
            local server_info=$(echo "$content" | cut -d'@' -f2)
            R_USER=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2)
            R_ADDR=$(echo "$server_info" | cut -d':' -f1)
            R_PORT=$(echo "$server_info" | cut -d':' -f2)
        else
            R_ADDR=$(echo "$content" | cut -d':' -f1)
            R_PORT=$(echo "$content" | cut -d':' -f2)
        fi
        hop_type=2
    fi
}

chain_proxy() {
    local cp_choice idx LOCAL_TAG RAW_LINK R_ADDR R_PORT R_METHOD R_PASS R_USER \
          hop_type OUT_TAG OUT_JSON CURRENT_OUTBOUND

    while true; do
        clear
        echo -e "${YELLOW}--- 链式代理管理 (支持多级跳转 & WARP) ---${PLAIN}"
        echo "1. 添加/追加跳转节点 (SS/Socks5/WARP)"
        echo "2. 查看当前转发链路"
        echo "3. 清空特定入站规则"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " cp_choice

        case $cp_choice in
            1)
                # --- 1. 选择本地入站 ---
                echo -e "\n${YELLOW}选择本地入站节点:${PLAIN}"
                local in_count=$(jq '.inbounds | length' "$CONFIG_FILE")
                [[ "$in_count" == "0" ]] && echo "无入站节点" && sleep 1 && continue
                jq -r '.inbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                read -p "选择序号: " idx
                [[ -z "$idx" ]] && continue
                LOCAL_TAG=$(jq -r ".inbounds[$((idx-1))].tag" "$CONFIG_FILE")
                
                # 检测该入站当前是否已有出口，以便实现追加 (Detour)
                CURRENT_OUTBOUND=$(jq -r --arg itag "$LOCAL_TAG" '.route.rules[] | select(.inbound[0] == $itag) | .outbound' "$CONFIG_FILE" | head -n 1)

                # --- 2. 获取新节点类型 ---
                echo -e "\n${CYAN}选择新节点类型:${PLAIN}"
                echo "1. 粘贴分享链接 (ss://, socks5://)"
                echo "2. 手动输入 SS/Socks5"
                echo "3. 自动注册 Cloudflare WARP"
                read -p "选择: " type_choice

                OUT_TAG="hop-$(date +%s)"
                
                if [[ "$type_choice" == "1" ]]; then
                    read -p "请输入链接: " RAW_LINK
                    parse_proxy_link "$RAW_LINK"
                elif [[ "$type_choice" == "2" ]]; then
                    read -p "协议 (1.SS 2.Socks5): " hop_type
                    read -p "地址: " R_ADDR
                    read -p "端口: " R_PORT
                    if [[ "$hop_type" == "1" ]]; then
                        read -p "加密: " R_METHOD; [[ -z "$R_METHOD" ]] && R_METHOD="aes-128-gcm"
                        read -p "密码: " R_PASS
                    else
                        read -p "用户名: " R_USER; read -p "密码: " R_PASS
                    fi
                elif [[ "$type_choice" == "3" ]]; then
                    # 调用之前定义的 WARP 注册函数
                    if register_warp_account; then
                        # 构造 WARP JSON，包含 detour 到当前节点
                        OUT_JSON=$(jq -n \
                            --arg t "$OUT_TAG" \
                            --arg priv "$W_PRIV" \
                            --arg v4 "$W_V4" \
                            --arg v6 "$W_V6" \
                            --arg d "$CURRENT_OUTBOUND" \
                            --argjson res "$W_RES_JSON" \
                            '{
                                "type": "wireguard",
                                "tag": $t,
                                "server": "engage.cloudflareclient.com",
                                "server_port": 2408,
                                "local_address": [$v4, $v6],
                                "private_key": $priv,
                                "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                                "reserved": $res,
                                "mtu": 1280
                            } + (if $d != "" and $d != "null" then {detour: $d} else {} end)')
                    else
                        sleep 2; continue
                    fi
                fi

                # --- 3. 构造普通节点 JSON (如果不是 WARP) ---
                if [[ "$type_choice" != "3" ]]; then
                    if [[ "$hop_type" == "1" || "$RAW_LINK" == ss://* ]]; then
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" --arg d "$CURRENT_OUTBOUND" \
                            '{type: "shadowsocks", tag: $t, server: $s, server_port: ($p|tonumber), method: $m, password: $pass} + (if $d != "" and $d != "null" then {detour: $d} else {} end)')
                    else
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg d "$CURRENT_OUTBOUND" \
                            '{type: "socks", tag: $t, server: $s, server_port: ($p|tonumber), version: "5"} + (if $d != "" and $d != "null" then {detour: $d} else {} end)')
                        [[ -n "$R_USER" ]] && OUT_JSON=$(echo "$OUT_JSON" | jq --arg u "$R_USER" --arg p "$R_PASS" '. + {username: $u, password: $p}')
                    fi
                fi

                # --- 4. 写入并重启 ---
                jq --argjson obj "$OUT_JSON" --arg itag "$LOCAL_TAG" --arg otag "$OUT_TAG" '
                    .outbounds += [$obj] |
                    del(.route.rules[] | select(.inbound[0] == $itag)) |
                    .route.rules = [{ "inbound": [$itag], "outbound": $otag }] + .route.rules
                ' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
                
                echo -e "${GREEN}✔ 链路已更新 (追加了新节点)${PLAIN}"
                save_and_restart
                sleep 2
                ;;

            2)
                # --- 查看链路 ---
                echo -e "\n${YELLOW}当前活跃转发链路:${PLAIN}"
                echo "------------------------------------------------"
                local rules_count=$(jq '.route.rules | length' "$CONFIG_FILE")
                local found=0
                
                for ((i=0; i<rules_count; i++)); do
                    local in_tag=$(jq -r ".route.rules[$i].inbound[0] // empty" "$CONFIG_FILE")
                    for ((i=0; i<rules_count; i++)); do
                    local in_tag=$(jq -r ".route.rules[$i].inbound[0] // empty" "$CONFIG_FILE")
                    local out_tag=$(jq -r ".route.rules[$i].outbound // empty" "$CONFIG_FILE")
                    
                    if [[ -n "$in_tag" && "$out_tag" != "direct" && "$out_tag" != "block" ]]; then
                        found=1
                        local path="$in_tag"
                        local next="$out_tag"
                        
                        while [[ -n "$next" && "$next" != "null" ]]; do
                            local srv=$(jq -r --arg t "$next" '.outbounds[] | select(.tag == $t) | "\(.server):\(.server_port)"' "$CONFIG_FILE")
                            [[ -z "$srv" ]] && srv="内置节点"
                            path="$path -> $next($srv)"
                            next=$(jq -r --arg t "$next" '.outbounds[] | select(.tag == $t) | .detour // empty' "$CONFIG_FILE")
                        done
                        echo -e "${CYAN}[规则]${PLAIN} $path -> 互联网"
                    fi
                done
                [[ $found -eq 0 ]] && echo "暂无自定义转发规则。"
                echo "------------------------------------------------"
                read -n 1 -s -r -p "按任意键返回菜单..."
                ;;

            3)
                # --- 清空规则 ---
                echo -e "\n${YELLOW}请选择要重置为直连的入站节点:${PLAIN}"
                local list=$(jq -r '.route.rules[] | select(.inbound != null) | .inbound[0]' "$CONFIG_FILE")
                if [[ -z "$list" ]]; then 
                    echo "没有发现转发规则。"
                else
                    echo "$list" | cat -n
                    read -p "选择序号: " del_idx
                    local DEL_IN_TAG=$(echo "$list" | sed -n "${del_idx}p")
                    
                    if [[ -n "$DEL_IN_TAG" ]]; then
                        local tags_to_del=$(jq -r --arg itag "$DEL_IN_TAG" '
                            def get_chain(t): .outbounds[] | select(.tag == t) | .tag, (if .detour then get_chain(.detour) else empty end);
                            (.route.rules[] | select(.inbound[0] == $itag) | .outbound) as $start |
                            get_chain($start)
                        ' "$CONFIG_FILE")

                        jq --arg itag "$DEL_IN_TAG" --argjson tags "$(echo "$tags_to_del" | jq -R . | jq -s .)" '
                            del(.route.rules[] | select(.inbound[0] == $itag)) |
                            del(.outbounds[] | select(.tag as $t | $tags | contains([$t])))
                        ' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
                        
                        (systemctl restart sing-box &)
                        echo -e "${GREEN}✔ 链路已清空。${PLAIN}"
                    fi
                fi
                sleep 1
                read -n 1 -s -r -p "按任意键继续..."
                ;;

            0)
                return 0 # 正常返回主菜单
                ;;
            *)
                echo -e "${RED}无效选择${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# --- 分流管理 ---
manage_routing() {
    local rt_choice idx OUT_TAG MATCH_TYPE MATCH_VALUE RULE_JSON \
          RAW_LINK R_ADDR R_PORT R_METHOD R_PASS R_USER hop_type

    while true; do
        # 每次循环重置变量，防止污染
        R_ADDR="" R_PORT="" R_METHOD="" R_PASS="" R_USER="" RAW_LINK=""
        
        clear
        echo -e "${YELLOW}--- 通用分流管理 (Split Tunneling) ---${PLAIN}"
        echo "1. 添加分流规则"
        echo "2. 查看当前所有分流规则"
        echo "3. 删除特定分流规则"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " rt_choice

        case $rt_choice in
            1)
                echo -e "\n${YELLOW}该流量应从哪个节点发出？${PLAIN}"
                echo "1. 使用现有出站"
                echo "2. 手动添加/通过链接添加新节点 (SS/Socks5)"
                echo "3. 自动申请并添加 Cloudflare WARP 节点"
                read -p "选择: " out_src_choice

                OUT_TAG=""

                if [[ "$out_src_choice" == "1" ]]; then
                    echo -e "\n${CYAN}当前可用出站列表:${PLAIN}"
                    local ob_count=$(jq '.outbounds | length' "$CONFIG_FILE")
                    [[ "$ob_count" == "0" ]] && { echo "无节点"; sleep 2; continue; }
                    jq -r '.outbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                    read -p "选择序号: " idx
                    [[ -z "$idx" ]] && continue
                    OUT_TAG=$(jq -r ".outbounds[$((idx-1))].tag" "$CONFIG_FILE")

                elif [[ "$out_src_choice" == "2" ]]; then
                    # 修正点 1: 修正 read 命令
                    read -p "请输入分享链接 (或直接回车进入手动模式): " RAW_LINK
                    if [[ -n "$RAW_LINK" ]]; then
                        parse_proxy_link "$RAW_LINK"
                    else
                        read -p "协议 (1.SS 2.Socks5): " hop_type
                        read -p "地址: " R_ADDR
                        read -p "端口: " R_PORT
                        if [[ "$hop_type" == "1" ]]; then
                            read -p "加密方法: " R_METHOD; [[ -z "$R_METHOD" ]] && R_METHOD="aes-128-gcm"
                            read -p "密码: " R_PASS
                        else
                            read -p "用户名 (可选): " R_USER; read -p "密码 (可选): " R_PASS
                        fi
                    fi

                    [[ -z "$R_ADDR" ]] && { echo "信息不完整"; sleep 1; continue; }
                    
                    # 修正点 2: 统一前缀名
                    OUT_TAG="split-node-$(date +%s)"
                    local NEW_OUT_JSON=""
                    if [[ "$hop_type" == "1" || "$RAW_LINK" == ss://* ]]; then
                        NEW_OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" \
                            '{type: "shadowsocks", tag: $t, server: $s, server_port: ($p|tonumber), method: $m, password: $pass}')
                    else
                        NEW_OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" \
                            '{type: "socks", tag: $t, server: $s, server_port: ($p|tonumber), version: "5"}')
                        [[ -n "$R_USER" ]] && NEW_OUT_JSON=$(echo "$NEW_OUT_JSON" | jq --arg u "$R_USER" --arg p "$R_PASS" '. + {username: $u, password: $p}')
                    fi
                    # 修正点 3: 必须 mv 覆盖
                    jq --argjson obj "$NEW_OUT_JSON" '.outbounds += [$obj]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

                elif [[ "$out_src_choice" == "3" ]]; then
                    if register_warp_account; then
                        OUT_TAG="split-node-warp-$(date +%s)"
                        local WARP_JSON=$(jq -n \
                            --arg t "$OUT_TAG" --arg priv "$W_PRIV" --arg v4 "$W_V4" --arg v6 "$W_V6" --argjson res "$W_RES_JSON" \
                            '{type: "wireguard", tag: $t, server: "engage.cloudflareclient.com", server_port: 2408, local_address: [$v4, $v6], private_key: $priv, peer_public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", reserved: $res, mtu: 1280}')
                        jq --argjson obj "$WARP_JSON" '.outbounds += [$obj]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
                    else
                        sleep 2; continue
                    fi
                fi

                # --- 第二阶段：绑定匹配规则 ---
                if [[ -z "$OUT_TAG" ]]; then
                    echo -e "${RED}✘ 节点获取失败${PLAIN}"; sleep 2; continue
                fi

                echo -e "\n${CYAN}>> 节点 [$OUT_TAG] 已就绪，设置分流规则:${PLAIN}"
                echo "1. 域名后缀 (如: google.com)"
                echo "2. 域名关键字 (如: netflix)"
                echo "3. IP 段 (如: 91.108.4.0/22)"
                read -p "选择: " mt_idx
                case $mt_idx in
                    1) MATCH_TYPE="domain_suffix";;
                    2) MATCH_TYPE="domain_keyword";;
                    3) MATCH_TYPE="ip_cidr";;
                    *) continue;;
                esac

                read -p "请输入匹配值 (多个用逗号隔开): " MATCH_VALUE
                [[ -z "$MATCH_VALUE" ]] && continue

                local val_json=$(echo "$MATCH_VALUE" | jq -R 'split(",")' | jq -c '.')
                RULE_JSON=$(jq -n --arg mt "$MATCH_TYPE" --arg ot "$OUT_TAG" --argjson mv "$val_json" '{"\($mt)": $mv, "outbound": $ot}')

                jq --argjson rule "$RULE_JSON" '.route.rules = [$rule] + .route.rules' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
                save_and_restart && echo -e "${GREEN}✔ 分流规则已生效！${PLAIN}"
                sleep 2
                ;;

            2)
                # --- 查看逻辑 ---
                echo -e "\n${YELLOW}当前自定义路由规则:${PLAIN}"
                echo "------------------------------------------------"
                jq -r '.route.rules[] | select(.inbound == null) | 
                    "[\(.outbound)] <- " + (if .domain_suffix then "后缀:\(.domain_suffix)" elif .domain_keyword then "关键字:\(.domain_keyword)" elif .ip_cidr then "IP段:\(.ip_cidr)" else "其他" end)' "$CONFIG_FILE" | cat -n
                echo "------------------------------------------------"
                read -n 1 -s -r -p "按任意键返回..."
                ;;

            3)
                # --- 删除逻辑 ---
                echo -e "\n${YELLOW}选择要删除的规则序号:${PLAIN}"
                # 提取非入站绑定的规则
                local rules_list=$(jq -c '.route.rules[] | select(.inbound == null)' "$CONFIG_FILE")
                [[ -z "$rules_list" ]] && { echo "无分流规则"; sleep 1; continue; }
                
                # 打印列表
                echo "$rules_list" | jq -r '(.outbound) + " (" + (if .domain_suffix then "后缀" elif .domain_keyword then "关键字" elif .ip_cidr then "IP段" else "其他" end) + ")"' | cat -n
                read -p "序号: " del_idx
                
                # 校验输入是否为数字以及是否在范围内
                local total=$(echo "$rules_list" | wc -l)
                if [[ ! "$del_idx" =~ ^[0-9]+$ ]] || [[ "$del_idx" -lt 1 ]] || [[ "$del_idx" -gt "$total" ]]; then
                    echo -e "${RED}无效序号${PLAIN}"; sleep 1; continue
                fi

                local target_rule=$(echo "$rules_list" | sed -n "${del_idx}p")
                local target_tag=$(echo "$target_rule" | jq -r .outbound)

                # 执行删除操作
                jq --argjson tr "$target_rule" --arg otag "$target_tag" '
                    del(.route.rules[] | select(. == $tr)) |
                    if ($otag | startswith("split-node-")) then 
                        del(.outbounds[] | select(.tag == $otag)) 
                    else . end
                ' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
                
                save_and_restart && echo -e "${GREEN}✔ 规则及相关临时节点已清理${PLAIN}"
                sleep 1
                ;;
            0) return ;;
        esac
    done
}

update_all() {
    auto_backup
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
    echo "2. 节点配置 (VLESS/TUIC/Hy2/SS/Socks)"
    echo "3. 配置管理 (查看/修改端口/删除)"
    echo "4. 链式代理设置/管理"
    echo "5. 分流规则设置/管理"
    echo "6. 更新脚本或内核"
    echo "7. 备份 / 还原"
    echo "8. 开启 BBR 网络加速"
    echo "9. 申请 SSL 域名证书 (ACME)"
    echo "77. 彻底卸载"
    echo -e " \033[1;32m  [88]   重启 sing-box 服务\033[0m"
    echo "0. 退出"
    read -p "选择 [0-88]: " num
    
    case "$num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy ;;
        5) manage_routing ;;
        6) update_all ;;
        7) backup_restore ;;
        8) enable_bbr ;;
        9) apply_cert ;;
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
