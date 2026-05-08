#!/bin/bash

set +e

# ---------- 颜色定义 ----------
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'
NC='\033[0m'

# ---------- 资源路径 ----------
GITHUB_RAW_URL="https://raw.githubusercontent.com/lje02/ssh/main/vps_manager.sh"
SINGBOX_INSTALL_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

# ---------- 基础环境清理 ----------
cleanup() {
    rm -f /tmp/vps_manager_latest.sh
}
trap cleanup EXIT

# 1. 提权检测
check_root() {
    if [[ $EUID -ne 0 ]]; then
        printf "${RED}错误：此脚本必须由 root 用户执行。${PLAIN}\n"
        exit 1
    fi
}

# 2. 系统识别
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_LIKE=$ID_LIKE
    else
        printf "${RED}无法检测系统类型${PLAIN}\n"
        exit 1
    fi

    case "$OS" in
        debian|ubuntu|kali|raspbian) OS_FAMILY="debian" ;;
        centos|rhel|fedora|rocky|alma) OS_FAMILY="rhel" ;;
        *)
            if [[ "$OS_LIKE" =~ (debian|ubuntu) ]]; then OS_FAMILY="debian"
            elif [[ "$OS_LIKE" =~ (rhel|fedora|centos) ]]; then OS_FAMILY="rhel"
            else printf "${RED}不支持的系统：$OS${PLAIN}\n"; exit 1; fi
            ;;
    esac
}

