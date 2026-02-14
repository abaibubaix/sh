#!/bin/bash

# ==============================================================================
# 四合一代理管理脚本 (Four-in-one Proxy Manager)
# 优化版本 - 性能提升 - 本地版本号获取
# ==============================================================================

# 全局颜色定义
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# 全局变量：控制命令行模式
CLI_MODE=0

# 调试模式
DEBUG=${DEBUG:-0}

# 全局工具函数
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${C_RED}[错误] 请使用 root 权限运行此脚本 (sudo -i)${C_RESET}"
        exit 1
    fi
}

pause_key() {
    # 命令行模式跳过暂停
    if [[ "$CLI_MODE" -eq 1 ]]; then return; fi
    echo
    read -n 1 -s -r -p "按任意键继续..."
    echo
}

debug_log() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${C_CYAN}[DEBUG] $1${C_RESET}"
    fi
}

# ==============================================================================
# 统一公共函数 - 网络请求优化
# ==============================================================================

# 带重试的网络请求函数
get_with_retry() {
    local url=$1
    local max_attempts=3
    local attempt=1
    local timeout=4
    
    debug_log "请求URL: $url"
    
    while [ $attempt -le $max_attempts ]; do
        result=$(curl -4s --max-time $timeout "$url" 2>/dev/null)
        if [ -n "$result" ]; then
            debug_log "请求成功 (尝试 $attempt)"
            echo "$result"
            return 0
        fi
        debug_log "请求失败，重试 $attempt/$max_attempts"
        attempt=$((attempt + 1))
    done
    return 1
}

# 统一的IPv4获取函数
get_public_ip() {
    local ip
    ip=$(get_with_retry "https://api-ipv4.ip.sb/ip") && echo "$ip" && return 0
    ip=$(get_with_retry "https://api.ipify.org") && echo "$ip" && return 0
    echo ""
}

