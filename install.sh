#!/bin/bash

# ==========================================
# sing-box 一键脚本 (快捷方式: ssb)
# ==========================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
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
    apt update -y
    apt install -y curl jq openssl tar util-linux wget

    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    wget -O sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-amd64.tar.gz"
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
    echo "2. TUIC v5"
    echo "3. Hysteria2"
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
            read -p "SNI (默认 music.apple.com): " SNI; SNI=${SNI:-"music.apple.com"}

            jq --arg port "$PORT" \
               --arg uuid "$UUID" \
               --arg sni "$SNI" \
               --arg priv "$PRIVATE" \
               --arg sid "$SHORT_ID" \
               '.inbounds += [{
                    "type":"vless",
                    "tag":("vless-reality-" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],
                    "tls":{
                        "enabled":true,
                        "server_name":$sni,
                        "reality":{
                            "enabled":true,
                            "handshake":{"server":$sni,"server_port":443},
                            "private_key":$priv,
                            "short_id":[$sid]
                        }
                    }
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            echo -e "${GREEN}节点链接:${PLAIN}"
            echo "vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORT_ID&type=tcp&flow=xtls-rprx-vision#VLESS-Reality"
            ;;
        2)
            UUID=$($SB_BIN generate uuid 2>/dev/null || uuidgen)
            read -p "端口: " PORT
            read -p "密码: " PASS

            # 增加 2>/dev/null 屏蔽冗余的证书生成提示信息
            openssl req -x509 -nodes -newkey rsa:2048 \
                -keyout /etc/sing-box/tuic.key \
                -out /etc/sing-box/tuic.crt \
                -subj "/CN=apple.com" -days 3650 2>/dev/null

            jq --arg port "$PORT" \
               --arg uuid "$UUID" \
               --arg pass "$PASS" \
               '.inbounds += [{
                    "type":"tuic",
                    "tag":("tuic-in-" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "users":[{"uuid":$uuid,"password":$pass}],
                    "tls":{
                        "enabled":true,
                        "certificate_path":"/etc/sing-box/tuic.crt",
                        "key_path":"/etc/sing-box/tuic.key",
                        "alpn": ["h3"]
                    }
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            echo -e "${GREEN}TUIC5 配置成功 (自签名证书)${PLAIN}"
            # 补齐了 sni, alpn 并且修正了 allow_insecure 参数，提升多客户端兼容性
            echo "节点链接: tuic://$UUID:$PASS@$IP:$PORT?sni=apple.com&alpn=h3&allow_insecure=1&congestion_control=bbr#TUIC5"
            ;;
        3)
            read -p "端口: " PORT
            read -p "密码: " PASS

            openssl req -x509 -nodes -newkey rsa:2048 \
                -keyout /etc/sing-box/hy2.key \
                -out /etc/sing-box/hy2.crt \
                -subj "/CN=google.com" -days 3650

            jq --arg port "$PORT" \
               --arg pass "$PASS" \
               '.inbounds += [{
                    "type":"hysteria2",
                    "tag":("hy2-in-" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "users":[{"password":$pass}],
                    "tls":{
                        "enabled":true,
                        "certificate_path":"/etc/sing-box/hy2.crt",
                        "key_path":"/etc/sing-box/hy2.key"
                    }
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            echo -e "${GREEN}Hysteria2 配置成功${PLAIN}"
            echo "节点链接: hysteria2://$PASS@$IP:$PORT?insecure=1#Hy2"
            ;;
        4)
            read -p "端口: " PORT
            PASS=$(openssl rand -base64 16)
            METHOD="2022-blake3-aes-128-gcm"

            jq --arg port "$PORT" \
               --arg pass "$PASS" \
               --arg method "$METHOD" \
               '.inbounds += [{
                    "type":"shadowsocks",
                    "tag":("ss-in-" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "method":$method,
                    "password":$pass
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
            echo -e "${GREEN}Shadowsocks 链接:${PLAIN}"
            echo "ss://$SS_BASE64@$IP:$PORT#SS"
            ;;
        5)
            read -p "端口: " PORT
            read -p "用户名: " USER
            read -p "密码: " PASS

            jq --arg port "$PORT" \
               --arg user "$USER" \
               --arg pass "$PASS" \
               '.inbounds += [{
                    "type":"socks",
                    "tag":("socks-in-" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "users":[{"username":$user,"password":$pass}]
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            echo -e "${GREEN}Socks5 添加成功。${PLAIN}"
            ;;
        *) return ;;
    esac
    systemctl restart sing-box
}