# 3. 依赖自动补齐
check_dependencies() {
    local deps=(
        "curl:curl"
        "jq:jq"
        "openssl:openssl"
        "ss:iproute2"
        "gawk:gawk"
        "realpath:coreutils"
        "diff:diffutils"
        "ssh-copy-id:openssh-client"
    )
    local missing_packages=()
    for item in "${deps[@]}"; do
        local cmd="${item%%:*}"
        local pkg="${item#*:}"
        if ! command -v "$cmd" &>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done
    if [ ${#missing_packages[@]} -ne 0 ]; then
        printf "${BLUE}正在补齐必要工具: ${missing_packages[*]}...${PLAIN}\n"
        if [ "$OS_FAMILY" = "debian" ]; then
            apt-get update -qq && apt-get install -y "${missing_packages[@]}" || {
                printf "${RED}依赖安装失败，请手动安装后重试${PLAIN}\n"
                exit 1
            }
        else
            yum install -y "${missing_packages[@]}" || {
                printf "${RED}依赖安装失败，请手动安装后重试${PLAIN}\n"
                exit 1
            }
        fi
    fi
}

# 4. 获取 SSH 端口
get_ssh_port() {
    local port
    port=$(ss -tlnp | grep -Po ':\d+ (?=.*sshd)' | head -1 | grep -Po '\d+')
    if [ -z "$port" ]; then
        port=$(grep -E "^#?Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    fi
    echo "${port:-22}"
}

# 5. 全局安装
install_self() {
    local install_path="/usr/local/bin/vps"
    if [[ "$1" == "--install" ]]; then
        check_root
        ln -sf "$(realpath "$0")" "$install_path"
        chmod +x "$install_path"
        printf "${GREEN}✔ 安装成功！现在输入 'vps' 即可启动面板。${PLAIN}\n"
        exit 0
    fi
}

# ==================== 远程管理模块（已修复 eval 风险） ====================
REMOTE_CONF="/etc/vps_manager_remotes.conf"
[ ! -f "$REMOTE_CONF" ] && touch "$REMOTE_CONF" && chmod 600 "$REMOTE_CONF"

setup_ssh_key() {
    local user=$1 ip=$2 port=$3
    [ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    printf "${YELLOW}正在尝试分发公钥 (仅需此次输入密码)...${PLAIN}\n"
    ssh-copy-id -p "$port" "$user@$ip"
}

delete_remote_host() {
    if [ ! -s "$REMOTE_CONF" ]; then
        printf "${RED}列表为空，无需删除。${PLAIN}\n"
        return
    fi
    printf "${YELLOW}选择要删除的主机编号:${PLAIN}\n"
    local i=1
    while IFS='|' read -r r_alias r_user r_ip r_port r_key; do
        printf "%d. %s (%s)\n" "$i" "$r_alias" "$r_ip"
        ((i++))
    done < "$REMOTE_CONF"
    read -p "请输入编号 (0取消): " del_num
    if [[ "$del_num" =~ ^[0-9]+$ ]] && [ "$del_num" -gt 0 ] && [ "$del_num" -lt "$i" ]; then
        sed -i "${del_num}d" "$REMOTE_CONF"
        printf "${GREEN}删除成功。${PLAIN}\n"
    fi
    sleep 1
}

add_remote_host() {
    clear
    printf "${BLUE}===== 添加远程主机 =====${PLAIN}\n"
    read -p "主机别名: " alias_name
    read -p "远程 IP: " r_ip
    read -p "SSH 端口 (默认 22): " r_port && r_port=${r_port:-22}
    read -p "用户名 (默认 root): " r_user && r_user=${r_user:-root}
    
    printf "\n1) 密码/已免密  2) 指定私钥路径\n"
    read -p "请选择: " auth_type
    if [[ "$auth_type" == "2" ]]; then
        read -p "请输入私钥路径: " key_path
        [ -f "$key_path" ] && echo "$alias_name|$r_user|$r_ip|$r_port|$key_path" >> "$REMOTE_CONF" || echo "$alias_name|$r_user|$r_ip|$r_port|none" >> "$REMOTE_CONF"
    else
        echo "$alias_name|$r_user|$r_ip|$r_port|none" >> "$REMOTE_CONF"
        read -p "配置免密登录? (y/n): " is_key
        [[ "$is_key" == "y" ]] && setup_ssh_key "$r_user" "$r_ip" "$r_port"
    fi
    printf "${GREEN}保存成功！${PLAIN}\n"
    sleep 1
}

remote_jump_menu() {
    while true; do
        clear
        printf "${GREEN}========== 远程 SSH 跳转中心 ==========${PLAIN}\n"
        if [ ! -s "$REMOTE_CONF" ]; then
            printf "${YELLOW}尚未添加任何远程主机。${PLAIN}\n"
        else
            # 使用索引数组存储字段，彻底避免 eval
            declare -a aliases users ips ports keys
            local i=1
            while IFS='|' read -r r_alias r_user r_ip r_port r_key; do
                printf "%2d. %-15s [%s@%s:%s]\n" "$i" "$r_alias" "$r_user" "$r_ip" "$r_port"
                aliases[$i]="$r_alias"
                users[$i]="$r_user"
                ips[$i]="$r_ip"
                ports[$i]="$r_port"
                keys[$i]="$r_key"
                ((i++))
            done < "$REMOTE_CONF"
            local max_index=$((i-1))
        fi
        printf "--------------------------------------\n"
        printf "a. 添加主机  d. 删除主机  0. 返回主菜单\n"
        read -p "选择编号: " choice
        case "$choice" in
            0) break ;;
            a) add_remote_host ;;
            d) delete_remote_host ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$max_index" ]; then
                    local u="${users[$choice]}" ip="${ips[$choice]}" p="${ports[$choice]}" k="${keys[$choice]}"
                    [[ "$k" != "none" ]] && ssh -i "$k" -p "$p" "$u@$ip" || ssh -p "$p" "$u@$ip"
                    break
                fi ;;
        esac
    done
}

# ==================== 防火墙管理 ====================
detect_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        printf "${GREEN}已安装 (UFW)${NC}\n"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        printf "${GREEN}已安装 (firewalld)${NC}\n"
    elif command -v iptables &>/dev/null; then
        printf "${YELLOW}已安装 (iptables)${NC}\n"
    else
        printf "${RED}未安装${NC}\n"
    fi
}