# IPv6获取函数
get_public_ipv6() {
    local ipv6
    ipv6=$(curl -6s --max-time 4 https://api.ipify.org 2>/dev/null)
    [ -n "$ipv6" ] && echo "$ipv6" || echo ""
}

# 获取本地Xray版本号
get_xray_version() {
    local xray_binary_path="/usr/local/bin/xray"
    
    if [[ -f "$xray_binary_path" ]]; then
        # 优先从本地获取 - 快速且准确
        local version
        version=$("$xray_binary_path" -version 2>/dev/null | head -n 1 | awk '{print $2}')
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    echo "Unknown"
}

# 获取本地SS-Rust版本号 (保留函数以兼容旧版检测)
get_ss_version() {
    local ss_binary_path="/usr/local/bin/ss-rust"
    
    if [[ -f "$ss_binary_path" ]]; then
        local version
        version=$("$ss_binary_path" -v 2>/dev/null | head -n 1)
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    return 1
}

# ==============================================================================
# 统一 Xray 核心安装函数
# ==============================================================================

install_xray_core() {
    local xray_binary_path="/usr/local/bin/xray"
    
    # 已安装则不重复安装核心
    if [[ -f "$xray_binary_path" ]]; then
        debug_log "Xray核心已存在，跳过安装"
        return 0
    fi
    
    local xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    local content
    content=$(curl -sL --max-time 10 "$xray_install_script_url" 2>/dev/null)
    if [[ -z "$content" || ! "$content" =~ "install-release" ]]; then
        echo -e "${C_RED}[✖] 无法下载 Xray 安装脚本${C_RESET}"
        return 1
    fi
    
    echo "$content" | bash -s -- install >/dev/null 2>&1
    echo "$content" | bash -s -- install-geodata >/dev/null 2>&1
}

# ==============================================================================
# 模块 0: Xray Reality - 函数定义（独立服务）
# ==============================================================================

m0_log_error() { echo -e "${C_RED}[✖] $1${C_RESET}"; }
m0_log_success() { echo -e "${C_GREEN}[✔] $1${C_RESET}"; }

m0_get_public_ip() {
    get_public_ip
}

m0_restart_xray_reality() {
    mkdir -p /etc/systemd/system
    cat <<'EOF' >/etc/systemd/system/xray-reality.service
[Unit]
Description=Xray Reality Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/reality.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray-reality
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-reality >/dev/null 2>&1
    systemctl restart xray-reality
    sleep 2 # 等待服务启动
    systemctl is-active --quiet xray-reality
}

m0_install_reality() {
    local xray_config_path="/usr/local/etc/xray/reality.json"

    # --- 默认配置 ---
    local port=26200
    local uuid="0e092eb5-7d41-484c-9c2b-e3a754376d2f"
    local flow="xtls-rprx-vision"
    local security="reality"
    local pbk="bNOXnPALN-eV9MvHqS-1nK0bi9sFfH35qwn7Z6NWZCo"
    local sid="6e6577"
    local sni="tesla.com"
    local fp="ios"
    local spider="%2F"
    # ----------------

    # 检测是否已安装
    if [[ -f "$xray_config_path" ]] && systemctl is-active --quiet xray-reality 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 VLESS-Reality 已安装，跳过安装步骤。${C_RESET}"
        local ip
        ip=$(m0_get_public_ip)
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
		echo ""
        echo -e "${C_GREEN}=== VLESS-Reality 节点链接 ===${C_RESET}"
        echo "vless://${uuid}@${ip}:${port}?encryption=none&flow=${flow}&security=${security}&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}&spx=${spider}&type=tcp#VLESS_Reality"
        echo ""
        return 0
    fi

    # 新安装：显示安装信息
    echo "正在安装 Xray 核心..."
    
    # 安装 Xray 核心
    if ! install_xray_core; then
        m0_log_error "核心安装失败"
        return 1
    fi
    
    # 显示版本号
    echo "版本号: $(get_xray_version)"

    echo "正在安装 VLESS-Reality..."
    mkdir -p "$(dirname "$xray_config_path")"
    cat > "$xray_config_path" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "::",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid", "flow": "$flow"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${sni}:443",
        "xver": 0,
        "serverNames": ["$sni"],
        "privateKey": "-OEfvIM5HGHMqGQ_eCEp8ZLMiR30A8j2Gylfh1Q3bkU",
        "shortIds": ["$sid"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    chmod 644 "$xray_config_path"

    if m0_restart_xray_reality; then
        local ip
        ip=$(m0_get_public_ip)
        local link="vless://${uuid}@${ip}:${port}?encryption=none&flow=${flow}&security=${security}&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}&spx=${spider}&type=tcp#VLESS_Reality"
        mkdir -p /root/four-in-one
        m0_log_success "VLESS-Reality 安装完成！"
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
		echo ""
        echo -e "${C_GREEN}=== VLESS-Reality 节点链接 ===${C_RESET}"
        echo "$link"
        echo ""
        echo "$link" > /root/four-in-one/xray_vless_reality_link.txt
    else
        m0_log_error "启动失败，请检查日志 (journalctl -u xray-reality)"
    fi
}

m0_view_info() {
    if [ -f /root/four-in-one/xray_vless_reality_link.txt ]; then
        cat /root/four-in-one/xray_vless_reality_link.txt
    else
        m0_log_error "未找到 Reality 链接，请先安装。"
    fi
}

module_reality_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== VLESS-Reality ===${C_RESET}"
        if systemctl is-active --quiet xray-reality; then
            echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
            echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装VLESS-Reality"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "5. 查看日志"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m0_install_reality; pause_key ;;
            2) m0_view_info; pause_key ;;
            3) m0_restart_xray_reality; m0_log_success "已重启"; pause_key ;;
            4) m0_uninstall_reality; pause_key ;;
            5) journalctl -u xray-reality -n 20 --no-pager; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

m0_uninstall_reality() {
    echo "正在卸载 VLESS-Reality..."
    systemctl stop xray-reality 2>/dev/null
    systemctl disable xray-reality 2>/dev/null
    rm -f /etc/systemd/system/xray-reality.service
    rm -f /usr/local/etc/xray/reality.json
    systemctl daemon-reload
    m0_log_success "卸载完成"
}

