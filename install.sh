#!/bin/bash

# ==========================================
# sing-box 一键脚本 (快捷方式: ssb)
# ==========================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
WHITE='\033[1;37m'
PLAIN='\033[0m'     

CONFIG_FILE="/etc/sing-box/config.json"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# --- 基础工具 ---
init_config() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        mkdir -p /etc/sing-box
        # [修复] 补全 route 结构，防止后续 jq 合并 null 时报错
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}
# --- SSL 证书管理 (ACME) ---
apply_cert() {
    echo -e "${YELLOW}--- ACME 域名证书申请 ---${PLAIN}"
    read -p "请输入解析到本机的域名: " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}错误: 域名不能为空${PLAIN}"
        return
    fi

    # 1. 安装基础依赖 (socat 用于 standalone 模式)
    echo -e "${CYAN}正在安装 acme.sh 依赖...${PLAIN}"
    apt update && apt install -y socat cron
    
    # 2. 安装 acme.sh (如果未安装)
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
        source ~/.bashrc
    fi

    # 3. 申请证书 (必须临时停止 sing-box 以释放 80 端口)
    echo -e "${YELLOW}正在尝试申请证书，请确保 80 端口未被占用且已在防火墙开启...${PLAIN}"
    systemctl stop sing-box 2>/dev/null
    
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --server letsencrypt
    
    if [ $? -eq 0 ]; then
        # 4. 安装证书到指定目录
        mkdir -p /etc/sing-box/certs
        ~/.acme.sh/acme.sh --install-cert -d "$domain" \
            --key-file /etc/sing-box/certs/server.key \
            --fullchain-file /etc/sing-box/certs/server.crt
        
        echo -e "${GREEN}✔ 证书申请并安装成功！${PLAIN}"
        echo -e "证书路径: ${BLUE}/etc/sing-box/certs/server.crt${PLAIN}"
        echo -e "私钥路径: ${BLUE}/etc/sing-box/certs/server.key${PLAIN}"
    else
        echo -e "${RED}✘ 证书申请失败，请检查域名解析是否正确，或 80 端口是否被屏蔽。${PLAIN}"
    fi
    
    # 恢复服务
    systemctl start sing-box 2>/dev/null
}

get_ip() {
    curl -sS -4 icanhazip.com || curl -sS -4 ifconfig.me
}

# --- BBR 开启脚本 ---
enable_bbr() {
    echo -e "${YELLOW}正在检查 BBR 状态...${PLAIN}"
    # 检查内核版本是否支持 (需 > 4.9)
    local kernel_version=$(uname -r | cut -d- -f1)
    if [[ $(echo -e "4.9\n$kernel_version" | sort -V | head -n1) == "4.9" ]]; then
        # 检查是否已启用
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
                echo -e "${RED}BBR 开启失败，请检查内核支持情况。${PLAIN}"
            fi
        fi
    else
        echo -e "${RED}内核版本过低 ($kernel_version)，请先升级内核以支持 BBR。${PLAIN}"
    fi
}