install_firewall() {
    printf "${BLUE}正在安装防火墙...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y ufw || {
            printf "${RED}UFW 安装失败${NC}\n"
            return
        }
        printf "${GREEN}UFW 安装完成${NC}\n"
    else
        yum install -y firewalld || {
            printf "${RED}firewalld 安装失败${NC}\n"
            return
        }
        systemctl start firewalld && systemctl enable firewalld
        printf "${GREEN}firewalld 安装完成${NC}\n"
    fi
}

enable_firewall() {
    if command -v ufw &>/dev/null; then
        ufw --force enable && systemctl enable ufw
        printf "${GREEN}UFW 已开启并设为开机自启${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        systemctl start firewalld && systemctl enable firewalld
        printf "${GREEN}firewalld 已开启并设为开机自启${NC}\n"
    else
        printf "${RED}未找到防火墙，请先安装${NC}\n"
    fi
}

open_all_ports() {
    local ssh_port=$(get_ssh_port)
    printf "${YELLOW}开放全部端口前，将先确保 SSH($ssh_port) 不被禁用${NC}\n"
    if command -v ufw &>/dev/null; then
        ufw default allow incoming
        ufw allow "$ssh_port"/tcp
        printf "${GREEN}UFW 默认策略已设为 ALLOW${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --set-default-zone=trusted
        firewall-cmd --zone=trusted --add-service=ssh --permanent
        firewall-cmd --reload
        printf "${GREEN}firewalld 默认区域已设为 trusted（全部放行）${NC}\n"
    elif command -v iptables &>/dev/null; then
        iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
        printf "${GREEN}iptables 默认策略已改为 ACCEPT${NC}\n"
    fi
}

close_all_ports() {
    local ssh_port=$(get_ssh_port)
    printf "${RED}⚠ 关闭全部端口可能导致你失去 SSH 连接！${NC}\n"
    read -p "是否保留 SSH 端口？(推荐保留) [Y/n]: " keep_ssh
    keep_ssh=${keep_ssh:-Y}
    local open_ssh=false
    [[ $keep_ssh =~ ^[Yy]$ ]] && open_ssh=true

    if command -v ufw &>/dev/null; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        $open_ssh && ufw allow "$ssh_port"/tcp
        ufw --force enable
        printf "${GREEN}UFW 已重置，所有入站端口已关闭${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --set-default-zone=public
        firewall-cmd --zone=public --remove-service=ssh --permanent 2>/dev/null
        $open_ssh && firewall-cmd --zone=public --add-port="${ssh_port}/tcp" --permanent
        firewall-cmd --reload
        printf "${GREEN}firewalld 默认区域已设为 public，仅开放必要端口${NC}\n"
    elif command -v iptables &>/dev/null; then
        iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT; iptables -F
        $open_ssh && iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        printf "${GREEN}iptables 已配置为 DROP 所有入站（SSH: $open_ssh）${NC}\n"
    fi
}

open_ports() {
    read -p "请输入要开放的端口（多个端口用空格分隔，支持范围如 1000:2000）：" ports
    [[ -z "$ports" ]] && printf "${RED}未输入任何端口${NC}\n" && return
    if command -v ufw &>/dev/null; then
        for port in $ports; do
            if [[ $port == *:* ]]; then
                ufw allow proto tcp to any port $port   # 注意：UFW 默认同时放行 tcp/udp，此处只放tcp，保持与iptables一致
            else
                ufw allow $port
            fi
        done
        printf "${GREEN}UFW 规则已添加${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        for port in $ports; do firewall-cmd --zone=public --add-port="${port}/tcp" --permanent; done
        firewall-cmd --reload
        printf "${GREEN}firewalld 端口已开放${NC}\n"
    elif command -v iptables &>/dev/null; then
        for port in $ports; do
            if [[ $port == *:* ]]; then
                start=$(echo $port | cut -d: -f1); end=$(echo $port | cut -d: -f2)
                iptables -A INPUT -p tcp --dport "${start}:${end}" -j ACCEPT
            else
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            fi
        done
        printf "${GREEN}iptables 规则已添加${NC}\n"
    fi
}

