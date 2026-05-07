#!/usr/bin/env bash
# sing-box 综合管理脚本 (ssb) 
# 功能：安装/更新 sing-box，节点配置管理，链式代理，备份/还原，ACME 证书申请等。
# 要求：Debian/Ubuntu 环境，需 root 权限。请使用：bash ssb

set -euo pipefail
IFS=$'\n\t'

# 颜色配置
RED='\033[1;31m'    # 红色
GREEN='\033[1;32m'  # 绿色
YELLOW='\033[1;33m' # 黄色
CYAN='\033[1;36m'   # 青色
PLAIN='\033[0m'     # 无色

# 可配置路径与常量
CONFIG_FILE="/etc/sing-box/config.json"
LINK_DIR="/etc/sing-box/links"
CERT_DIR="/etc/sing-box/certs"
BACKUP_DIR="/root/singbox_backup"
SB_BIN="/usr/local/bin/sing-box"
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

# 检查命令是否存在
require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}错误：缺少依赖 '$1'，请先安装。${PLAIN}" >&2
        exit 1
    fi
}

# 先验检查
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：必须以 root 用户运行脚本！${PLAIN}" >&2
    exit 1
fi

# 检查 package 管理器 (仅支持 apt, yum)
if command -v apt-get &>/dev/null; then
    PKG_INSTALL="apt-get"
elif command -v yum &>/dev/null; then
    PKG_INSTALL="yum"
else
    echo -e "${RED}错误：系统不受支持，只支持 Debian/Ubuntu/CentOS 等常见发行版。${PLAIN}" >&2
    exit 1
fi

# 检查必要命令
for cmd in curl wget jq openssl tar systemctl uuidgen; do
    require_cmd $cmd
done

# 暂停函数
pause() {
    echo ""
    read -r -p "操作完成，按回车键继续..." _ || true
}

# 原子化写入配置并检查
save_and_restart() {
    local tmpfile
    tmpfile=$(mktemp) || { echo -e "${RED}错误：创建临时文件失败。${PLAIN}"; return 1; }
    # 将新配置写入临时文件
    jq "$@" "$CONFIG_FILE" > "$tmpfile"
    # 语法检查
    set +e
    if "$SB_BIN" check -c "$tmpfile" &>/dev/null; then
        set -e
        mv "$tmpfile" "$CONFIG_FILE"
        systemctl restart sing-box
        echo -e "${GREEN}✔ 配置已应用并重启服务。${PLAIN}"
        return 0
    else
        set -e
        echo -e "${RED}✘ 配置语法检查失败，更新已取消。${PLAIN}"
        rm -f "$tmpfile"
        return 1
    fi
}

# 初始化配置文件和目录
init_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" "$LINK_DIR" "$CERT_DIR"
    if [[ ! -s "$CONFIG_FILE" ]]; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}

# 获取公网IP (IPv4或IPv6)
get_ip() {
    local ip4 ip6
    ip4=$(curl -s4 --retry 3 --retry-delay 2 --connect-timeout 5 icanhazip.com || curl -s4 --retry 3 --retry-delay 2 --connect-timeout 5 ifconfig.me || true)
    ip6=$(curl -s6 --retry 3 --retry-delay 2 --connect-timeout 5 icanhazip.com || curl -s6 --retry 3 --retry-delay 2 --connect-timeout 5 ifconfig.me || true)
    if [[ -n "$ip4" ]]; then
        echo "$ip4"
    elif [[ -n "$ip6" ]]; then
        echo "[$ip6]"
    else
        echo "127.0.0.1"
    fi
}

# 显示 sing-box 服务状态
show_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box 状态: ${GREEN}[运行中]${PLAIN}"
    else
        echo -e "sing-box 状态: ${RED}[未运行/已停止]${PLAIN}"
    fi
}

# -------------------- 功能模块 --------------------

