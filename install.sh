#!/bin/bash

# ==========================================
# sing-box 一键管理脚本 (快捷方式: ssb)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
SB_BIN="/usr/local/bin/sing-box"
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

# --- 权限检查 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# --- 基础初始化 ---
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

# 一 & 十三：安装与快捷方式
install_base() {
    echo -e "${GREEN}>>> 正在同步系统环境并安装依赖...${PLAIN}"
    apt update -y && apt install -y curl jq openssl tar util-linux wget

    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    echo -e "${GREEN}>>> 正在下载 sing-box ${TAG} amd64...${PLAIN}"
    wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-amd64.tar.gz"
    tar -xzf sing-box.tar.gz
    mv sing-box-*/sing-box $SB_BIN
    chmod +x $SB_BIN
    rm -rf sing-box*

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$SB_BIN run -c $CONFIG_FILE
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

# 二：节点配置 (重点修复生成逻辑)
add_node() {
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS/Reality"
    echo "2. TUIC V5"
    echo "3. Hysteria 2"
    echo "4. Shadowsocks"
    echo "5. Socks5"
    echo "6. 返回"
    read -p "请选择: " choice

    IP=$(get_ip)
    case $choice in
        1)
            # 生成 UUID
            UUID=$($SB_BIN generate uuid 2>/dev/null)
            [[ -z "$UUID" ]] && UUID=$(uuidgen)
            
            # 生成密钥对
            KEYS=$($SB_BIN generate keypair)
            PRIVATE=$(echo "$KEYS" | awk '/Private key:/ {print $3}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS" | awk '/Public key:/ {print $3}' | tr -d '[:space:]')
            SHORT_ID=$(openssl rand -hex 8)
            
            read -p "请输入端口 (默认 443): " PORT; PORT=${PORT:-443}
            read -p "请输入 SNI (默认 www.microsoft.com): " SNI; SNI=${SNI:-"www.microsoft.com"}

            if [[ -z "$PRIVATE" || -z "$UUID" ]]; then
                echo -e "${RED}错误: 无法调用 $SB_BIN 生成密钥或 UUID。${PLAIN}"
                return
            fi

            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg priv "$PRIVATE" --arg sid "$SHORT_ID" \
            '.inbounds += [{"type":"vless","tag":"vless-reality","listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#VLESS-Reality"
            echo -e "${GREEN}添加成功！节点链接:${PLAIN}\n$LINK"
            ;;
        2|3)
            echo -e "${YELLOW}TUIC/Hysteria2 需要证书，请先确保证书路径正确后再手动修改 config.json。${PLAIN}"
            ;;
        4)
            read -p "请输入端口: " PORT
            # Shadowsocks 2022 推荐 16字节 Base64 密码
            PASS=$(openssl rand -base64 16)
            METHOD="2022-blake3-aes-128-gcm"
            
            jq --arg port "$PORT" --arg pass "$PASS" --arg method "$METHOD" \
            '.inbounds += [{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            SS_LINK="ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$PORT#Shadowsocks"
            echo -e "${GREEN}添加成功！节点链接:${PLAIN}\n$SS_LINK"
            ;;
        5)
            read -p "请输入端口: " PORT
            read -p "用户名: " USER
            read -p "密码: " PASS
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" \
            '.inbounds += [{"type":"socks","tag":"socks-in","listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}]}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            echo -e "${GREEN}Socks5 配置成功。${PLAIN}"
            ;;
        *) return ;;
    esac
    
    systemctl restart sing-box
    echo -e "${GREEN}服务已重启。${PLAIN}"
}

# 三、四、五：配置操作
manage_configs() {
    echo -e "${YELLOW}--- 当前节点列表 ---${PLAIN}"
    jq -r '.inbounds[] | "Tag: \(.tag) | Port: \(.listen_port)"' $CONFIG_FILE | cat -n
    read -p "请选择序号 (q退出): " idx
    [[ "$idx" == "q" ]] && return

    echo "1. 查看配置内容 | 2. 删除此配置 | 3. 修改配置信息"
    read -p "选择操作: " op
    case $op in
        1) jq ".inbounds[$(($idx-1))]" $CONFIG_FILE ;;
        2) jq "del(.inbounds[$(($idx-1))])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE ;;
        3) 
            echo "目前支持修改端口，其他项建议删除后重新添加。"
            read -p "新端口: " NEW_PORT
            jq ".inbounds[$(($idx-1))].listen_port = ($NEW_PORT|tonumber)" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            ;;
    esac
    systemctl restart sing-box
}

# 六：链式代理
chain_proxy() {
    read -p "外部出口节点 IP: " E_IP
    read -p "外部出口节点端口: " E_PORT
    # 添加入站到出站的路由映射 (简单示例)
    jq --arg ip "$E_IP" --arg port "$E_PORT" \
    '.outbounds += [{"type":"socks","tag":"proxy-out","server":$ip,"server_port":($port|tonumber)}] | .routing.rules = [{"inbound":["vless-reality","ss-in"],"outbound":"proxy-out"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    systemctl restart sing-box
}

# 更新、备份、卸载
update_all() {
    echo "1. 更新脚本 | 2. 更新 sing-box 内核"
    read -p "请选择: " uc
    if [ "$uc" == "1" ]; then
        curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
        echo "脚本更新完成。"
        exit 0
    else
        install_base
    fi
}

backup_restore() {
    echo "1. 备份配置 | 2. 还原配置"
    read -p "选择: " br
    [[ "$br" == "1" ]] && tar -czf /root/sb_backup.tar.gz /etc/sing-box/ && echo "备份成功: /root/sb_backup.tar.gz"
    [[ "$br" == "2" ]] && tar -xzf /root/sb_backup.tar.gz -C / && systemctl restart sing-box && echo "还原成功"
}

uninstall() {
    systemctl stop sing-box && systemctl disable sing-box
    rm -rf /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/ssb /etc/systemd/system/sing-box.service
    echo "卸载完成。"
    exit 0
}

# ================= 主菜单 =================
while true; do
    clear
    echo -e "====================================="
    echo -e "       ${GREEN}sing-box 管理脚本 (ssb)${PLAIN}       "
    echo -e "====================================="
    show_status
    echo -e "====================================="
    echo " 1. 安装/重装 sing-box"
    echo " 2. 一键配置节点 (VLESS/Reality, SS等)"
    echo " 3. 查看/修改/删除已有配置"
    echo " 4. 配置链式代理"
    echo " 5. 更新脚本或内核"
    echo " 6. 备份/还原配置"
    echo " 7. 彻底卸载"
    echo " 0. 退出"
    echo -e "====================================="
    read -p "选择 [0-7]: " menu_num

    case "$menu_num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy ;;
        5) update_all ;;
        6) backup_restore ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
    read -p "按回车继续..."
done