close_ports() {
    read -p "请输入要关闭的端口（多个端口用空格分隔）：" ports
    [[ -z "$ports" ]] && printf "${RED}未输入任何端口${NC}\n" && return
    if command -v ufw &>/dev/null; then
        for port in $ports; do ufw deny $port; done
        printf "${GREEN}UFW 拒绝规则已添加${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        for port in $ports; do firewall-cmd --zone=public --remove-port="${port}/tcp" --permanent; done
        firewall-cmd --reload
        printf "${GREEN}firewalld 端口已关闭${NC}\n"
    elif command -v iptables &>/dev/null; then
        for port in $ports; do iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true; done
        printf "${GREEN}iptables 规则已尝试删除${NC}\n"
    fi
}

show_firewall_status() {
    clear
    printf "${BLUE}===== 防火墙详细状态 =====${NC}\n"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        printf "${GREEN}UFW 状态:${NC}\n"
        ufw status verbose
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        printf "${GREEN}firewalld 状态:${NC}\n"
        firewall-cmd --state
        echo ""
        printf "默认区域: %s\n" "$(firewall-cmd --get-default-zone)"
        for zone in $(firewall-cmd --get-active-zones | grep -v "interfaces\|sources" | tr ' ' '\n' | grep -v '^$'); do
            printf "\n区域: %s\n" "$zone"
            firewall-cmd --zone="$zone" --list-all
        done
    elif command -v iptables &>/dev/null; then
        printf "${YELLOW}iptables 规则 (无上层管理工具):${NC}\n"
        iptables -L INPUT -n -v --line-numbers 2>/dev/null
        iptables -L FORWARD -n -v --line-numbers 2>/dev/null
        iptables -L OUTPUT -n -v --line-numbers 2>/dev/null
    else
        printf "${RED}未检测到活动的防火墙${NC}\n"
    fi
    echo ""
    read -p "按回车键继续..." dummy
}

firewall_menu() {
    while true; do
        clear
        printf "${BLUE}===== 防火墙 / Fail2Ban 管理 =====${NC}\n"
        printf "当前防火墙状态："; detect_firewall
        printf "当前 Fail2Ban 状态："; detect_fail2ban
        echo "--------------------------------------"
        echo "1. 安装防火墙"
        echo "2. 开启防火墙"
        echo "3. 开放全部端口"
        echo "4. 关闭全部端口"
        echo "5. 开放指定端口"
        echo "6. 关闭指定端口"
        echo "7. 查看防火墙详细状态"
        echo "--------------------------------------"
        echo "8. Fail2Ban 管理"
        echo "0. 返回上级菜单"
        read -p "请选择操作: " fw_choice
        case $fw_choice in
            1) install_firewall ;;
            2) enable_firewall ;;
            3) open_all_ports ;;
            4) close_all_ports ;;
            5) open_ports ;;
            6) close_ports ;;
            7) show_firewall_status ;;
            8) fail2ban_menu ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
        echo ""; read -p "按回车键继续..." dummy
    done
}

# ==================== Fail2Ban 管理 ===================
detect_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        systemctl is-active --quiet fail2ban && printf "${GREEN}已安装（运行中）${NC}\n" || printf "${YELLOW}已安装（未运行）${NC}\n"
    else
        printf "${RED}未安装${NC}\n"
    fi
}

