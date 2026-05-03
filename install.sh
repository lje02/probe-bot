#!/bin/bash

# ==========================================
# sing-box 一键管理脚本 (快捷方式: ssb)
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
REPO_URL="https://github.com/lje02/sing.git"

# --- 检查 Root 权限 ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# --- 辅助功能 ---
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

# 一 & 十三：一键安装、自启、可执行权限与快捷方式
install_base() {
    echo -e "${GREEN}>>> 开始安装必要依赖和 sing-box...${PLAIN}"
    apt update -y
    apt install -y curl wget jq openssl tar git util-linux

    # 获取最新 sing-box 版本
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64) SB_ARCH="amd64" ;;
        arm64) SB_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    # 下载并安装
    wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${SB_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz
    mv sing-box-*/sing-box /usr/local/bin/
    rm -rf sing-box*

    chmod +x /usr/local/bin/sing-box

    # Systemd 守护进程
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
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

    # 十三：配置可执行权限和创建快捷方式
    SCRIPT_PATH=$(readlink -f "$0")
    cp "$SCRIPT_PATH" /usr/local/bin/ssb
    chmod +x /usr/local/bin/ssb
    
    echo -e "${GREEN}安装完成！已创建快捷命令: ssb${PLAIN}"
    systemctl start sing-box
}

# 二：节点配置 (示例: Shadowsocks & VLESS Reality)
add_node() {
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS/Reality"
    echo "2. TUIC V5"
    echo "3. Hysteria 2"
    echo "4. Shadowsocks"
    echo "5. Socks5"
    echo "6. 返回主菜单"
    read -p "请选择协议 [1-6]: " proto_choice

    IP=$(get_ip)
    
    case $proto_choice in
        1)
            read -p "请输入端口: " PORT
            UUID=$(uuidgen)
            read -p "请输入 SNI (如 www.microsoft.com): " SNI
            # 生成 x25519 密钥对
            KEYS=$(sing-box generate keypair)
            PRIVATE=$(echo "$KEYS" | grep Private | awk '{print $3}')
            PUBLIC=$(echo "$KEYS" | grep Public | awk '{print $3}')
            SHORT_ID=$(openssl rand -hex 8)
            
            # 使用 jq 写入配置
            jq --arg port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg priv "$PRIVATE" --arg sid "$SHORT_ID" \
            '.inbounds += [{"type":"vless","tag":"vless-reality","listen":"::","listen_port":($port|tonumber),"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$priv,"short_id":[$sid]}}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#VLESS-Reality"
            echo -e "${GREEN}添加成功！节点链接:${PLAIN}\n$LINK"
            ;;
        4)
            read -p "请输入端口: " PORT
            read -p "请输入密码: " PASS
            METHOD="2022-blake3-aes-128-gcm"
            # SS2022 需要特定长度密钥
            KEY=$(openssl rand -base64 16)
            
            jq --arg port "$PORT" --arg pass "$KEY" --arg method "$METHOD" \
            '.inbounds += [{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":($port|tonumber),"method":$method,"password":$pass}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            # URL 安全 Base64
            SS_BASE64=$(echo -n "$METHOD:$KEY" | base64 -w 0)
            LINK="ss://$SS_BASE64@$IP:$PORT#Shadowsocks"
            echo -e "${GREEN}添加成功！节点链接:${PLAIN}\n$LINK"
            ;;
        5)
            read -p "请输入端口: " PORT
            read -p "请输入用户名: " USER
            read -p "请输入密码: " PASS
            
            jq --arg port "$PORT" --arg user "$USER" --arg pass "$PASS" \
            '.inbounds += [{"type":"socks","tag":"socks-in","listen":"::","listen_port":($port|tonumber),"users":[{"username":$user,"password":$pass}]}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
            echo -e "${GREEN}添加成功！Socks5 凭证: IP:$IP 端口:$PORT 用户:$USER 密码:$PASS${PLAIN}"
            ;;
        6) return ;;
        *) echo -e "${YELLOW}TUIC 和 Hysteria2 协议需要签发证书，请在此基础上扩展 jq 逻辑。${PLAIN}" ;;
    esac
    
    systemctl restart sing-box
    exit 0
}

# 三、四、五：配置管理
manage_configs() {
    echo -e "${YELLOW}--- 当前节点列表 ---${PLAIN}"
    # 读取所有 inbounds 的 tag 和 端口
    jq -r '.inbounds[] | "Tag: \(.tag) | Port: \(.listen_port)"' $CONFIG_FILE | cat -n
    
    read -p "请输入要操作的配置序号 (按 q 退出): " idx
    if [[ "$idx" == "q" ]]; then return; fi
    
    # 获取选中的 tag
    TAG=$(jq -r ".inbounds[$(($idx-1))].tag" $CONFIG_FILE)
    
    echo "1. 查看配置 (四)"
    echo "2. 删除配置 (五)"
    echo "3. 更改端口 (三)"
    read -p "请选择操作 [1-3]: " op
    
    case $op in
        1)
            echo -e "${GREEN}配置详情:${PLAIN}"
            jq ".inbounds[$(($idx-1))]" $CONFIG_FILE
            exit 0
            ;;
        2)
            jq "del(.inbounds[$(($idx-1))])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            systemctl restart sing-box
            echo -e "${GREEN}配置已删除！${PLAIN}"
            exit 0
            ;;
        3)
            read -p "请输入新端口: " NEW_PORT
            jq ".inbounds[$(($idx-1))].listen_port = ($NEW_PORT|tonumber)" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            systemctl restart sing-box
            echo -e "${GREEN}端口已更新为 $NEW_PORT 并已重启服务！${PLAIN}"
            exit 0
            ;;
    esac
}

