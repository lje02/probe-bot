#!/bin/bash

# ==========================================
# sing-box 一键管理脚本 (ssb) - 2026 增强版
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

init_config() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$CONFIG_FILE"
    fi
}

get_ip() {
    curl -sS -4 icanhazip.com || curl -sS -4 ifconfig.me
}

show_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box 状态: ${GREEN}[运行中]${PLAIN}"
    else
        echo -e "sing-box 状态: ${RED}[未运行/已停止]${PLAIN}"
    fi
}

install_base() {
    echo -e "${GREEN}>>> 正在同步系统环境并安装依赖...${PLAIN}"
    apt update -y && apt install -y curl jq openssl tar util-linux wget
    
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-amd64.tar.gz"
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
    cp "$0" /usr/local/bin/ssb
    chmod +x /usr/local/bin/ssb
    systemctl start sing-box
    echo -e "${GREEN}安装完成！输入 ssb 呼出菜单。${PLAIN}"
}

add_node() {
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS + Reality"
    echo "2. TUIC V5 (包含 insecure 提醒)"
    echo "3. Hysteria 2 (包含 insecure 提醒)"
    echo "4. Shadowsocks"
    echo "5. Socks5"
    echo "6. 返回"
    read -p "请选择: " choice

    IP=$(get_ip)
    case $choice in
        1)
            UUID=$($SB_BIN generate uuid 2>/dev/null || uuidgen)
            KEYS=$($SB_BIN generate reality-keypair)
            PRIVATE=$(echo "$KEYS" | awk -F': ' '/Private/ {print $2}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS" | awk -F': ' '/Public/ {print $2}' | tr -d '[:space:]')
            SHORT_ID=$(openssl rand -hex 8)
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            read -p "SNI (默认 www.microsoft.com): " SNI; SNI=${SNI:-"www.microsoft.com"}

            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg priv "$PRIVATE" --arg sid "$SHORT_ID" \
            '.inbounds += [{"type":"vless","tag":"vless-reality","listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            echo -e "${GREEN}节点链接:${PLAIN}\nvless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#VLESS-Reality"
            ;;
        2)
            UUID=$($SB_BIN generate uuid 2>/dev/null || uuidgen)
            read -p "端口: " PORT
            read -p "密码: " PASS
            openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt -subj "/CN=bing.com" -days 3650
            
            jq --arg port "$PORT" --arg uuid "$UUID" --arg pass "$PASS" \
            '.inbounds += [{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"password":$pass}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/tuic.crt","key_path":"/etc/sing-box/tuic.key"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            echo -e "${RED}！！！重要：TUIC5 使用自签名证书，请在客户端 TLS 设置中开启 [允许不安全连接 / Insecure]！！！${PLAIN}"
            echo -e "${GREEN}客户端配置建议 (JSON):${PLAIN}"
            echo "{
  \"type\": \"tuic\",
  \"server\": \"$IP\",
  \"server_port\": $PORT,
  \"uuid\": \"$UUID\",
  \"password\": \"$PASS\",
  \"tls\": { \"enabled\": true, \"server_name\": \"bing.com\", \"insecure\": true, \"alpn\": [\"h3\"] }
}"
            ;;
        3)
            read -p "端口: " PORT
            read -p "密码: " PASS
            openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt -subj "/CN=google.com" -days 3650
            
            jq --arg port "$PORT" --arg pass "$PASS" \
            '.inbounds += [{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":($port|tonumber),"users":[{"password":$pass}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/hy2.crt","key_path":"/etc/sing-box/hy2.key"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            echo -e "${RED}！！！重要：Hysteria2 使用自签名证书，请在客户端开启 [允许不安全连接 / Insecure]！！！${PLAIN}"
            echo -e "${GREEN}客户端配置建议 (JSON):${PLAIN}"
            echo "hysteria2://$PASS@$IP:$PORT?insecure=1&sni=google.com#Hy2"
            ;;
        4)
            read -p "端口: " PORT
            PASS=$(openssl rand -base64 16)
            METHOD="2022-blake3-aes-128-gcm"
            jq --arg port "$PORT" --arg pass "$PASS" --arg method "$METHOD" \
            '.inbounds += [{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
            echo -e "${GREEN}SS 链接:${PLAIN}\nss://$SS_BASE64@$IP:$PORT#SS"
            ;;
        5)
            read -p "端口: " PORT
            read -p "用户名: " USER; read -p "密码: " PASS
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" \
            '.inbounds += [{"type":"socks","tag":"socks-in","listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}]}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            echo -e "${GREEN}Socks5 已添加${PLAIN}"
            ;;
        *) return ;;
    esac
    systemctl restart sing-box
}

manage_configs() {
    echo -e "${YELLOW}--- 节点列表 ---${PLAIN}"
    jq -r '.inbounds[] | "Tag: \(.tag) | Port: \(.listen_port)"' $CONFIG_FILE | cat -n
    read -p "选择序号: " idx
    [[ -z "$idx" ]] && return
    echo "1. 查看详情 | 2. 删除"
    read -p "选择: " op
    [[ "$op" == "1" ]] && jq ".inbounds[$(($idx-1))]" $CONFIG_FILE
    [[ "$op" == "2" ]] && jq "del(.inbounds[$(($idx-1))])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE && systemctl restart sing-box
}

# ... (其余 update_all, backup_restore 逻辑保持不变) ...

while true; do
    clear
    echo -e "--- ${YELLOW}sing-box 综合管理 (ssb)${PLAIN} ---"
    show_status
    echo "1. 安装/重装 | 2. 添加节点 | 3. 管理配置 | 4. 更新 | 5. 卸载 | 0. 退出"
    read -p "选择: " num
    case "$num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb && echo "更新成功" && exit 0 ;;
        5) systemctl stop sing-box && rm -rf /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/ssb && echo "已卸载" && exit 0 ;;
        0) exit 0 ;;
    esac
    read -p "回车继续..."
done
