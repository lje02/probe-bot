#!/bin/bash

# ==========================================
# sing-box 一键管理脚本 (快捷方式: ssb)
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
    if [ ! -f "$CONFIG_FILE" ]; then
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
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
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
    echo -e "${GREEN}安装完成！快捷命令: ssb${PLAIN}"
}

add_node() {
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS/Reality"
    echo "2. Shadowsocks"
    echo "3. Socks5"
    echo "4. 返回"
    read -p "选择: " choice

    IP=$(get_ip)
    case $choice in
        1)
            # 兼容性生成
            UUID=$($SB_BIN generate uuid 2>/dev/null || uuidgen)
            KEYS=$($SB_BIN generate reality-keypair)
            PRIVATE=$(echo "$KEYS" | awk -F': ' '/Private/ {print $2}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS" | awk -F': ' '/Public/ {print $2}' | tr -d '[:space:]')
            SHORT_ID=$(openssl rand -hex 8)
            
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            read -p "SNI (默认 www.microsoft.com): " SNI; SNI=${SNI:-"www.microsoft.com"}

            if [[ -z "$PRIVATE" ]]; then
                echo -e "${RED}错误: 无法获取 Reality 密钥，请检查 $SB_BIN generate reality-keypair 是否正常工作。${PLAIN}"
                return
            fi

            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg priv "$PRIVATE" --arg sid "$SHORT_ID" \
            '.inbounds += [{"type":"vless","tag":"vless-reality","listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#VLESS-Reality"
            echo -e "${GREEN}添加成功！节点链接:${PLAIN}\n$LINK"
            ;;
        2)
            read -p "端口: " PORT
            PASS=$(openssl rand -base64 16)
            METHOD="2022-blake3-aes-128-gcm"
            jq --arg port "$PORT" --arg pass "$PASS" --arg method "$METHOD" \
            '.inbounds += [{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            echo -e "${GREEN}Shadowsocks 添加成功！密钥: $PASS${PLAIN}"
            ;;
        3)
            read -p "端口: " PORT
            read -p "用户名: " USER
            read -p "密码: " PASS
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" \
            '.inbounds += [{"type":"socks","tag":"socks-in","listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}]}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            echo -e "${GREEN}Socks5 添加成功。${PLAIN}"
            ;;
        *) return ;;
    esac
    systemctl restart sing-box
}

manage_configs() {
    echo -e "${YELLOW}--- 节点列表 ---${PLAIN}"
    jq -r '.inbounds[] | "Tag: \(.tag) | Port: \(.listen_port)"' $CONFIG_FILE | cat -n
    read -p "序号 (q退出): " idx
    [[ "$idx" == "q" ]] && return
    echo "1. 查看 | 2. 删除"
    read -p "选择: " op
    [[ "$op" == "1" ]] && jq ".inbounds[$(($idx-1))]" $CONFIG_FILE
    [[ "$op" == "2" ]] && jq "del(.inbounds[$(($idx-1))])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE && systemctl restart sing-box && echo "已删除"
}

update_manager() {
    echo "1. 更新脚本 | 2. 更新内核"
    read -p "选择: " uc
    if [ "$uc" == "1" ]; then
        curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
        echo "更新成功，请重新运行 ssb"
        exit 0
    else
        install_base
    fi
}

# 主菜单
while true; do
    clear
    echo -e "--- ${YELLOW}sing-box 管理脚本 (ssb)${PLAIN} ---"
    show_status
    echo "1. 安装/重装"
    echo "2. 添加节点"
    echo "3. 管理配置"
    echo "4. 更新"
    echo "5. 卸载"
    echo "0. 退出"
    read -p "选择: " menu_num
    case "$menu_num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) update_manager ;;
        5) 
            systemctl stop sing-box && systemctl disable sing-box
            rm -rf /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/ssb
            echo "已卸载"
            exit 0 ;;
        0) exit 0 ;;
    esac
    read -p "按回车继续..."
done