# 申请证书 (ACME)
apply_cert() {
    echo -e "${YELLOW}--- ACME 域名证书申请 ---${PLAIN}"
    read -r -p "请输入解析到本机的域名: " domain
    if [[ -z "$domain" ]]; then
        echo -e "${RED}域名不能为空！${PLAIN}"
        pause
        return
    fi
    # 域名简单校验
    if ! [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z]{2,})+$ ]]; then
        echo -e "${RED}域名格式不正确！${PLAIN}"
        pause
        return
    fi

    # 安装 acme.sh 及依赖
    echo -e "${CYAN}>>> 安装 acme.sh 和依赖${PLAIN}"
    if [[ "$PKG_INSTALL" == "apt-get" ]]; then
        apt-get update -qq
        apt-get install -y socat cron curl
    else
        yum install -y socat cronie curl
    fi

    # 安装 acme.sh (无需交互)
    if ! command -v acme.sh &>/dev/null; then
        echo -e "${CYAN}>>> 安装 acme.sh...${PLAIN}"
        curl -sSf https://get.acme.sh | bash -s -- --accountemail "admin@$domain"
        source ~/.bashrc || true
    fi

    echo -e "${YELLOW}尝试申请证书，请确保 80 端口未被占用...${PLAIN}"
    systemctl stop sing-box 2>/dev/null || true

    # 使用 standalone 模式申请证书
    if acme.sh --issue --standalone -d "$domain" --server letsencrypt --home ~/.acme.sh --force; then
        local target_dir="$CERT_DIR/$domain"
        mkdir -p "$target_dir"
        acme.sh --install-cert -d "$domain" \
            --key-file "$target_dir/server.key" \
            --fullchain-file "$target_dir/server.crt" \
            --reloadcmd "systemctl restart sing-box" \
            --home ~/.acme.sh
        echo -e "${GREEN}✔ 证书申请成功，文件已保存到：$target_dir${PLAIN}"
    else
        echo -e "${RED}✘ 证书申请失败，请检查域名解析和80端口。${PLAIN}"
    fi
    systemctl start sing-box 2>/dev/null || true
    pause
}

# 自动备份（更新前快照）
auto_backup() {
    mkdir -p "$BACKUP_DIR"
    local time_str
    time_str=$(date +%Y%m%d_%H%M%S)
    local bakfile="auto_bak_before_update_$time_str.tar.gz"
    local tmpdir
    tmpdir=$(mktemp -d) || { echo -e "${RED}错误：创建临时目录失败。${PLAIN}"; return; }
    trap 'rm -rf "$tmpdir"' RETURN

    # 备份 sing-box 二进制和 /etc/sing-box
    mkdir -p "$tmpdir/bin"
    [[ -f /usr/local/bin/sing-box ]] && cp -p /usr/local/bin/sing-box "$tmpdir/bin/"
    [[ -d /etc/sing-box ]] && cp -r /etc/sing-box "$tmpdir/sing-box"
    tar -C "$tmpdir" -czf "$BACKUP_DIR/$bakfile" .
    echo -e "${YELLOW}[自动备份] 更新前已备份至: $bakfile${PLAIN}"
}

