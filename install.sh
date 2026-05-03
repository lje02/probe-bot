#!/bin/bash

# ==========================================
# sing-box 一键管理脚本 (快捷方式: ssb)
# 无 Git 依赖版 - 适配 https://github.com/lje02/sing
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 配置路径
CONFIG_FILE="/etc/sing-box/config.json"
# 注意：请确保下方分支名 (main) 与文件名 (install.sh) 与你仓库一致
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

# --- 权限检查 ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

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

# 十一：显示运行状态
show_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box 状态: ${GREEN}[运行中]${PLAIN}"
    else
        echo -e "sing-box 状态: ${RED}[未运行/已停止]${PLAIN}"
    fi
}

# 一 & 十三：安装与快捷方式
install_base() {
    echo -e "${GREEN}>>> 正在安装必要依赖 (curl, jq, openssl, util-linux)...${PLAIN}"
    apt update -y && apt install -y curl jq openssl tar util-linux

    # 获取最新内核版本
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64) SB_ARCH="amd64" ;;
        arm64) SB_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    echo -e "${GREEN}>>> 正在下载 sing-box ${TAG}...${PLAIN}"
    wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${SB_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    mv sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box*

    # 写入 Service
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

    # 十三：创建快捷方式 ssb
    cp "$0" /usr/local/bin/ssb
    chmod +x /usr/local/bin/ssb
    
    systemctl start sing-box
    echo -e "${GREEN}安装完成！现在你可以直接输入 ssb 呼出此菜单。${PLAIN}"
}

# 二：节点配置 (VLESS/SS/Socks)
add_node() {
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS/Reality"
    echo "2. Shadowsocks"
    echo "3. Socks5"
    echo "4. TUIC5/Hysteria2 (需自行配置证书路径)"
    echo "5. 返回"
    read -p "选择: " choice

    IP=$(get_ip)
    case $choice in
        1)
            read -p "端口: " PORT
            UUID=$(uuidgen)
            read -p "SNI (如 www.microsoft.com): " SNI
            KEYS=$(/usr/local/bin/sing-box generate keypair)
            PRIVATE=$(echo "$KEYS" | awk '/Private key:/ {print $3}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS" | awk '/Public key:/ {print $3}' | tr -d '[:space:]')
            SHORT_ID=$(openssl rand -hex 8)
            
            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg priv "$PRIVATE" --arg sid "$SHORT_ID" \
            '.inbounds += [{"type":"vless","tag":"vless-reality","listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#VLESS-Reality"
            echo -e "${GREEN}节点链接: ${PLAIN}\n$LINK"
            ;;
        2)
            read -p "端口: " PORT
            METHOD="2022-blake3-aes-128-gcm"
            KEY=$(openssl rand -base64 16)
            jq --arg port "$PORT" --arg pass "$KEY" --arg method "$METHOD" \
            '.inbounds += [{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            SS_BASE64=$(echo -n "$METHOD:$KEY" | base64 -w 0)
            echo -e "${GREEN}节点链接: ${PLAIN}\nss://$SS_BASE64@$IP:$PORT#SS"
            ;;
        3)
            read -p "端口: " PORT
            read -p "用户名: " USER
            read -p "密码: " PASS
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" \
            '.inbounds += [{"type":"socks","tag":"socks-in","listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}]}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            echo -e "${GREEN}Socks5 配置成功！${PLAIN}"
            ;;
        *) return ;;
    esac
    systemctl restart sing-box
}

# 三、四、五：管理配置
manage_configs() {
    echo -e "${YELLOW}--- 节点列表 ---${PLAIN}"
    jq -r '.inbounds[] | "Tag: \(.tag) | Port: \(.listen_port)"' $CONFIG_FILE | cat -n
    read -p "请输入序号进行操作 (q退出): " idx
    [[ "$idx" == "q" ]] && return
    
    echo "1. 查看详情 | 2. 删除 | 3. 修改端口"
    read -p "选择: " op
    case $op in
        1) jq ".inbounds[$(($idx-1))]" $CONFIG_FILE ;;
        2) jq "del(.inbounds[$(($idx-1))])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE ;;
        3) read -p "新端口: " NP; jq ".inbounds[$(($idx-1))].listen_port = ($NP|tonumber)" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE ;;
    esac
    systemctl restart sing-box
}

# 六：链式代理
chain_proxy() {
    read -p "外部节点 IP: " E_IP
    read -p "外部节点端口: " E_PORT
    # 增加出站
    jq --arg ip "$E_IP" --arg port "$E_PORT" \
    '.outbounds += [{"type":"socks","tag":"chain-out","server":$ip,"server_port":($port|tonumber)}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    # 修改路由
    jq '.routing.rules = [{"inbound":["vless-reality","ss-in"],"outbound":"chain-out"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    systemctl restart sing-box
}

# 七、十二：更新 (无 Git)
update_manager() {
    echo "1. 更新脚本 | 2. 更新 sing-box 内核"
    read -p "选择: " uc
    if [ "$uc" == "1" ]; then
        curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
        echo -e "${GREEN}脚本已更新！请重启 ssb 命令。${PLAIN}"
        exit 0
    elif [ "$uc" == "2" ]; then
        install_base
    fi
}

# 八：备份还原
backup_data() {
    echo "1. 备份 | 2. 还原"
    read -p "选择: " bc
    [[ "$bc" == "1" ]] && tar -czf /root/sb_bak.tar.gz /etc/sing-box/ && echo "备份至 /root/sb_bak.tar.gz"
    [[ "$bc" == "2" ]] && tar -xzf /root/sb_bak.tar.gz -C / && systemctl restart sing-box && echo "还原完成"
}

# 九：卸载
uninstall() {
    systemctl stop sing-box && systemctl disable sing-box
    rm -rf /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/ssb /etc/systemd/system/sing-box.service
    echo -e "${GREEN}卸载完成。${PLAIN}"
    exit 0
}

# 主菜单
while true; do
    clear
    echo -e "--- ${YELLOW}sing-box 一键管理脚本 (ssb)${PLAIN} ---"
    show_status
    echo "1. 安装/初始化"
    echo "2. 添加节点"
    echo "3. 查看/修改/删除配置"
    echo "4. 链式代理"
    echo "5. 更新"
    echo "6. 备份/还原"
    echo "7. 卸载"
    echo "0. 退出"
    read -p "选择 [0-7]: " menu_num

    case "$menu_num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy ;;
        5) update_manager ;;
        6) backup_data ;;
        7) uninstall ;;
        0) exit 0 ;;
    esac
    read -p "按回车继续..."
done