# ==============================================================================
# 模块 1: Socks5 (Xray) - 函数定义 - 优化版
# ==============================================================================

m1_install_xray() {
    local CONFIG_DIR="/etc/xrayL"
    local SERVICE_FILE="/etc/systemd/system/xray-socks5.service"
    local CONFIG_PATH="/usr/local/etc/xray/socks5.json"
    
    # --- 默认配置 ---
    local START_PORT=20264
    local USER="abai"
    local PASS="abai569"
    # ----------------
    
    # === 检测是否已安装 ===
    local ALREADY_INSTALLED=0
    if [[ -f "$SERVICE_FILE" ]]; then
        echo -e "${C_YELLOW}检测到 Socks5 已安装，跳过安装步骤。${C_RESET}"
        ALREADY_INSTALLED=1
    else
        # 新安装：安装 Xray 核心
        if ! install_xray_core; then
            echo -e "${C_RED}[✖] 核心安装失败${C_RESET}"
            return 1
        fi

        cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=Xray Socks5 Multi-IP Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/socks5.json
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable xray-socks5.service >/dev/null 2>&1
        
        # 显示安装信息（仅新安装）
        echo "正在安装 Socks5..."
		
    fi
    # ====================

    # 重新获取IP列表
    local IPV4_LIST=()
    local IPV6_LIST=()

    debug_log "开始检测IPv4地址..."
    while read ip; do
        [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168|127\.) ]] && continue
        if curl --interface "$ip" -s4 --max-time 3 ip.sb 2>/dev/null | grep -q "$ip"; then
            IPV4_LIST+=("$ip")
            debug_log "检测到IPv4: $ip"
        fi
    done < <(ip -4 addr show scope global | awk '{print $2}' | cut -d/ -f1)

    # IPv4 NAT/Cloud
    debug_log "检测公网IPv4..."
    local PUB_IPV4
    PUB_IPV4=$(curl -s4 --max-time 3 ip.sb 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$PUB_IPV4" ] && IPV4_LIST+=("$PUB_IPV4") && debug_log "检测到公网IPv4: $PUB_IPV4"

    # IPv6
    debug_log "开始检测IPv6地址..."
    while read ip; do
        [[ "$ip" =~ ^(fd|fe80) ]] && continue
        if curl --interface "$ip" -s6 --max-time 3 ip.sb 2>/dev/null | grep -q ':'; then
            IPV6_LIST+=("$ip")
            debug_log "检测到IPv6: $ip"
        fi
    done < <(ip -6 addr show scope global | awk '{print $2}' | cut -d/ -f1)

    # 去重
    IPV4_LIST=($(printf "%s\n" "${IPV4_LIST[@]}" | sort -u))
    IPV6_LIST=($(printf "%s\n" "${IPV6_LIST[@]}" | sort -u))

    mkdir -p "$(dirname "$CONFIG_PATH")"
    
    # 生成 Xray JSON 配置
    local inbounds="[]"
    local index=0
    local all_ips=("${IPV4_LIST[@]}" "${IPV6_LIST[@]}")

    for ip in "${all_ips[@]}"; do
        local PORT=$((START_PORT + index))
        local listen_addr="$ip"
        [[ "$ip" =~ ":" ]] && listen_addr="[$ip]"
        
        if [ $index -eq 0 ]; then
            inbounds="[{\"listen\": \"$listen_addr\", \"port\": $PORT, \"protocol\": \"socks\", \"settings\": {\"auth\": \"password\", \"accounts\": [{\"user\": \"$USER\", \"pass\": \"$PASS\"}]}}]"
        else
            inbounds="${inbounds%]},{\"listen\": \"$listen_addr\", \"port\": $PORT, \"protocol\": \"socks\", \"settings\": {\"auth\": \"password\", \"accounts\": [{\"user\": \"$USER\", \"pass\": \"$PASS\"}]}}]"
        fi
        index=$((index + 1))
    done

    cat > "$CONFIG_PATH" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": $inbounds,
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    chmod 644 "$CONFIG_PATH"
    
    systemctl restart xray-socks5.service >/dev/null 2>&1
    sleep 2 # 等待服务重启
    
    # 仅在新安装时显示“安装完成”
    if [[ "$ALREADY_INSTALLED" -eq 0 ]]; then
        echo -e "${C_GREEN}[✔] Socks5 安装完成！${C_RESET}"
    fi
    
    echo -e "${C_YELLOW}使用默认配置：${C_RESET}"
    echo "起始端口：$START_PORT 用户：$USER 密码：$PASS"
    
    if [ ${#all_ips[@]} -gt 0 ]; then
        echo -e "\n${C_GREEN}=== Socks5 节点链接 ===${C_RESET}"
        local idx=0
        for ip in "${all_ips[@]}"; do
            local PORT=$((START_PORT + idx))
            idx=$((idx + 1))
            if [[ "$ip" =~ ":" ]]; then
                printf "socks5://%s:%s@[%s]:%s\n" "$USER" "$PASS" "$ip" "$PORT"
            else
                printf "socks5://%s:%s@%s:%s\n" "$USER" "$PASS" "$ip" "$PORT"
            fi
        done
        echo ""
    fi
}

m1_uninstall_xray() {
    echo "开始卸载 Socks5..."
    systemctl stop xray-socks5.service 2>/dev/null
    systemctl disable xray-socks5.service 2>/dev/null
    rm -f "/etc/systemd/system/xray-socks5.service"
    systemctl daemon-reload
    rm -f "/usr/local/etc/xray/socks5.json"
    rm -rf "/etc/xrayL"
    echo "Socks5 已卸载完成"
}

module_socks5_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== Socks5 ===${C_RESET}"
        echo "1. 安装Socks5"
        echo "2. 重置配置"
        echo "3. 卸载服务"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1)
                m1_install_xray
                pause_key
                ;;
            2)
                m1_install_xray
                pause_key
                ;;
            3)
                m1_uninstall_xray
                pause_key
                ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 模块 2: Xray VLESS-Enc (官方核心) - 函数定义（独立服务）