# 备份与还原菜单
backup_restore() {
    clear
    echo -e "${YELLOW}--- 备份与还原 ---${PLAIN}"
    echo "1. 立即备份 (内核 + 配置)"
    echo "2. 还原备份"
    echo "0. 返回"
    read -r -p "选择: " br_choice
    case "$br_choice" in
        0) return ;;
        1)
            # 立即备份
            echo -e "${CYAN}>>> 执行手动备份...${PLAIN}"
            mkdir -p "$BACKUP_DIR"
            local time_str dirbak
            time_str=$(date +%Y%m%d_%H%M%S)
            dirbak=$(mktemp -d) || { echo -e "${RED}错误：创建临时目录失败。${PLAIN}"; return; }
            trap 'rm -rf "$dirbak"' RETURN
            mkdir -p "$dirbak/bin"
            [[ -f /usr/local/bin/sing-box ]] && cp -p /usr/local/bin/sing-box "$dirbak/bin/"
            [[ -d /etc/sing-box ]] && cp -r /etc/sing-box "$dirbak/sing-box"
            tar -C "$dirbak" -czf "$BACKUP_DIR/singbox_full_$time_str.tar.gz" .
            echo -e "${GREEN}备份完成: singbox_full_$time_str.tar.gz${PLAIN}"
            ;;
        2)
            # 还原备份
            echo -e "${CYAN}>>> 备份还原${PLAIN}"
            # 列出备份文件
            mapfile -t files < <(ls "$BACKUP_DIR" 2>/dev/null | grep -E "singbox_full_[0-9]{8}_[0-9]{6}\.tar\.gz$")
            if [[ ${#files[@]} -eq 0 ]]; then
                echo -e "${RED}未找到备份文件。${PLAIN}"
                pause
                return
            fi
            echo "可用备份文件："
            for i in "${!files[@]}"; do
                echo "$((i+1)). ${files[i]}"
            done
            read -r -p "选择要还原的序号: " idx
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#files[@]} )); then
                echo -e "${RED}选择无效。${PLAIN}"
                pause
                return
            fi
            local chosen="${files[$((idx-1))]}"
            local tmpdir
            tmpdir=$(mktemp -d) || { echo -e "${RED}错误：创建临时目录失败。${PLAIN}"; return; }
            trap 'rm -rf "$tmpdir"' RETURN
            tar -xzf "$BACKUP_DIR/$chosen" -C "$tmpdir"
            # 恢复文件
            if [[ -f "$tmpdir/bin/sing-box" ]]; then
                cp -p "$tmpdir/bin/sing-box" /usr/local/bin/sing-box
            fi
            if [[ -d "$tmpdir/sing-box" ]]; then
                cp -rp "$tmpdir/sing-box/." /etc/sing-box/
            fi
            systemctl restart sing-box
            echo -e "${GREEN}备份 $chosen 已成功还原并重启服务。${PLAIN}"
            ;;
        *)
            echo -e "${RED}输入错误，请重新选择。${PLAIN}"
            ;;
    esac
    pause
}

# 安装或更新 sing-box
install_base() {
    echo -e "${GREEN}>>> 正在安装依赖并检测架构...${PLAIN}"
    if [[ "$PKG_INSTALL" == "apt-get" ]]; then
        apt-get update -qq
        apt-get install -y curl jq openssl tar util-linux wget uuid-runtime
    else
        yum install -y curl jq openssl tar util-linux wget which
    fi

    # 检测架构
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}" >&2; pause; return ;;
    esac

    # 获取最新版本号
    echo -e "${CYAN}检测到架构: $arch，正在获取最新版本...${PLAIN}"
    local TAG
    TAG=$(curl -sSfL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
          | jq -r .tag_name)
    if [[ -z "$TAG" ]]; then
        echo -e "${RED}错误：无法获取最新版本号。${PLAIN}"
        pause
        return
    fi
    echo -e "${CYAN}最新版本: $TAG${PLAIN}"

    # 下载并解压 sing-box
    local url file
    file="sing-box-${TAG#v}-linux-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/${TAG}/${file}"
    echo -e "${CYAN}正在下载 $file...${PLAIN}"
    curl -L --retry 3 --retry-delay 2 -o "$file" "$url" \
        && echo -e "${GREEN}下载完成。${PLAIN}" \
        || { echo -e "${RED}下载失败，请检查网络或版本号。${PLAIN}"; rm -f "$file"; pause; return; }

    local extract_dir
    extract_dir=$(mktemp -d) || { echo -e "${RED}错误：创建临时目录失败。${PLAIN}"; rm -f "$file"; pause; return; }
    tar -xzf "$file" -C "$extract_dir"
    local bin_path
    bin_path=$(find "$extract_dir" -type f -name sing-box -print -quit)
    if [[ -z "$bin_path" ]]; then
        echo -e "${RED}错误：未找到 sing-box 可执行文件。${PLAIN}"
        rm -rf "$extract_dir" "$file"
        pause
        return
    fi
    mv "$bin_path" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "$extract_dir" "$file"
    echo -e "${GREEN}sing-box 二进制已安装到 /usr/local/bin/sing-box${PLAIN}"

    # 生成 systemd 服务单元（使用临时文件保证原子性）
    echo -e "${CYAN}正在配置 systemd 服务...${PLAIN}"
    local unit_tmp
    unit_tmp=$(mktemp) || { echo -e "${RED}错误：创建临时文件失败。${PLAIN}"; pause; return; }
    cat > "$unit_tmp" <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    mv "$unit_tmp" /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    systemctl enable sing-box
    init_config
    cp -- "$0" /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
    systemctl start sing-box
    echo -e "${GREEN}安装完成！现在可以使用${PLAIN} ${CYAN}ssb${PLAIN} ${GREEN}命令进行管理。${PLAIN}"
    pause
}