install_fail2ban() {
    printf "${BLUE}正在安装 Fail2Ban...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y fail2ban iptables || {
            printf "${RED}Fail2Ban 安装失败${NC}\n"; return
        }
    else
        yum install -y epel-release && yum install -y fail2ban iptables || {
            printf "${RED}Fail2Ban 安装失败${NC}\n"; return
        }
    fi

    # 自动修复：如果系统使用 journald 且 auth.log 不存在，设置 sshd 后端为 systemd
    local jail_local="/etc/fail2ban/jail.local"
    [ ! -f "$jail_local" ] && cp /etc/fail2ban/jail.conf "$jail_local"

    if ! [ -f /var/log/auth.log ] && command -v journalctl &>/dev/null; then
        if grep -q '^\[sshd\]' "$jail_local"; then
            sed -i '/^\[sshd\]/,/^\[/ s/^backend.*/backend = systemd/' "$jail_local"
        else
            echo -e "[sshd]\nbackend = systemd" >> "$jail_local"
        fi
    fi

    # 启动服务
    if command -v systemctl &>/dev/null; then
        systemctl enable fail2ban && systemctl start fail2ban
    else
        chkconfig fail2ban on 2>/dev/null || update-rc.d fail2ban defaults 2>/dev/null
        service fail2ban start
    fi

    sleep 2
    if pgrep -x fail2ban-server &>/dev/null; then
        printf "${GREEN}Fail2Ban 安装完成并已启动${NC}\n"
    else
        printf "${RED}Fail2Ban 安装后未能启动，请检查日志: journalctl -u fail2ban${NC}\n"
    fi
}

show_ban_records() {
    if ! command -v fail2ban-client &>/dev/null; then printf "${RED}Fail2Ban 未安装${NC}\n"; return; fi
    printf "${BLUE}==== 拦截记录 ====${NC}\n"
    fail2ban-client status
    for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr -d ','); do
        printf "${GREEN}-- $jail --${NC}\n"; fail2ban-client status "$jail"; echo ""
    done
}

config_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then printf "${RED}Fail2Ban 未安装${NC}\n"; return; fi
    local conf_file="/etc/fail2ban/jail.local"
    [ ! -f "$conf_file" ] && cp /etc/fail2ban/jail.conf "$conf_file"
    read -p "封禁时长(秒, 默认600): " bantime; bantime=${bantime:-600}
    read -p "时间窗口(秒, 默认600): " findtime; findtime=${findtime:-600}
    read -p "最大尝试次数(默认5): " maxretry; maxretry=${maxretry:-5}
    sed -i "s/^bantime.*=.*/bantime = $bantime/" "$conf_file"
    sed -i "s/^findtime.*=.*/findtime = $findtime/" "$conf_file"
    sed -i "s/^maxretry.*=.*/maxretry = $maxretry/" "$conf_file"
    systemctl restart fail2ban
    printf "${GREEN}参数已更新，Fail2Ban 已重启${NC}\n"
}

uninstall_fail2ban() {
    read -p "确定要卸载 Fail2Ban 吗？[y/N] " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return
    systemctl stop fail2ban; systemctl disable fail2ban
    if [ "$OS_FAMILY" = "debian" ]; then apt-get purge -y fail2ban; else yum remove -y fail2ban; fi
    printf "${GREEN}Fail2Ban 已卸载${NC}\n"
}

fail2ban_menu() {
    while true; do
        clear
        printf "${BLUE}===== Fail2Ban 管理 =====${NC}\n"
        printf "当前状态："; detect_fail2ban
        echo "1. 安装 Fail2Ban"
        echo "2. 查看拦截记录"
        echo "3. 基础参数配置"
        echo "4. 卸载 Fail2Ban"
        echo "0. 返回上级菜单"
        read -p "请选择操作: " fb_choice
        case $fb_choice in
            1) install_fail2ban ;;
            2) show_ban_records ;;
            3) config_fail2ban ;;
            4) uninstall_fail2ban ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
        echo ""; read -p "按回车键继续..." dummy
    done
}