# ==============================================================================

m2_log_error() { echo -e "${C_RED}[✖] $1${C_RESET}"; }
m2_log_info() { echo -e "${C_BLUE}[!] $1${C_RESET}"; }
m2_log_success() { echo -e "${C_GREEN}[✔] $1${C_RESET}"; }

m2_check_xray_version() {
    local xray_binary_path="/usr/local/bin/xray"
    [ -f "$xray_binary_path" ] || return 1
    # 直接假定支持（避免 grep help 误报）
    return 0
}

m2_get_public_ip() {
    get_public_ip
}

m2_restart_xray_vlessenc() {
    mkdir -p /etc/systemd/system
    cat <<'EOF' >/etc/systemd/system/xray-vlessenc.service
[Unit]
Description=Xray VLESS-Enc Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/vlessenc.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray-vlessenc
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-vlessenc >/dev/null 2>&1
    systemctl restart xray-vlessenc
    sleep 2 # 等待服务启动
    systemctl is-active --quiet xray-vlessenc
}

m2_install_xray() {
    local xray_config_path="/usr/local/etc/xray/vlessenc.json"
    
    # --- 默认配置 ---
    local port=26201
    local uuid="0e092eb5-7d41-484c-9c2b-e3a754376d2f"
    local decryption_config="mlkem768x25519plus.native.600s.6JN17BDd2jpmFfBWQ1eDVrmp3iA0yOdVx3zD7wPuQ3Y"
    local encryption_config="mlkem768x25519plus.native.0rtt.AVkBW8-SWZDmk50sRAQ9BvrEjG3KZaYNSoK_fyMwz2M"
    # ----------------

    # 检测是否已安装
    if [[ -f "$xray_config_path" ]] && systemctl is-active --quiet xray-vlessenc 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 VLESS-Enc 已安装，跳过安装步骤。${C_RESET}"
        local ip
        ip=$(m2_get_public_ip)
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
		echo ""
        echo -e "${C_GREEN}=== VLESS-Enc 节点链接 ===${C_RESET}"
        local link="vless://${uuid}@${ip}:${port}?encryption=${encryption_config}&flow=xtls-rprx-vision&type=tcp&security=none#VLESS-Enc"
        echo "$link"
        echo ""
        return 0
    fi
    
    # 新安装：显示安装信息
    echo "正在安装 VLESS-Enc..."
    
    # 安装 Xray 核心
    if ! install_xray_core; then
        m2_log_error "核心安装失败"
        return 1
    fi

    # 检查版本支持 (已移除过时检测)
    if ! m2_check_xray_version; then
        m2_log_error "当前 Xray 版本不支持 VLESS Encryption，请尝试更新。"
        return 1
    fi

    # 保存客户端需要的key
    mkdir -p /root/four-in-one
    echo "$encryption_config" > /root/four-in-one/xray_encryption_info.txt

    # 写入配置
    mkdir -p "$(dirname "$xray_config_path")"
    cat > "$xray_config_path" <<EOF
{
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
            "decryption": "$decryption_config"
        },
        "streamSettings": { "network": "tcp" }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF
    chmod 644 "$xray_config_path"
    
    if m2_restart_xray_vlessenc; then
        local ip
        ip=$(m2_get_public_ip)
        local link="vless://${uuid}@${ip}:${port}?encryption=${encryption_config}&flow=xtls-rprx-vision&type=tcp&security=none#VLESS-Enc"
        m2_log_success "VLESS-Enc 安装完成！"
        echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
        echo -e "\n${C_GREEN}=== VLESS-Enc 节点链接 ===${C_RESET}"
        echo "$link"
        echo ""
        mkdir -p /root/four-in-one
        echo "$link" > /root/four-in-one/xray_vless_encryption_link.txt
    else
        m2_log_error "启动失败，请检查日志 (journalctl -u xray-vlessenc)"
    fi
}