# 添加节点配置
add_node() {
    clear
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo "1. VLESS + Reality"
    echo "2. TUIC v5"
    echo "3. Hysteria2"
    echo "4. Shadowsocks (2022-blake3)"
    echo "5. VLESS + WS + TLS"
    echo "6. Socks5"
    echo "0. 返回"
    read -r -p "请选择: " choice
    [[ "$choice" == "0" ]] && return

    local IP
    IP=$(get_ip)
    local LINK TAG UUID PASS
    UUID=$(uuidgen)
    case $choice in
        1)
            # VLESS + Reality
            TAG="reality"
            read -r -p "端口 (默认 443): " PORT
            PORT=${PORT:-443}
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            read -r -p "SNI (默认 music.apple.com): " SNI
            SNI=${SNI:-music.apple.com}
            TAG="${TAG}${PORT}"
            # 生成 Reality 密钥对
            if ! require_cmd uuidgen; then return; fi
            local keys privkey pubkey shortid
            keys=$("$SB_BIN" generate reality-keypair)
            privkey=$(echo "$keys" | awk -F': ' '/Private/ {print $2}')
            pubkey=$(echo "$keys" | awk -F': ' '/Public/ {print $2}')
            shortid=$(openssl rand -hex 8)
            save_and_restart '.inbounds += [{
                    "type":"vless","tag":$t,"listen_port":'"$PORT"',
                    "listen":"::","users":[{"uuid":"'"$UUID"'","flow":"xtls-rprx-vision"}],
                    "tls":{"enabled":true,"server_name":"'"$SNI"'",
                        "reality":{"enabled":true,"handshake":{"server":"'"$SNI"'","server_port":443},
                                   "private_key":"'"$privkey"'","short_id":["'"$shortid"'"]}}
                }]' --arg t "$TAG"
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&pbk=$pubkey&sid=$shortid&type=tcp&flow=xtls-rprx-vision#$TAG"
            ;;
        2)
            # TUIC v5
            TAG="tuic"
            read -r -p "端口: " PORT
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            read -r -p "密码: " PASS
            if [[ -z "$PASS" ]]; then
                echo -e "${RED}密码不能为空！${PLAIN}"
                pause; return
            fi
            TAG="${TAG}${PORT}"
            echo "1. 自签名证书 | 2. ACME 证书"
            read -r -p "选择证书类型: " cert_type
            local cert_path key_path alpn sni_name allow_insecure
            if [[ "$cert_type" == "2" ]]; then
                read -r -p "请输入域名 (对应已有证书): " domain
                if [[ -z "$domain" ]]; then echo -e "${RED}域名不能为空！${PLAIN}"; pause; return; fi
                cert_path="$CERT_DIR/$domain/server.crt"
                key_path="$CERT_DIR/$domain/server.key"
                if [[ ! -f "$cert_path" ]]; then
                    echo -e "${RED}错误：未找到证书，请先申请！${PLAIN}"
                    pause; return
                fi
                alpn='["h3"]'
                sni_name="$domain"
                allow_insecure=false
            else
                # 自签名
                cert_path="/etc/sing-box/tuic.crt"
                key_path="/etc/sing-box/tuic.key"
                openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                    -keyout "$key_path" -out "$cert_path" -subj "/CN=tuic" -days 3650 &>/dev/null
                alpn='["h3"]'
                sni_name="tuic"
                allow_insecure=true
            fi
            save_and_restart '.inbounds += [{
                    "type":"tuic","tag":$t,"listen_port":'"$PORT"',"listen":"::",
                    "users":[{"uuid":"'"$UUID"'","password":"'"$PASS"'"}],
                    "tls":{"enabled":true,
                           "certificate_path":"'"$cert_path"'","key_path":"'"$key_path"'",
                           "alpn":'"$alpn"',"alpn_server_name":"'"$sni_name"'"}}
                }]' --arg t "$TAG"
            LINK="tuic://$UUID:$PASS@$IP:$PORT?alpn=h3&sni=$sni_name&allow_insecure=$allow_insecure#$TAG"
            ;;
        3)
            # Hysteria2
            TAG="hysteria2"
            read -r -p "端口: " PORT
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            read -r -p "密码: " PASS
            if [[ -z "$PASS" ]]; then
                echo -e "${RED}密码不能为空！${PLAIN}"
                pause; return
            fi
            TAG="${TAG}${PORT}"
            echo "1. 自签名证书 | 2. ACME 证书"
            read -r -p "选择证书类型: " cert_type
            local hysteria_cert hysteria_key hysteria_sni insecure_flag
            if [[ "$cert_type" == "2" ]]; then
                read -r -p "请输入域名 (对应已有证书): " domain
                if [[ -z "$domain" ]]; then echo -e "${RED}域名不能为空！${PLAIN}"; pause; return; fi
                hysteria_cert="$CERT_DIR/$domain/server.crt"
                hysteria_key="$CERT_DIR/$domain/server.key"
                if [[ ! -f "$hysteria_cert" ]]; then
                    echo -e "${RED}错误：未找到证书，请先申请！${PLAIN}"
                    pause; return
                fi
                insecure_flag=false
            else
                hysteria_cert="/etc/sing-box/hy2.crt"
                hysteria_key="/etc/sing-box/hy2.key"
                openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                    -keyout "$hysteria_key" -out "$hysteria_cert" -subj "/CN=hysteria2" -days 3650 &>/dev/null
                insecure_flag=true
            fi
            save_and_restart '.inbounds += [{
                    "type":"hysteria2","tag":$t,"listen_port":'"$PORT"',"listen":"::",
                    "users":[{"password":"'"$PASS"'"}],
                    "tls":{"enabled":true,
                           "certificate_path":"'"$hysteria_cert"'","key_path":"'"$hysteria_key"'"}}
                }]' --arg t "$TAG"
            LINK="hysteria2://$PASS@$IP:$PORT?insecure=$insecure_flag#$TAG"
            ;;
        4)
            # Shadowsocks (2022-blake3)
            TAG="ss"
            read -r -p "端口: " PORT
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            PASS=$(openssl rand -base64 16)
            local method="2022-blake3-aes-128-gcm"
            TAG="${TAG}${PORT}"
            save_and_restart '.inbounds += [{
                    "type":"shadowsocks","tag":$t,"listen_port":'"$PORT"',"listen":"::",
                    "method":"'"$method"'","password":"'"$PASS"'"
                }]' --arg t "$TAG"
            local ss_base64
            ss_base64=$(printf "%s:%s" "$method" "$PASS" | base64 -w 0)
            LINK="ss://$ss_base64@$IP:$PORT#$TAG"
            ;;
        5)
            # VLESS + WS + TLS (CloudFlare)
            echo -e "${CYAN}提醒：已假设 CloudFlare 隧道已配置并使用 CF 证书。${PLAIN}"
            read -r -p "CF 域名 (已解析到本机): " DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                echo -e "${RED}域名不能为空！${PLAIN}"
                pause; return
            fi
            local certfile keyfile
            certfile="$CERT_DIR/$DOMAIN/server.crt"
            keyfile="$CERT_DIR/$DOMAIN/server.key"
            if [[ ! -f "$certfile" ]]; then
                echo -e "${RED}错误：未找到 $DOMAIN 的证书，请先申请。${PLAIN}"
                pause; return
            fi
            read -r -p "端口: " PORT
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            read -r -p "WS 路径 (默认 /video): " WSPATH
            WSPATH=${WSPATH:-/video}
            TAG="vless-ws-$PORT"
            save_and_restart '.inbounds += [{
                    "type":"vless","tag":$t,"listen_port":'"$PORT"',"listen":"::",
                    "users":[{"uuid":"'"$UUID"'"}],
                    "transport":{"type":"ws","path":"'"$WSPATH"'"},
                    "tls":{"enabled":true,"server_name":"'"$DOMAIN"'",
                           "certificate_path":"'"$certfile"'","key_path":"'"$keyfile"'"}
                }]' --arg t "$TAG"
            LINK="vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&type=ws&path=$WSPATH#$TAG"
            ;;
        6)
            # Socks5
            TAG="socks"
            read -r -p "端口: " PORT
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            read -r -p "用户名: " USER
            read -r -p "密码: " PASS
            if [[ -z "$USER" || -z "$PASS" ]]; then
                echo -e "${RED}用户名或密码不能为空！${PLAIN}"
                pause; return
            fi
            TAG="${TAG}${PORT}"
            save_and_restart '.inbounds += [{
                    "type":"socks","tag":$t,"listen_port":'"$PORT"',"listen":"::",
                    "users":[{"username":"'"$USER"'","password":"'"$PASS"'"}]
                }]' --arg t "$TAG"
            LINK="socks5://$USER:$PASS@$IP:$PORT#$TAG"
            ;;
        *)
            echo -e "${RED}选择无效。${PLAIN}"
            pause
            return
            ;;
    esac

    # 保存并显示节点链接
    if [[ -n "${LINK-}" ]]; then
        mkdir -p "$LINK_DIR"
        echo "$LINK" > "$LINK_DIR/${TAG}.link"
        echo -e "${GREEN}节点已添加并保存链接！${PLAIN}"
        echo -e "分享链接：${CYAN}$LINK${PLAIN}"
        pause
    fi
}