# 六：链式代理 (前置代理出站)
chain_proxy() {
    echo -e "${YELLOW}--- 配置链式代理 (作为外部节点出口) ---${PLAIN}"
    read -p "请输入外部节点地址(IP): " EXT_IP
    read -p "请输入外部节点端口: " EXT_PORT
    
    # 简单的 Socks5 出站示例
    jq --arg ip "$EXT_IP" --arg port "$EXT_PORT" \
    '.outbounds += [{"type":"socks","tag":"chain-out","server":$ip,"server_port":($port|tonumber)}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    
    # 将路由规则指向此出站
    jq '.routing.rules += [{"inbound":["vless-reality","ss-in"],"outbound":"chain-out"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    
    systemctl restart sing-box
    echo -e "${GREEN}链式代理已配置完成！${PLAIN}"
    exit 0
}

# 七、十二：更新机制
update_script() {
    echo -e "${YELLOW}1. 更新管理脚本 (从 Github: $REPO_URL)${PLAIN}"
    echo -e "${YELLOW}2. 更新 sing-box 内核${PLAIN}"
    read -p "请选择: " up_choice
    
    if [ "$up_choice" == "1" ]; then
        TMP_DIR="/tmp/sing_update"
        rm -rf $TMP_DIR
        git clone "$REPO_URL" $TMP_DIR
        # 假设仓库中的脚本名为 ssb.sh 或 install.sh
        if [ -f "$TMP_DIR/install.sh" ]; then
            cp "$TMP_DIR/install.sh" /usr/local/bin/ssb
            chmod +x /usr/local/bin/ssb
            echo -e "${GREEN}脚本更新成功！请重新运行 ssb。${PLAIN}"
            exit 0
        else
            echo -e "${RED}未在仓库中找到安装脚本。${PLAIN}"
        fi
    elif [ "$up_choice" == "2" ]; then
        # 重新运行安装逻辑中的下载部分
        systemctl stop sing-box
        TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
        ARCH=$(dpkg --print-architecture)
        wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${ARCH}.tar.gz"
        tar -xzf sing-box.tar.gz
        mv sing-box-*/sing-box /usr/local/bin/
        rm -rf sing-box*
        systemctl start sing-box
        echo -e "${GREEN}sing-box 内核已更新至 $TAG！${PLAIN}"
    fi
}

# 八：备份与还原
backup_restore() {
    echo "1. 备份配置"
    echo "2. 还原配置"
    read -p "选择操作: " br_choice
    
    if [ "$br_choice" == "1" ]; then
        tar -czvf /root/sing-box-backup.tar.gz /etc/sing-box/
        echo -e "${GREEN}备份已保存至 /root/sing-box-backup.tar.gz${PLAIN}"
    elif [ "$br_choice" == "2" ]; then
        if [ -f "/root/sing-box-backup.tar.gz" ]; then
            tar -xzvf /root/sing-box-backup.tar.gz -C /
            systemctl restart sing-box
            echo -e "${GREEN}还原成功并已重启！${PLAIN}"
        else
            echo -e "${RED}未找到备份文件！${PLAIN}"
        fi
    fi
}

# 九：卸载
uninstall_all() {
    read -p "确认完全卸载 sing-box 及所有配置？(y/n): " confirm
    if [ "$confirm" == "y" ]; then
        systemctl stop sing-box
        systemctl disable sing-box
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
        rm -rf /etc/sing-box
        rm -f /usr/local/bin/sing-box
        rm -f /usr/local/bin/ssb
        echo -e "${GREEN}已彻底卸载！${PLAIN}"
        exit 0
    fi
}

# ================= 主菜单 =================
while true; do
    clear
    echo -e "====================================="
    echo -e "       ${GREEN}sing-box 一键管理脚本${PLAIN}       "
    echo -e "====================================="
    show_status
    echo -e "====================================="
    echo " 1. 一键安装 / 初始化基础环境 (一, 十三)"
    echo " 2. 节点配置 / 添加协议 (二)"
    echo " 3. 管理已有配置 (三, 四, 五)"
    echo " 4. 链式代理设置 (六)"
    echo " 5. 更新核心 / 更新脚本 (七, 十二)"
    echo " 6. 备份 / 还原配置 (八)"
    echo " 7. 完全卸载 (九)"
    echo " 0. 退出脚本 (十)"
    echo -e "====================================="
    read -p "请输入数字 [0-7]: " num

    case "$num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy ;;
        5) update_script ;;
        6) backup_restore ;;
        7) uninstall_all ;;
        0) echo "退出脚本."; exit 0 ;;
        *) echo -e "${RED}请输入正确的数字!${PLAIN}" ;;
    esac
    read -p "按回车键继续..."
done