m2_uninstall_xray() {
    echo "正在卸载 VLESS-Enc..."
    systemctl stop xray-vlessenc 2>/dev/null
    systemctl disable xray-vlessenc 2>/dev/null
    rm -f /etc/systemd/system/xray-vlessenc.service
    rm -f /usr/local/etc/xray/vlessenc.json
    systemctl daemon-reload
    m2_log_success "卸载完成"
}

m2_view_info() {
    if [ -f /root/four-in-one/xray_vless_encryption_link.txt ]; then
        echo -e "${C_GREEN}上次生成的链接:${C_RESET}"
        cat /root/four-in-one/xray_vless_encryption_link.txt
    else
        m2_log_error "未找到链接文件，请重新安装或检查配置。"
    fi
}

module_vless_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== VLESS-Enc ===${C_RESET}"
        if systemctl is-active --quiet xray-vlessenc; then
             echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
             echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装VLESS-Enc"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "5. 查看日志"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m2_install_xray; pause_key ;;
            2) m2_view_info; pause_key ;;
            3) m2_restart_xray_vlessenc; m2_log_success "已重启"; pause_key ;;
            4) m2_uninstall_xray; pause_key ;;
            5) journalctl -u xray-vlessenc -n 20 --no-pager; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 模块 3: Shadowsocks-2022 (Xray 核心) - 函数定义
# ==============================================================================