# --- 三、四、五：配置管理 ---
manage_configs() {
    echo -e "${YELLOW}--- 节点列表 ---${PLAIN}"
    # 列出所有入站，带上序号
    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q退出): " idx
    [[ "$idx" == "q" ]] && return

    echo -e "\n1. 查看详情并生成链接 | 2. 修改端口 | 3. 删除配置"
    read -p "选择操作: " op
    case $op in
        1)
            # 获取选中的入站配置内容
            local CONF=$(jq -c ".inbounds[$(($idx-1))]" "$CONFIG_FILE")
            local TYPE=$(echo "$CONF" | jq -r .type)
            local PORT=$(echo "$CONF" | jq -r .listen_port)
            local IP=$(get_ip)

            echo -e "\n${GREEN}================ 原始 JSON 配置 ================${PLAIN}"
            echo "$CONF" | jq .
            echo -e "${GREEN}===============================================${PLAIN}"

            echo -e "\n${YELLOW}>>>> 自动生成的节点分享链接 <<<<${PLAIN}"
            case $TYPE in
                vless)
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local SNI=$(echo "$CONF" | jq -r '.tls.server_name')
                    local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0]')
                    # 注意：Reality 的公钥 (pbk) 通常不存在服务器 config 里，这里只能提示用户手动填写或从创建记录中找
                    echo -e "${BLUE}vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=这里需填写你的公钥&sid=$SID&type=tcp&flow=xtls-rprx-vision#VLESS_$PORT${PLAIN}"
                    echo -e "${RED}(提示: VLESS Reality 的 Public Key 仅在创建时显示，不保存在服务器配置文件中)${PLAIN}"
                    ;;
                tuic)
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    echo -e "${BLUE}tuic://$UUID:$PASS@$IP:$PORT?sni=apple.com&alpn=h3&allow_insecure=1&congestion_control=bbr#TUIC5_$PORT${PLAIN}"
                    ;;
                hysteria2)
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    echo -e "${BLUE}hysteria2://$PASS@$IP:$PORT?insecure=1&sni=google.com#Hy2_$PORT${PLAIN}"
                    ;;
                shadowsocks)
                    local METHOD=$(echo "$CONF" | jq -r .method)
                    local PASS=$(echo "$CONF" | jq -r .password)
                    local SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
                    echo -e "${BLUE}ss://$SS_BASE64@$IP:$PORT#SS_$PORT${PLAIN}"
                    ;;
                socks)
                    local USER=$(echo "$CONF" | jq -r '.users[0].username')
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    echo -e "${BLUE}Socks5 链接: socks5://$USER:$PASS@$IP:$PORT${PLAIN}"
                    ;;
                *)
                    echo -e "${RED}该协议暂不支持自动生成链接预览${PLAIN}"
                    ;;
            esac
            echo -e "${YELLOW}-----------------------------------------------${PLAIN}"
            ;;
        2)
            read -p "新端口: " NP
            jq ".inbounds[$(($idx-1))].listen_port = ($NP|tonumber)" "$CONFIG_FILE" > tmp.json
            mv tmp.json "$CONFIG_FILE"
            systemctl restart sing-box
            echo "端口已更新并重启服务"
            ;;
        3)
            jq "del(.inbounds[$(($idx-1))])" "$CONFIG_FILE" > tmp.json
            mv tmp.json "$CONFIG_FILE"
            systemctl restart sing-box
            echo "配置已删除并重启服务"
            ;;
    esac
}

# --- 六：链式代理 ---
chain_proxy() {
    read -p "输入外部 Socks5/SS 地址: " E_IP
    read -p "输入外部端口: " E_PORT

    jq --arg ip "$E_IP" \
       --arg port "$E_PORT" \
       '.outbounds += [{
            "type":"socks",
            "tag":"chain-out",
            "server":$ip,
            "server_port":($port|tonumber)
        }]
        | .routing.rules = [{
            "inbound":["vless-reality","ss-in"],
            "outbound":"chain-out"
        }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

    systemctl restart sing-box
    echo "链式代理配置完成"
}

# --- 七、八、九：系统维护 ---
update_all() {
    echo "1. 更新脚本 | 2. 更新内核"
    read -p "选择: " uc
    if [ "$uc" == "1" ]; then
        curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb
        chmod +x /usr/local/bin/ssb
        echo "脚本更新完成"
        exit 0
    else
        install_base
    fi
}

backup_restore() {
    echo "1. 备份 | 2. 还原"
    read -p "选择: " br
    if [[ "$br" == "1" ]]; then
        tar -czf /root/sb_bak.tar.gz /etc/sing-box/
        echo "备份成功: /root/sb_bak.tar.gz"
    elif [[ "$br" == "2" ]]; then
        tar -xzf /root/sb_bak.tar.gz -C /
        systemctl restart sing-box
        echo "还原成功"
    fi
}

# --- 主菜单 ---
while true; do
    clear
    echo -e "--- ${YELLOW}sing-box 综合管理脚本 (ssb)${PLAIN} ---"
    show_status
    echo "--------------------------------"
    echo "1. 安装 / 重装 sing-box"
    echo "2. 节点配置 (VLESS/TUIC/Hy2/SS/Socks)"
    echo "3. 管理配置 (查看/修改/删除)"
    echo "4. 链式代理设置"
    echo "5. 更新脚本或内核"
    echo "6. 备份 / 还原"
    echo "7. 卸载"
    echo -e " \033[1;32m  [8]  重启 sing-box 服务\033[0m" # 绿色加粗，很醒目
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
            echo -e "${RED}！！！警告：即将卸载 sing-box 并删除所有配置！！！${PLAIN}"
            read -p "确定要继续吗？(y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                systemctl stop sing-box >/dev/null 2>&1
                systemctl disable sing-box >/dev/null 2>&1
                rm -f /usr/local/bin/sing-box /usr/local/bin/ssb
                rm -rf /etc/sing-box
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload
                echo -e "${GREEN}卸载完成！${PLAIN}"
                exit 0
            else
                echo -e "${YELLOW}已取消卸载。${PLAIN}"
            fi
            ;;
    8)
            echo -e "${YELLOW}正在尝试重启 sing-box 服务...${PLAIN}"
            systemctl restart sing-box
            sleep 1
            if systemctl is-active --quiet sing-box; then
                echo -e "${GREEN}✔ 重启成功！服务正常运行中。${PLAIN}"
            else
                echo -e "${RED}✘ 重启失败！配置可能存在语法错误。${PLAIN}"
                echo -e "${YELLOW}提示: 请运行 'journalctl -u sing-box --no-pager -n 10' 检查。${PLAIN}"
            fi
            ;;
        0) 
            echo -e "${GREEN}感谢使用，再见！${PLAIN}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}请输入正确的数字选择 [0-8]${PLAIN}" 
            ;;
    esac
    echo ""
    read -p "按回车键返回主菜单..."
done