# 管理已有配置 (查看/修改/删除)
manage_configs() {
    clear
    echo -e "${YELLOW}--- 管理节点配置 ---${PLAIN}"
    local count
    count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo "暂无入站节点。"
        pause; return
    fi

    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | nl -w2 -s'. '
    read -r -p "请选择序号 (q 返回): " idx
    [[ "$idx" == "q" ]] && return
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
        echo -e "${RED}选择无效！${PLAIN}"
        pause; return
    fi
    idx=$((idx-1))
    local tag
    tag=$(jq -r ".inbounds[$idx].tag" "$CONFIG_FILE")
    echo -e "\n1. 查看详情/链接 | 2. 修改端口 | 3. 删除配置"
    read -r -p "选择操作: " op
    case "$op" in
        1)
            # 查看 JSON 详情和分享链接
            local conf type port
            conf=$(jq ".inbounds[$idx]" "$CONFIG_FILE")
            type=$(echo "$conf" | jq -r .type)
            port=$(echo "$conf" | jq -r .listen_port)
            echo -e "\n${GREEN}================ 原始 JSON 配置 ================${PLAIN}"
            echo "$conf" | jq
            echo -e "${GREEN}===============================================${PLAIN}"
            echo -e "\n${YELLOW}>>>> 节点分享链接 <<<<${PLAIN}"
            if [[ -f "$LINK_DIR/${tag}.link" ]]; then
                echo -e "${CYAN}$(<"$LINK_DIR/${tag}.link")${PLAIN}"
            else
                # 根据配置尝试生成链接
                local UUID SNI SID WSPATH METHOD
                case "$type" in
                    vless)
                        UUID=$(echo "$conf" | jq -r '.users[0].uuid')
                        SNI=$(echo "$conf" | jq -r '.tls.server_name // empty')
                        SID=$(echo "$conf" | jq -r '.tls.reality.short_id[0] // empty')
                        WSPATH=$(echo "$conf" | jq -r '.transport.path // empty')
                        if [[ -n "$SID" ]]; then
                            echo -e "${RED}Reality 节点公钥不可用，无法生成完整链接。${PLAIN}"
                        else
                            echo -e "${CYAN}vless://$UUID@$IP:$port?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$tag${PLAIN}"
                        fi
                        ;;
                    tuic)
                        UUID=$(echo "$conf" | jq -r '.users[0].uuid')
                        PASS=$(echo "$conf" | jq -r '.users[0].password')
                        echo -e "${CYAN}tuic://$UUID:$PASS@$IP:$port?congestion_control=bbr#$tag${PLAIN}"
                        ;;
                    hysteria2)
                        PASS=$(echo "$conf" | jq -r '.users[0].password')
                        echo -e "${CYAN}hysteria2://$PASS@$IP:$port#$tag${PLAIN}"
                        ;;
                    shadowsocks)
                        METHOD=$(echo "$conf" | jq -r .method)
                        PASS=$(echo "$conf" | jq -r .password)
                        local ss_base64
                        ss_base64=$(printf "%s:%s" "$METHOD" "$PASS" | base64 -w 0)
                        echo -e "${CYAN}ss://$ss_base64@$IP:$port#$tag${PLAIN}"
                        ;;
                    *)
                        echo -e "${RED}不支持的类型: $type${PLAIN}"
                        ;;
                esac
            fi
            pause
            ;;
        2)
            # 修改端口
            read -r -p "新端口: " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || ((new_port<1||new_port>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            save_and_restart ".inbounds[$idx].listen_port = ($new_port|tonumber)"
            echo -e "${GREEN}端口已更新为 $new_port，请更新客户端配置。${PLAIN}"
            pause
            ;;
        3)
            # 删除配置
            jq "del(.inbounds[$idx])" "$CONFIG_FILE" > "$(mktemp)" \
                && mv "$(ls /tmp/tmp*.??*)" "$CONFIG_FILE"
            rm -f "$LINK_DIR/${tag}.link"
            echo -e "${GREEN}配置已删除（包括持久化链接）。${PLAIN}"
            systemctl restart sing-box
            pause
            ;;
        *)
            echo -e "${RED}操作无效！${PLAIN}"
            pause
            ;;
    esac
}