# ==================== 系统信息与优化 ====================
show_system_info() {
    clear
    printf "${BLUE}========== 系统信息 ==========${NC}\n"
    printf "主机名: %s\n" "$(hostname)"
    printf "操作系统: %s\n" "$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    printf "内核版本: %s\n" "$(uname -r)"
    printf "CPU 型号: %s\n" "$(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
    printf "CPU 核心数: %s\n" "$(nproc)"
    printf "内存: %s\n" "$(free -h | grep Mem | awk '{print $2}')"
    printf "磁盘使用: %s\n" "$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
    printf "运行时间: %s\n" "$(uptime -p)"

    printf "\n${BLUE}========== 网络信息 ==========${NC}\n"
    echo "=== 网卡地址 ==="
    ip -br addr | grep -v "lo"
    echo ""
    echo "=== 默认网关 ==="
    ip route | grep default
    echo ""
    echo "=== DNS 服务器 ==="
    cat /etc/resolv.conf | grep nameserver

    echo ""
    read -p "按回车键继续..." dummy
}

install_bbr() {
    clear
    printf "${BLUE}===== BBR 加速状态与设置 =====${NC}\n"
    local kernel_full=$(uname -r)
    local kernel_ver=$(echo "$kernel_full" | cut -d. -f1-2)
    printf "当前内核版本: %s\n" "$kernel_full"

    local current_cc
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    printf "当前拥塞控制算法: %s\n" "${current_cc:-未知}"
    printf "当前队列算法: %s\n" "$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || echo '未知')"

    if [ "$current_cc" = "bbr" ]; then
        printf "${GREEN}BBR 已启用！${NC}\n"
        read -p "按回车键返回..." dummy
        return
    fi

    # 检查内核版本是否 >= 4.9
    if ! printf '%s\n' "$kernel_ver" "4.9" | sort -V | head -1 | grep -q "4.9"; then
        printf "${RED}内核版本过低（当前 %s，需要 >= 4.9），不支持 BBR。${NC}\n" "$kernel_ver"
        read -p "按回车键返回..." dummy
        return
    fi

    printf "${YELLOW}BBR 未启用，是否立即开启？[Y/n]: ${NC}"
    read -p "" confirm
    if [[ ! $confirm =~ ^[Yy]?$ ]]; then
        return
    fi

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    if sysctl -p &>/dev/null; then
        printf "${GREEN}BBR 加速已激活！${NC}\n"
        printf "新拥塞控制算法: %s\n" "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
    else
        printf "${RED}sysctl 应用失败，请检查配置。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

config_swap() {
    clear
    printf "${BLUE}当前 Swap 状态：${NC}\n"; swapon --show; echo ""
    read -p "输入要创建的 Swap 大小 (MB) [例如 1024]，输入 0 取消: " swap_size
    [[ -z "$swap_size" || "$swap_size" -eq 0 ]] && return
    if [[ $swap_size =~ ^[0-9]+$ ]]; then
        if swapon --show | grep -q "swapfile"; then swapoff /swapfile; rm -f /swapfile; fi
        dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=progress
        chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        printf "${GREEN}Swap 创建成功，大小 ${swap_size}MB${NC}\n"
    else
        printf "${RED}输入的不是有效数字${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

#=============系统查看====================
system_opt_menu() {
    while true; do
        clear
        printf "${BLUE}===== 系统信息与优化 =====${NC}\n"
        echo "1. 查看系统与网络信息"
        echo "2. 安装/开启 BBR"
        echo "3. 虚拟内存配置 (Swap)"
        echo "0. 返回上级菜单"
        read -p "请选择: " opt_choice
        case $opt_choice in
            1) show_system_info ;;
            2) install_bbr ;;
            3) config_swap ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
    done
}