auto_backup() {
    local BACKUP_DIR="/root/singbox_backup"
    mkdir -p "$BACKUP_DIR"
    local TIME=$(date +%Y%m%d_%H%M%S)
    local B_NAME="auto_bak_before_update_$TIME.tar.gz"

    # 临时打包
    mkdir -p "/tmp/sb_auto_bak"
    # 备份内核
    [[ -f "/usr/local/bin/sing-box" ]] && cp "/usr/local/bin/sing-box" "/tmp/sb_auto_bak/"
    # 备份配置文件夹
    [[ -d "/etc/sing-box" ]] && cp -r /etc/sing-box/* "/tmp/sb_auto_bak/"
    
    # 压缩并清理
    tar -czf "$BACKUP_DIR/$B_NAME" -C "/tmp/sb_auto_bak" . >/dev/null 2>&1
    rm -rf "/tmp/sb_auto_bak"

    echo -e "${YELLOW}[自动快照] 更新前已备份当前内核与配置至: $B_NAME${PLAIN}"
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
    enable_bbr
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
    echo "0. 返回"
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
                    "tag":("reality" + $port),
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

            # [优化] 使用 ECC 证书替换 RSA，性能更好
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout /etc/sing-box/tuic.key \
                -out /etc/sing-box/tuic.crt \
                -subj "/CN=apple.com" -days 3650 2>/dev/null

            jq --arg port "$PORT" \
               --arg uuid "$UUID" \
               --arg pass "$PASS" \
               '.inbounds += [{
                    "type":"tuic",
                    "tag":("tuic" + $port),
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

            echo -e "${GREEN}TUIC5 配置成功 (自签名 ECC 证书)${PLAIN}"
            echo "节点链接: tuic://$UUID:$PASS@$IP:$PORT?sni=apple.com&alpn=h3&allow_insecure=1&congestion_control=bbr#TUIC5"
            ;;
        3)
            read -p "端口: " PORT
            read -p "密码: " PASS

            # [优化] 使用 ECC 证书替换 RSA，性能更好
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout /etc/sing-box/hy2.key \
                -out /etc/sing-box/hy2.crt \
                -subj "/CN=google.com" -days 3650 2>/dev/null

            jq --arg port "$PORT" \
               --arg pass "$PASS" \
               '.inbounds += [{
                    "type":"hysteria2",
                    "tag":("hy2" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "users":[{"password":$pass}],
                    "tls":{
                        "enabled":true,
                        "certificate_path":"/etc/sing-box/hy2.crt",
                        "key_path":"/etc/sing-box/hy2.key"
                    }
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            echo -e "${GREEN}Hysteria2 配置成功 (自签名 ECC 证书)${PLAIN}"
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
                    "tag":("ss" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "method":$method,
                    "password":$pass
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
            echo -e "${GREEN}Shadowsocks 链接:${PLAIN}"
            echo "ss://$SS_BASE64@$IP:$PORT#SS"
            # [优化] 增加兼容性提示
            echo -e "${YELLOW}(提示: SS-2022 协议需要较新的客户端支持，如 sing-box, Clash Meta/Mihomo 等)${PLAIN}"
            ;;
        5)
            read -p "请输入证书对应的域名: " DOMAIN
            if [ ! -f "/etc/sing-box/certs/server.crt" ]; then
                echo -e "${RED}错误: 未检测到 SSL 证书，请先执行菜单 5 申请证书。${PLAIN}"
                return
            fi
            read -p "端口 (建议 443, 8443, 2053 等 CF 支持端口): " PORT; PORT=${PORT:-443}
            read -p "WS 路径 (默认 /video): " WSPATH; WSPATH=${WSPATH:-"/video"}
            UUID=$($SB_BIN generate uuid 2>/dev/null || uuidgen)
            
            jq --arg port "$PORT" --arg uuid "$UUID" --arg path "$WSPATH" --arg domain "$DOMAIN" \
               '.inbounds += [{
                    "type": "vless",
                    "tag": ("vless-ws-" + $port),
                    "listen": "::",
                    "listen_port": ($port|tonumber),
                    "users": [{"uuid": $uuid}],
                    "transport": { "type": "ws", "path": $path },
                    "tls": {
                        "enabled": true,
                        "server_name": $domain,
                        "certificate_path": "/etc/sing-box/certs/server.crt",
                        "key_path": "/etc/sing-box/certs/server.key"
                    }
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
            
            echo -e "${GREEN}CF 兼容节点配置成功！${PLAIN}"
            echo -e "${BLUE}链接: vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&path=$WSPATH#CF_VLESS_${PORT}${PLAIN}"
            echo -e "${YELLOW}提示: 在 Cloudflare 后台开启“小云朵”即可隐藏真实 IP。${PLAIN}"
            ;;
        6)
            read -p "端口: " PORT
            read -p "用户名: " USER
            read -p "密码: " PASS

            jq --arg port "$PORT" \
               --arg user "$USER" \
               --arg pass "$PASS" \
               '.inbounds += [{
                    "type":"socks",
                    "tag":("socks" + $port),
                    "listen":"::",
                    "listen_port":($port|tonumber),
                    "users":[{"username":$user,"password":$pass}]
                }]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            echo -e "${GREEN}Socks5 添加成功。${PLAIN}"
            ;;
        0) 
            return
            ;;
        *) 
            echo -e "${RED}输入错误，返回主菜单${PLAIN}"
            return 
            ;;
    esac
    
    systemctl restart sing-box
}

# --- 三、四、五：配置管理 ---
manage_configs() {
    echo -e "${YELLOW}--- 节点列表 ---${PLAIN}"
    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q退出): " idx
    [[ "$idx" == "q" ]] && return

    echo -e "\n1. 查看详情并生成链接 | 2. 修改端口 | 3. 删除配置"
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

            echo -e "\n${YELLOW}>>>> 自动生成的节点分享链接 <<<<${PLAIN}"
            case $TYPE in
                vless)
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local SNI=$(echo "$CONF" | jq -r '.tls.server_name')
                    local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0]')
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
    echo -e "${YELLOW}--- 链式代理管理 (指定入站分流) ---${PLAIN}"
    echo "1. 添加链式转发"
    echo "2. 删除链式转发"
    echo "0. 返回"
    read -p "请选择: " cp_choice

    case $cp_choice in
        1)
            # 1. 选择本地入站节点
            echo -e "${YELLOW}请选择要进行链式转发的本地节点:${PLAIN}"
            jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
            read -p "选择序号: " idx
            local LOCAL_CONF=$(jq -c ".inbounds[$(($idx-1))]" "$CONFIG_FILE")
            local LOCAL_TAG=$(echo "$LOCAL_CONF" | jq -r .tag)
            local LOCAL_PORT=$(echo "$LOCAL_CONF" | jq -r .listen_port)

            # 2. 选择出站协议
            echo -e "\n${CYAN}选择落地机 (Next Hop) 协议:${PLAIN}"
            echo "1. Shadowsocks (SS)"
            echo "2. Socks5"
            read -p "选择: " hop_type

            read -p "远程服务器地址: " R_ADDR
            read -p "远程端口: " R_PORT
            
            local OUT_TAG="chain-out-$LOCAL_PORT"
            local OUT_JSON=""

            if [[ "$hop_type" == "1" ]]; then
                read -p "SS加密方式 (默认 aes-128-gcm): " R_METHOD
                [[ -z "$R_METHOD" ]] && R_METHOD="aes-128-gcm"
                read -p "密码: " R_PASS
                OUT_JSON="{ \"type\": \"shadowsocks\", \"tag\": \"$OUT_TAG\", \"server\": \"$R_ADDR\", \"server_port\": $R_PORT, \"method\": \"$R_METHOD\", \"password\": \"$R_PASS\" }"
            else
                read -p "用户名 (可选): " R_USER
                read -p "密码 (可选): " R_PASS
                OUT_JSON="{ \"type\": \"socks\", \"tag\": \"$OUT_TAG\", \"server\": \"$R_ADDR\", \"server_port\": $R_PORT, \"version\": \"5\" }"
                if [[ -n "$R_USER" ]]; then
                    OUT_JSON=$(echo "$OUT_JSON" | jq --arg u "$R_USER" --arg p "$R_PASS" '. + { "username": $u, "password": $p }')
                fi
            fi

            # 3. 写入 Outbound
            jq --argjson obj "$OUT_JSON" '.outbounds += [$obj]' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            # 4. 写入 Route Rule (置顶)，使用 (.route.rules // []) 防御 null 错误
            jq --arg in_tag "$LOCAL_TAG" --arg out_tag "$OUT_TAG" \
               '.route.rules = [{ "inbound": [$in_tag], "outbound": $out_tag }] + (.route.rules // [])' \
               "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"

            systemctl restart sing-box
            
            echo -e "\n${YELLOW}===============================================${PLAIN}"
            echo -e "${GREEN} ✔ 链式转发已成功开启！${PLAIN}"
            echo -e "${CYAN} 转发路径: [本地入站:$LOCAL_TAG] --> [远程落地:$R_ADDR]${PLAIN}"
            echo -e "${WHITE} 提示: 客户端配置保持不变，无需重新导入。${PLAIN}"
            echo -e "${YELLOW}===============================================${PLAIN}"
            ;;

        2)
            echo -e "${YELLOW}当前链式规则列表:${PLAIN}"
            local RULES=$(jq -r '.route.rules[] | select(.outbound | startswith("chain-out-")) | .inbound[0]' "$CONFIG_FILE")
            if [[ -z "$RULES" ]]; then echo "无配置"; return; fi
            echo "$RULES" | cat -n
            read -p "删除序号: " del_idx
            
            local DEL_IN_TAG=$(echo "$RULES" | sed -n "${del_idx}p")
            # [修复] 放弃脆弱的字符串截取，直接通过 inbound 查找对应的 outbound 标签
            local DEL_OUT_TAG=$(jq -r --arg itag "$DEL_IN_TAG" '.route.rules[] | select(.inbound[0] == $itag) | .outbound' "$CONFIG_FILE")

            # 执行删除
            jq --arg itag "$DEL_IN_TAG" 'del(.route.rules[] | select(.inbound[0] == $itag))' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
            jq --arg otag "$DEL_OUT_TAG" 'del(.outbounds[] | select(.tag == $otag))' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
            
            systemctl restart sing-box
            echo -e "${GREEN}链式规则已清除。${PLAIN}"
            ;;
        0) return ;;
    esac
}

# --- 七、八、九：系统维护 ---
update_all() {
    auto_backup
    echo -e "${CYAN}正在检查新版本...${PLAIN}"
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
    local BACKUP_DIR="/root/singbox_backup"
    mkdir -p "$BACKUP_DIR"

    echo -e "${YELLOW}--- 备份与还原 (含内核) ---${PLAIN}"
    echo "1. 立即备份 (内核 + 配置)"
    echo "2. 还原备份"
    echo "0. 返回"
    read -p "请选择: " br_choice

    case $br_choice in
        1)
            local TIME=$(date +%Y%m%d_%H%M%S)
            local B_NAME="singbox_full_$TIME.tar.gz"
            
            echo -e "${YELLOW}正在打包内核与配置...${PLAIN}"
            mkdir -p "/tmp/sb_bak"
            cp /usr/local/bin/sing-box "/tmp/sb_bak/"
            cp -r /etc/sing-box "/tmp/sb_bak/"
            
            tar -czf "$BACKUP_DIR/$B_NAME" -C "/tmp/sb_bak" .
            rm -rf "/tmp/sb_bak"
            
            echo -e "${GREEN}✔ 备份成功！${PLAIN}"
            echo -e "文件保存在: ${CYAN}$BACKUP_DIR/$B_NAME${PLAIN}"
            ;;
        2)
            echo -e "${YELLOW}可用备份列表:${PLAIN}"
            ls "$BACKUP_DIR" | grep ".tar.gz" | cat -n
            read -p "请选择要还原的序号: " r_idx
            local R_FILE=$(ls "$BACKUP_DIR" | grep ".tar.gz" | sed -n "${r_idx}p")
            
            if [[ -n "$R_FILE" ]]; then
                echo -e "${RED}警告：还原将覆盖当前内核与配置！${PLAIN}"
                read -p "确定还原 $R_FILE 吗？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    systemctl stop sing-box
                    tar -xzf "$BACKUP_DIR/$R_FILE" -C /tmp/
                    cp /tmp/sing-box /usr/local/bin/sing-box
                    chmod +x /usr/local/bin/sing-box
                    cp -r /tmp/sing-box/* /etc/sing-box/
                    rm -rf /tmp/sing-box /tmp/config.json
                    
                    systemctl restart sing-box
                    echo -e "${GREEN}✔ 还原成功并已重启服务！${PLAIN}"
                fi
            else
                echo -e "${RED}序号无效。${PLAIN}"
            fi
            ;;
        0) return ;;
    esac
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
    echo "7. 开启 BBR 网络加速"
    echo "8. 申请 SSL 域名证书 (ACME)"
    echo "77. 卸载"
    echo -e " \033[1;32m  [88]  重启 sing-box 服务\033[0m"
    echo "0. 退出"
    read -p "选择 [0-7]: " num
    case "$num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy ;;
        5) update_all ;;
        6) backup_restore ;;
        7) enable_bbr ;;
        8) apply_cert ;;
        77)
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
        88)
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