# 链式代理管理
chain_proxy() {
    clear
    echo -e "${YELLOW}--- 链式代理管理 ---${PLAIN}"
    echo "1. 添加链式转发"
    echo "2. 删除所有链式转发"
    echo "0. 返回"
    read -r -p "选择: " cp_choice
    case "$cp_choice" in
        0) return ;;
        1)
            # 添加链式转发
            local count
            count=$(jq '.inbounds | length' "$CONFIG_FILE")
            if [[ "$count" -eq 0 ]]; then
                echo "暂无节点可用作为链式起点。"
                pause; return
            fi
            jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | nl -w2 -s'. '
            read -r -p "选择入站节点序号作为起点: " idx
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
                echo -e "${RED}无效选择！${PLAIN}"
                pause; return
            fi
            idx=$((idx-1))
            local inbound_tag
            inbound_tag=$(jq -r ".inbounds[$idx].tag" "$CONFIG_FILE")
            read -r -p "远程服务器地址 (IP或域名): " R_ADDR
            if [[ -z "$R_ADDR" ]]; then
                echo -e "${RED}地址不能为空！${PLAIN}"
                pause; return
            fi
            read -r -p "远程端口: " R_PORT
            if ! [[ "$R_PORT" =~ ^[0-9]+$ ]] || ((R_PORT<1||R_PORT>65535)); then
                echo -e "${RED}端口无效！${PLAIN}"
                pause; return
            fi
            local out_tag="chain-out-$inbound_tag"
            save_and_restart '.outbounds += [{"type":"socks","tag":$o,"server":"'"$R_ADDR"'","server_port":'"$R_PORT"',"version":"5"}]
                | .route.rules = [{"inbound":[$i],"outbound":$o}] + .route.rules' \
                --arg i "$inbound_tag" --arg o "$out_tag"
            echo -e "${GREEN}链式转发已开启：$inbound_tag -> $R_ADDR:$R_PORT${PLAIN}"
            pause
            ;;
        2)
            # 删除所有链式转发
            save_and_restart '.route.rules = [] | .outbounds = (.outbounds | map(select(.tag | startswith("chain-out-") | not)))'
            echo -e "${GREEN}所有链式转发已清除。${PLAIN}"
            pause
            ;;
        *)
            echo -e "${RED}选择无效。${PLAIN}"
            pause
            ;;
    esac
}