# ==================== 开机自启设置 ====================
autostart_menu() {
    while true; do
        clear
        printf "${BLUE}===== 开机自启设置 =====${NC}\n"
        echo "1. 防火墙开机自启 (UFW/firewalld)"
        echo "2. Fail2Ban 开机自启"
        echo "3. 开启所有服务自启"
        echo "0. 返回"
        read -p "请选择: " as_choice
        case $as_choice in
            1)
                if command -v ufw &>/dev/null; then systemctl enable ufw; printf "${GREEN}UFW 已设为开机自启${NC}\n"
                elif command -v firewall-cmd &>/dev/null; then systemctl enable firewalld; printf "${GREEN}firewalld 已设为开机自启${NC}\n"
                else printf "${RED}未安装防火墙${NC}\n"; fi ;;
            2)
                if command -v fail2ban-client &>/dev/null; then systemctl enable fail2ban; printf "${GREEN}Fail2Ban 已设为开机自启${NC}\n"
                else printf "${YELLOW}Fail2Ban 未安装${NC}\n"; fi ;;
            3)
                command -v ufw &>/dev/null && systemctl enable ufw
                command -v firewall-cmd &>/dev/null && systemctl enable firewalld
                command -v fail2ban-client &>/dev/null && systemctl enable fail2ban
                printf "${GREEN}已尝试为已安装的服务设置开机自启${NC}\n" ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
        read -p "按回车键继续..." dummy
    done
}

# ==================== sing-box 调用入口 ====================
run_singbox_menu() {
    if command -v ssb &>/dev/null; then
        ssb
    else
        printf "${YELLOW}sing-box 管理脚本未安装。${NC}\n"
        echo "你可以手动安装："
        echo "  curl -sSL $SINGBOX_INSTALL_URL | bash"
        read -p "是否现在自动安装并运行？[Y/n]: " confirm
        if [[ $confirm =~ ^[Yy]?$ ]]; then
            bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
                printf "${RED}sing-box 安装失败，请检查网络或仓库地址。${NC}\n"
                return
            }
            if command -v ssb &>/dev/null; then ssb
            else printf "${RED}安装后未找到 ssb 命令，请手动检查。${NC}\n"; fi
        fi
    fi
}

#==========更新卸载=================
update_script() {
    printf "${BLUE}正在从 GitHub 下载最新版本...${NC}\n"
    local tmpfile="/tmp/vps_manager_latest.sh"
    if curl -sL "$GITHUB_RAW_URL" -o "$tmpfile"; then
        # 解析真实脚本路径，避免符号链接被覆盖
        local real_script
        real_script=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
        if diff "$real_script" "$tmpfile" &>/dev/null; then
            printf "${GREEN}当前已是最新版本${NC}\n"; rm -f "$tmpfile"
        else
            chmod +x "$tmpfile"
            mv "$tmpfile" "$real_script"
            printf "${GREEN}脚本已更新，重新执行...${NC}\n"
            exec "$real_script" "$@"
        fi
    else
        printf "${RED}下载失败，请检查网络或仓库地址${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

uninstall_script() {
    read -p "确定要卸载此管理脚本吗？此操作不可恢复！[y/N] " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    printf "${YELLOW}正在删除脚本文件: $script_path${NC}\n"
    rm -f "$script_path"
    rm -f /usr/local/bin/vps 2>/dev/null
    printf "${GREEN}卸载完成，再见！${NC}\n"
    exit 0
}

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        clear
        printf "${GREEN}========== VPS 综合管理面板 (vps) ==========${PLAIN}\n"
        printf "${BLUE}--- 本地运维 ---${PLAIN}\n"
        echo -e "1. 防火墙/Fail2Ban 管理"
        echo -e "2. 系统信息与优化 (BBR/Swap)"
        echo -e "33. sing-box 安装/管理"
        printf "${BLUE}--- 远程管理 ---${PLAIN}\n"
        echo -e "4. 远程 SSH 管理"
        echo -e "--------------------------------------------"
        echo -e "u. 检查脚本更新  x. 卸载脚本  0. 退出"
        echo -e "--------------------------------------------"
        read -p "请输入选项: " main_choice

        case "$main_choice" in
            1) firewall_menu ;;
            2) system_opt_menu ;;
            33) run_singbox_menu ;;
            4) remote_jump_menu ;;
            u) update_script ;;
            x) uninstall_script ;;
            0) exit 0 ;;
            *) printf "${RED}无效选项${PLAIN}\n" && sleep 1 ;;
        esac
    done
}

# ---------- 启动程序 ----------
check_root
detect_os
check_dependencies
install_self "$1"
main_menu