m3_install_ss() {
    local CONFIG_PATH="/usr/local/etc/xray/ss2022.json"
    local SERVICE_FILE="/etc/systemd/system/xray-ss2022.service"
    
    # === 检测是否已安装 ===
    if [[ -f "$CONFIG_PATH" ]] && systemctl is-active --quiet xray-ss2022 2>/dev/null; then
        echo -e "${C_YELLOW}检测到 SS-2022 (Xray) 已安装，跳过安装步骤。${C_RESET}"
        m3_view_config
        return 0
    fi
    # ====================

    # --- 默认配置 ---
    local port=26202
    local password="gZl9lxHUUZiI5gakkq3pDA=="
    local method="2022-blake3-aes-128-gcm"
    # ----------------

    echo "正在安装 SS-2022 (Xray 核心)..."
    
    # 安装 Xray 核心
    if ! install_xray_core; then
        echo -e "${C_RED}[✖] 核心安装失败${C_RESET}"
        return 1
    fi
    
    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 写入配置 (Xray 格式，移除不支持的 settings.network 字段)
    cat <<EOF > "$CONFIG_PATH"
{
    "log": {"loglevel": "warning"},
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "shadowsocks",
        "settings": {
            "method": "$method",
            "password": "$password"
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    chmod 644 "$CONFIG_PATH"

    # 服务文件
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Xray Shadowsocks-2022 Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config $CONFIG_PATH
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-ss2022 >/dev/null 2>&1
    
    # 启动服务并检查
    systemctl restart xray-ss2022 >/dev/null 2>&1
    sleep 2 # 等待服务启动
    
    if systemctl is-active --quiet xray-ss2022; then
        debug_log "SS-2022 服务启动成功"
        echo -e "${C_GREEN}[✔] SS-2022 (Xray) 安装完成！${C_RESET}"
    else
        echo -e "${C_RED}[✖] SS-2022 服务启动失败，请检查日志${C_RESET}"
        return 1
    fi

    m3_view_config
}

m3_view_config() {
    local CONFIG_PATH="/usr/local/etc/xray/ss2022.json"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${C_RED}[错误] 未找到配置文件${C_RESET}"
        return
    fi
    
    local port
    port=$(grep '"port"' "$CONFIG_PATH" | tr -cd '0-9')
    local password
    password=$(grep '"password"' "$CONFIG_PATH" | cut -d'"' -f4)
    local method
    method=$(grep '"method"' "$CONFIG_PATH" | cut -d'"' -f4)
    
    local ip
    ip=$(get_public_ip)
    
    local link_str="${method}:${password}"
    local base64_str
    base64_str=$(echo -n "$link_str" | base64 -w 0)
    local link="ss://${base64_str}@${ip}:${port}#SS-2022-Xray"
    
    echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
    echo -e "${C_YELLOW}默认密码: $password${C_RESET}"
    echo -e "\n${C_GREEN}=== SS-2022 节点链接 ===${C_RESET}"
    echo "$link"
    echo ""
}

m3_uninstall_ss() {
    echo "卸载 SS-2022 (Xray)..."
    systemctl stop xray-ss2022 2>/dev/null
    systemctl disable xray-ss2022 2>/dev/null
    rm -f "/etc/systemd/system/xray-ss2022.service"
    systemctl daemon-reload
    rm -f "/usr/local/etc/xray/ss2022.json"
    # 同时清理可能的旧版残留
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f "/etc/systemd/system/ss-rust.service"
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/etc/ss-rust"
    echo -e "${C_GREEN}[成功] 已卸载${C_RESET}"
}

module_ssrust_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== Shadowsocks-2022 (Xray) ===${C_RESET}"
        if systemctl is-active --quiet xray-ss2022; then
             echo -e "状态: ${C_GREEN}运行中${C_RESET}"
        else
             echo -e "状态: ${C_RED}未运行${C_RESET}"
        fi
        echo "1. 安装SS-2022"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 卸载服务"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1) m3_install_ss; pause_key ;;
            2) m3_view_config; pause_key ;;
            3) systemctl restart xray-ss2022; echo -e "${C_GREEN}已重启${C_RESET}"; pause_key ;;
            4) m3_uninstall_ss; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 一键安装所有服务
# ==============================================================================
install_all_services() {
    clear
    echo -e "${C_YELLOW}>>> 开始安装服务...${C_RESET}"

    m0_install_reality
    m2_install_xray
    m3_install_ss
    m1_install_xray

    echo -e "${C_GREEN}>>> 服务全部安装${C_RESET}"
    pause_key
}

# ==============================================================================
# 主逻辑入口
# ==============================================================================