# 更新脚本或 sing-box 内核
update_all() {
    auto_backup
    echo -e "${CYAN}请选择更新项:${PLAIN}"
    echo "1. 更新管理脚本 (ssb)"
    echo "2. 更新 sing-box 内核"
    echo "0. 返回"
    read -r -p "选择: " uc
    case "$uc" in
        0) return ;;
        1)
            echo -e "${CYAN}>>> 更新 ssb 脚本...${PLAIN}"
            curl -sSfL "$UPDATE_URL" -o /usr/local/bin/ssb
            chmod +x /usr/local/bin/ssb
            echo -e "${GREEN}脚本已更新，请重新运行。${PLAIN}"
            exit 0
            ;;
        2)
            echo -e "${CYAN}>>> 更新 sing-box...${PLAIN}"
            install_base
            ;;
        *)
            echo -e "${RED}选择无效。${PLAIN}"
            pause
            ;;
    esac
}

# 启用 BBR
enable_bbr() {
    echo -e "${YELLOW}>>> 检查并启用 BBR 网络加速${PLAIN}"
    local kernel
    kernel=$(uname -r | cut -d- -f1)
    if [[ $(echo -e "4.9\n$kernel" | sort -V | head -n1) != "4.9" ]]; then
        echo -e "${RED}当前内核 $kernel 不支持 BBR (需 >=4.9)${PLAIN}"
        pause; return
    fi
    if lsmod | grep -q bbr; then
        echo -e "${GREEN}BBR 已启用。${PLAIN}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p &>/dev/null || true
        if lsmod | grep -q bbr; then
            echo -e "${GREEN}BBR 已成功开启！${PLAIN}"
        else
            echo -e "${RED}BBR 启用失败。${PLAIN}"
        fi
    fi
    pause
}

