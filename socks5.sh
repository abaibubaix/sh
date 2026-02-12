#!/bin/bash

# ==============================================================================
# Socks5 (Xray) 单独安装脚本
# ==============================================================================

# 全局颜色定义
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# 调试模式
DEBUG=${DEBUG:-0}

# ==============================================================================
# 全局工具函数
# ==============================================================================

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${C_RED}[错误] 请使用 root 权限运行此脚本${C_RESET}"
        exit 1
    fi
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
        # 优先从本地获取
        local version
        version=$("$xray_binary_path" -version 2>/dev/null | head -n 1)
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    
    # 本地获取失败，则从网络获取
    curl -s --max-time 5 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | \
    grep -o '"tag_name":"[^"]*' | cut -d '"' -f 4 | head -1
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
    
    echo "正在安装 Xray..."
    local xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    local content
    content=$(curl -sL --max-time 10 "$xray_install_script_url" 2>/dev/null)
    if [[ -z "$content" || ! "$content" =~ "install-release" ]]; then
        echo -e "${C_RED}[✖] 无法下载 Xray 安装脚本${C_RESET}"
        return 1
    fi
    
    echo "$content" | bash -s -- install >/dev/null 2>&1
    echo "$content" | bash -s -- install-geodata >/dev/null 2>&1
    
    # 安装完成后获取版本号
    local latest_tag
    latest_tag=$(get_xray_version)
    echo "版本号: ${latest_tag:-Unknown}"
}

# ==============================================================================
# Socks5 相关函数
# ==============================================================================

socks5_install() {
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
    
    # 显示完整信息（新安装 + 已安装都显示）
    echo -e "${C_GREEN}[✔] Socks5 安装完成！${C_RESET}"
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

socks5_uninstall() {
    echo "开始卸载 Socks5..."
    systemctl stop xray-socks5.service 2>/dev/null
    systemctl disable xray-socks5.service 2>/dev/null
    rm -f "/etc/systemd/system/xray-socks5.service"
    systemctl daemon-reload
    rm -f /usr/local/etc/xray/socks5.json
    rm -rf "/etc/xrayL"
    echo -e "${C_GREEN}[✔] Socks5 已卸载完成${C_RESET}"
}

# ==============================================================================
# 主逻辑
# ==============================================================================

check_root

# 安装基础依赖
if ! command -v curl &>/dev/null; then
    echo "安装基础依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update >/dev/null 2>&1 && apt-get install -y curl wget tar >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl wget tar >/dev/null 2>&1
    fi
fi

# 处理命令行参数
if [[ "$1" == "--uninstall" ]]; then
    socks5_uninstall
    exit 0
else
    # 默认安装
    socks5_install
    exit 0
fi