uninstall_all() {
    echo -e "${C_RED}警告: 即将卸载所有模块 (VLESS-Reality, VLESS-Enc, SS-2022, Socks5)!${C_RESET}"
    
    # 命令行模式跳过确认
    if [[ "$CLI_MODE" -eq 0 ]]; then
        read -p "确定继续吗? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            echo "操作取消。"
            return
        fi
    fi

    # 暴力停止所有可能的服务 (包括新的 xray-ss2022 和旧的 ss-rust)
    systemctl stop xray-reality xray-vlessenc xray-socks5 xray-ss2022 ss-rust 2>/dev/null
    systemctl disable xray-reality xray-vlessenc xray-socks5 xray-ss2022 ss-rust 2>/dev/null
    
    rm -f /etc/systemd/system/xray-reality.service
    rm -f /etc/systemd/system/xray-vlessenc.service
    rm -f /etc/systemd/system/xray-socks5.service
    rm -f /etc/systemd/system/xray-ss2022.service
    rm -f /etc/systemd/system/ss-rust.service
    systemctl daemon-reload
    
    # 彻底卸载 xray 核心（用官方脚本）
    if command -v /usr/local/bin/xray &>/dev/null; then
        local xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        local content
        content=$(curl -sL "$xray_install_script_url" 2>/dev/null)
        if [[ -n "$content" ]]; then
            echo "$content" | bash -s -- remove --purge >/dev/null 2>&1
        else
            rm -f /usr/local/bin/xray
            rm -rf /usr/local/etc/xray
            rm -rf /usr/local/share/xray
        fi
    fi
    
    rm -f /usr/local/bin/ss-rust
    rm -rf /etc/ss-rust
    rm -rf /etc/xrayL
    rm -rf /root/four-in-one
    
    echo -e "${C_GREEN}所有组件已清理完毕。${C_RESET}"
}

check_root

# 处理命令行参数
if [[ -n "$1" ]]; then
    case "$1" in
        --1)
            CLI_MODE=1
            m0_install_reality
            exit 0
            ;;
        --2)
            CLI_MODE=1
            m2_install_xray
            exit 0
            ;;
        --3)
            CLI_MODE=1
            m3_install_ss
            exit 0
            ;;
        --4)
            CLI_MODE=1
            m1_install_xray
            exit 0
            ;;
        --8)
            CLI_MODE=1
            install_all_services
            exit 0
            ;;
        --9)
            CLI_MODE=1
            uninstall_all
            exit 0
            ;;
    esac
fi

# 安装基础依赖
if ! command -v curl &>/dev/null || ! command -v unzip &>/dev/null; then
    echo "安装基础依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update >/dev/null 2>&1 && apt-get install -y curl unzip wget tar openssl >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl unzip wget tar openssl >/dev/null 2>&1
    fi
fi
# ============= 新增：时间同步检查 =============
echo "检查时间同步服务..."
if ! command -v chronyc &>/dev/null; then
    echo "安装 chrony 时间同步服务..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y chrony >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y chrony >/dev/null 2>&1
    fi
fi
# 启动 chrony 服务
systemctl start chrony >/dev/null 2>&1
systemctl enable chrony >/dev/null 2>&1
echo "✓ 时间同步服务已就绪"
# ============================================

while true; do
    clear
    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "${C_CYAN}   四合一代理脚本 (Four-in-one Script)   ${C_RESET}"
    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "1. ${C_YELLOW}VLESS-Reality${C_RESET}"
    echo -e "2. ${C_YELLOW}VLESS-Enc${C_RESET}"
    echo -e "3. ${C_YELLOW}SS-2022${C_RESET}"
    echo -e "4. ${C_YELLOW}Socks5${C_RESET}"
    echo -e "----------------------------------------------"
    echo -e "8. ${C_GREEN}安装所有服务${C_RESET}"
    echo -e "9. ${C_RED}卸载所有服务${C_RESET}"
    echo -e "0. 退出脚本"
    echo -e "${C_GREEN}==============================================${C_RESET}"
    read -p "请输入选项: " main_choice

    case $main_choice in
        1) module_reality_menu ;;
        2) module_vless_menu ;;
        3) module_ssrust_menu ;;
        4) module_socks5_menu ;;
        8) install_all_services ;;
        9) uninstall_all; pause_key ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause_key ;;
    esac
done