# -------------------- 主菜单 --------------------
while true; do
    clear
    echo -e "--- ${YELLOW}sing-box 综合管理脚本 (ssb)${PLAIN} ---"
    show_status
    echo "--------------------------------"
    echo "1. 安装 / 重装 sing-box"
    echo "2. 节点配置 (VLESS/TUIC/Hy2/SS/Socks)"
    echo "3. 管理配置 (查看/修改端口/删除)"
    echo "4. 链式代理设置"
    echo "5. 更新脚本或内核"
    echo "6. 备份 / 还原"
    echo "7. 开启 BBR 网络加速"
    echo "8. 申请 SSL 域名证书 (ACME)"
    echo "77. 彻底卸载 sing-box"
    echo -e " \033[1;32m[88] 重启 sing-box 服务\033[0m"
    echo "0. 退出"
    read -r -p "选择 [0-88]: " num
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
            read -r -p "确定要卸载？此操作不可逆 (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${CYAN}正在卸载 sing-box...${PLAIN}"
                systemctl stop sing-box 2>/dev/null || true
                systemctl disable sing-box 2>/dev/null || true
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload
                rm -f /usr/local/bin/sing-box /usr/local/bin/ssb
                rm -rf /etc/sing-box
                echo -e "${GREEN}sing-box 及相关配置已彻底卸载。${PLAIN}"
                exit 0
            fi
            ;;
        88)
            echo -e "${CYAN}重启 sing-box 服务...${PLAIN}"
            systemctl restart sing-box
            sleep 1
            ;;
        0)
            echo -e "${GREEN}已退出脚本。${PLAIN}"
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请重新选择。${PLAIN}"
            sleep 1
            ;;
    esac
done