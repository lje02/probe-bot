#!/bin/bash

# ==========================================
# sing-box 一键管理脚本 (快捷方式: ssb)
# 适配版本: 1.13.x | 包含全协议实现
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# --- 基础工具 ---
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

# --- 一、安装与快捷方式 ---
install_base() {
    echo -e "${GREEN}>>> 正在安装必要依赖...${PLAIN}"
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

# --- 二、节点配置 ---
add_node() {
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS + Reality"
    echo "2. TUIC V5"
    echo "3. Hysteria 2"
    echo "4. Shadowsocks (2022-blake3)"
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
            # TUIC 需要证书，这里生成自签名证书作为示例
            openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/tuic.key -out /etc/sing-box/tuic.crt -subj "/CN=bing.com" -days 3650
            
            jq --arg port "$PORT" --arg uuid "$UUID" --arg pass "$PASS" \
            '.inbounds += [{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"password":$pass}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/tuic.crt","key_path":"/etc/sing-box/tuic.key"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            echo -e "${GREEN}TUIC5 配置成功 (自签名证书)${PLAIN}"
            echo -e "链接示例: tuic://$UUID:$PASS@$IP:$PORT?congestion_control=bbr&alpn=h3#TUIC5"
            ;;
        3)
            read -p "端口: " PORT
            read -p "密码: " PASS
            openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt -subj "/CN=google.com" -days 3650
            
            jq --arg port "$PORT" --arg pass "$PASS" \
            '.inbounds += [{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":($port|tonumber),"users":[{"password":$pass}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/hy2.crt","key_path":"/etc/sing-box/hy2.key"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            echo -e "${GREEN}Hysteria2 配置成功${PLAIN}"
            echo -e "链接示例: hysteria2://$PASS@$IP:$PORT?insecure=1#Hy2"
            ;;
        4)
            read -p "端口: " PORT
            PASS=$(openssl rand -base64 16)
            METHOD="2022-blake3-aes-128-gcm"
            jq --arg port "$PORT" --arg pass "$PASS" --arg method "$METHOD" \
            '.inbounds += [{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
            echo -e "${GREEN}Shadowsocks 链接:${PLAIN}\nss://$SS_BASE64@$IP:$PORT#SS"
            ;;
        5)
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

# --- 三、四、五：配置管理 ---
manage_configs() {
    echo -e "${YELLOW}--- 节点列表 ---${PLAIN}"
    jq -r '.inbounds[] | "Tag: \(.tag) | Port: \(.listen_port)"' $CONFIG_FILE | cat -n
    read -p "请选择序号 (q退出): " idx
    [[ "$idx" == "q" ]] && return

    echo "1. 查看详情 | 2. 修改端口 | 3. 删除配置"
    read -p "选择操作: " op
    case $op in
        1) jq ".inbounds[$(($idx-1))]" $CONFIG_FILE ;;
        2) 
            read -p "新端口: " NP
            jq ".inbounds[$(($idx-1))].listen_port = ($NP|tonumber)" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            systemctl restart sing-box && echo "端口已更新" ;;
        3) 
            jq "del(.inbounds[$(($idx-1))])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            systemctl restart sing-box && echo "已删除" ;;
    esac
}

# --- 六：链式代理 ---
chain_proxy() {
    read -p "输入外部 Socks5/SS 地址: " E_IP
    read -p "输入外部端口: " E_PORT
    jq --arg ip "$E_IP" --arg port "$E_PORT" \
    '.outbounds += [{"type":"socks","tag":"chain-out","server":$ip,"server_port":($port|tonumber)}] | .routing.rules = [{"inbound":["vless-reality","ss-in"],"outbound":"chain-out"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    systemctl restart sing-box && echo "链式代理配置完成"
}

# --- 七、八、九：系统维护 ---
update_all() {
    echo "1. 更新脚本 | 2. 更新内核"
    read -p "选择: " uc
    if [ "$uc" == "1" ]; then
        curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
        echo "脚本更新完成" && exit 0
    else
        install_base
    fi
}

backup_restore() {
    echo "1. 备份 | 2. 还原"
    read -p "选择: " br
    [[ "$br" == "1" ]] && tar -czf /root/sb_bak.tar.gz /etc/sing-box/ && echo "备份成功: /root/sb_bak.tar.gz"
    [[ "$br" == "2" ]] && tar -xzf /root/sb_bak.tar.gz -C / && systemctl restart sing-box && echo "还原成功"
}

# --- 主菜单 ---
while true; do
    clear
    echo -e "--- ${YELLOW}sing-box 综合管理脚本 (ssb)${PLAIN} ---"
    show_status
    echo "--------------------------------"
    echo "1. 安装 / 重装 sing-box"
    echo "2. 节点配置 (添加 VLESS/TUIC/Hy2/SS/Socks)"
    echo "3. 管理配置 (查看/修改/删除)"
    echo "4. 链式代理设置"
    echo "5. 更新脚本或内核"
    echo "6. 备份 / 还原"
    echo "7. 彻底卸载"
    echo "0. 退出"
    read -p "选择 [0-7]: " num
    case "$num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy ;;
        5) update_all ;;
        6) backup_restore ;;
        7) 
            systemctl stop sing-box && systemctl disable sing-box
            rm -rf /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/ssb /etc/systemd/system/sing-box.service
            echo "已卸载" && exit 0 ;;
        0) exit 0 ;;
    esac
    read -p "按回车继续..."
done
