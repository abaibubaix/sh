#!/bin/bash

# ==============================================================================
# 三合一代理管理脚本 (Three-in-one Proxy Manager) - v1.3 (Smart Install)
# ==============================================================================

# 全局颜色定义
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# [新增] 全局变量：控制命令行模式
CLI_MODE=0

# 全局工具函数
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${C_RED}[错误] 请使用 root 权限运行此脚本 (sudo -i)${C_RESET}"
        exit 1
    fi
}

pause_key() {
    # [新增] 命令行模式跳过暂停
    if [[ "$CLI_MODE" -eq 1 ]]; then return; fi
    echo
    read -n 1 -s -r -p "按任意键继续..."
    echo
}

# ==============================================================================
# 模块 1: Multi-IP Socks5 (XrayL) - 函数定义
# ==============================================================================

m1_install_xray() {
    local BIN_PATH="/usr/local/bin/xrayL"
    local CONFIG_DIR="/etc/xrayL"
    local SERVICE_FILE="/etc/systemd/system/xrayL.service"
    
    # === 检测是否已安装 ===
    if [[ -f "$BIN_PATH" ]]; then
        echo -e "${C_YELLOW}检测到 Socks5 已安装，跳过安装步骤。${C_RESET}"
        return 0
    fi
    # ====================

    echo "正在安装 Socks5..."
    apt-get install -y unzip curl || yum install -y unzip curl
    
    # 下载核心
    wget -q --show-progress https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip -o Xray-linux-64.zip >/dev/null
    mv xray "$BIN_PATH"
    chmod +x "$BIN_PATH"

    cat <<EOF >"$SERVICE_FILE"
[Unit]
Description=XrayL Multi-IP Service
After=network.target

[Service]
ExecStart=$BIN_PATH -c $CONFIG_DIR/config.toml
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xrayL.service
    systemctl start xrayL.service

    rm -f Xray-linux-64.zip
#    echo "Socks5 安装完成."
}

m1_uninstall_xray() {
    echo "开始卸载 Socks5..."
    systemctl stop xrayL.service 2>/dev/null
    systemctl disable xrayL.service 2>/dev/null
    rm -f "/etc/systemd/system/xrayL.service"
    rm -f /etc/systemd/system/multi-user.target.wants/xrayL.service
    systemctl daemon-reload
    rm -f "/usr/local/bin/xrayL"
    rm -rf "/etc/xrayL"
    rm -f Xray-linux-64.zip
    echo "Socks5 已卸载完成"
}

m1_config_xray() {
    local CONFIG_DIR="/etc/xrayL"
    
    # --- 默认配置 ---
    local START_PORT=51665
    local USER="abai"
    local PASS="abai569"
    # ----------------
    
    # 重新获取IP列表
    local IPV4_LIST=()
    local IPV6_LIST=()

    
    # IPv4 检测逻辑
    while read ip; do
        [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168|127\.) ]] && continue
        if curl --interface "$ip" -s4 --max-time 3 ip.sb | grep -q "$ip"; then
            IPV4_LIST+=("$ip")
        fi
    done < <(ip -4 addr show scope global | awk '{print $2}' | cut -d/ -f1)

    # IPv4 NAT/Cloud
    local PUB_IPV4=$(curl -s4 --max-time 3 ip.sb | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$PUB_IPV4" ] && IPV4_LIST+=("$PUB_IPV4")

    # IPv6
    while read ip; do
        [[ "$ip" =~ ^(fd|fe80) ]] && continue
        if curl --interface "$ip" -s6 --max-time 3 ip.sb | grep -q ':'; then
            IPV6_LIST+=("$ip")
        fi
    done < <(ip -6 addr show scope global | awk '{print $2}' | cut -d/ -f1)

    # 去重
    IPV4_LIST=($(printf "%s\n" "${IPV4_LIST[@]}" | sort -u))
    IPV6_LIST=($(printf "%s\n" "${IPV6_LIST[@]}" | sort -u))

    mkdir -p "$CONFIG_DIR"
    echo -e "${C_GREEN}[✔] Socks5 安装完成！${C_RESET}"   
    echo -e "${C_YELLOW}使用默认配置：${C_RESET}"
    echo -e "${C_YELLOW}起始端口：$START_PORT 用户：$USER 密码：$PASS${C_RESET}"

    local config_content=""
    local index=0
    local all_ips=("${IPV4_LIST[@]}" "${IPV6_LIST[@]}")

    for ip in "${all_ips[@]}"; do
        local PORT=$((START_PORT + index))
        config_content+="[[inbounds]]\nport = $PORT\nprotocol = \"socks\"\ntag = \"tag_$index\"\n[inbounds.settings]\nauth = \"password\"\nudp = true\n[[inbounds.settings.accounts]]\nuser = \"$USER\"\npass = \"$PASS\"\n[[outbounds]]\nprotocol = \"freedom\"\ntag = \"tag_$index\"\n[[routing.rules]]\ntype = \"field\"\ninboundTag = \"tag_$index\"\noutboundTag = \"tag_$index\"\n\n"
        index=$((index + 1))
    done

    echo -e "$config_content" > "$CONFIG_DIR/config.toml"
    systemctl restart xrayL.service
    echo -e "\n${C_GREEN}=== Socks5 节点链接 ===${C_RESET}"
    index=0
    for ip in "${all_ips[@]}"; do
        local PORT=$((START_PORT + index))
        index=$((index + 1))
        if [[ "$ip" =~ ":" ]]; then
            printf "socks5://%s:%s@[%s]:%s\n" "$USER" "$PASS" "$ip" "$PORT"
        else
            printf "socks5://%s:%s@%s:%s\n" "$USER" "$PASS" "$ip" "$PORT"
        fi
    done
    echo -e "${C_GREEN}=============================${C_RESET}"
}

module_socks5_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== Multi-IP Socks5 ===${C_RESET}"
        echo "1. 安装Socks5"
        echo "2. 重置配置"
        echo "3. 卸载服务"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -p "请选择: " choice
        case $choice in
            1)
                m1_install_xray
                m1_config_xray
                pause_key
                ;;
            2)
                m1_config_xray
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
# 模块 2: Xray VLESS-Enc (官方核心) - 函数定义
# ==============================================================================

m2_log_error() { echo -e "${C_RED}[✖] $1${C_RESET}"; }
m2_log_info() { echo -e "${C_BLUE}[!] $1${C_RESET}"; }
m2_log_success() { echo -e "${C_GREEN}[✔] $1${C_RESET}"; }

m2_check_xray_version() {
    local xray_binary_path="/usr/local/bin/xray"
    [ -f "$xray_binary_path" ] || return 1
    "$xray_binary_path" help 2>/dev/null | grep -q "vlessenc" || return 1
    return 0
}

m2_get_public_ip() {
    curl -4s --max-time 4 https://api-ipv4.ip.sb/ip || curl -4s https://api.ipify.org
}

m2_restart_xray() {
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray
}

m2_execute_official_script() {
    local args="$1"
    local xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    local content
    content=$(curl -sL "$xray_install_script_url")
    if [[ -z "$content" || ! "$content" =~ "install-release" ]]; then
        m2_log_error "无法下载 Xray 安装脚本"
        return 1
    fi
    echo "$content" | bash -s -- $args
}

m2_install_xray() {
    local xray_config_path="/usr/local/etc/xray/config.json"
    local xray_binary_path="/usr/local/bin/xray"
    
    # --- 默认配置 ---
    local port=26201
    # ----------------
    
    # === 检测是否已安装 ===
    if [[ -f "$xray_binary_path" ]]; then
        echo -e "${C_YELLOW}检测到 VLESS-Enc 已安装，跳过安装步骤。${C_RESET}"
    else
        m2_log_info "安装 VLESS-Enc..."
        # 1. 安装核心
        if ! m2_execute_official_script "install"; then
             m2_log_error "核心安装失败"
             return 1
        fi
        m2_execute_official_script "install-geodata"
    fi
    # ====================

    # 2. 生成配置 (即使已安装，也运行一次以确保配置符合当前脚本要求)
    if ! m2_check_xray_version; then
        m2_log_error "当前 Xray 版本不支持 VLESS Encryption，请尝试更新。"
        return 1
    fi

    local uuid=$($xray_binary_path uuid)
    local vlessenc_output=$($xray_binary_path vlessenc)
    
    if [[ -z "$vlessenc_output" ]]; then
        m2_log_error "生成加密配置失败"
        return 1
    fi
    
    local decryption_config=$(echo "$vlessenc_output" | grep '"decryption":' | head -1 | cut -d'"' -f4)
    local encryption_config=$(echo "$vlessenc_output" | grep '"encryption":' | head -1 | cut -d'"' -f4)
    
    if [[ -z "$decryption_config" ]]; then
         m2_log_info "尝试备用解析..."
         decryption_config=$(echo "$vlessenc_output" | jq -r .decryption 2>/dev/null)
    fi

    if [[ -z "$decryption_config" ]]; then
         m2_log_error "无法解析 vlessenc 输出，请确保安装了支持该特性的 Xray。"
         echo "$vlessenc_output"
         return 1
    fi

    # 保存客户端需要的key
    echo "$encryption_config" > ~/xray_encryption_info.txt

    # 写入配置
    mkdir -p "$(dirname "$xray_config_path")"
    cat <<EOF > "$xray_config_path"
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
    
    if m2_restart_xray; then
        local ip=$(m2_get_public_ip)
        local link="vless://${uuid}@${ip}:${port}?encryption=${encryption_config}&flow=xtls-rprx-vision&type=tcp&security=none#VLESS-Enc"
	    echo -e "${C_GREEN}[✔] VLESS-Enc 安装完成！${C_RESET}"
		echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
        echo -e "\n${C_GREEN}=== VLESS-Enc 节点链接 ===${C_RESET}"
        echo "$link"
        echo "$link" > ~/xray_vless_link.txt
    else
        m2_log_error "启动失败，请检查日志 (journalctl -u xray)"
    fi
}

m2_uninstall_xray() {
    echo "正在卸载 VLESS-Enc..."
    m2_execute_official_script "remove --purge"
    rm -f ~/xray_vless_link.txt ~/xray_encryption_info.txt
    m2_log_success "卸载完成"
}

m2_view_info() {
    if [ -f ~/xray_vless_link.txt ]; then
        echo -e "${C_GREEN}上次生成的链接:${C_RESET}"
        cat ~/xray_vless_link.txt
    else
        m2_log_error "未找到链接文件，请重新安装或检查配置。"
    fi
}

module_vless_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== VLESS-Enc ===${C_RESET}"
        if systemctl is-active --quiet xray; then
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
            3) m2_restart_xray; m2_log_success "已重启"; pause_key ;;
            4) m2_uninstall_xray; pause_key ;;
            5) journalctl -u xray -n 20 --no-pager; pause_key ;;
            0) return ;;
            *) echo "无效选项"; pause_key ;;
        esac
    done
}

# ==============================================================================
# 模块 3: Shadowsocks-Rust 2022 - 函数定义
# ==============================================================================

m3_install_ss() {
    local INSTALL_DIR="/etc/ss-rust"
    local BINARY_PATH="/usr/local/bin/ss-rust"
    local CONFIG_PATH="${INSTALL_DIR}/config.json"
    local SERVICE_FILE="/etc/systemd/system/ss-rust.service"
    local TMP_DIR=$(mktemp -d)
    
    # === 检测是否已安装 ===
    if [[ -f "$BINARY_PATH" ]]; then
        echo -e "${C_YELLOW}检测到 SS-2022 已安装，跳过安装步骤。${C_RESET}"
        m3_view_config
        return 0
    fi
    # ====================

    # --- 默认配置 ---
    local port=26202
    local password="gZl9lxHUUZiI5gakkq3pDA=="
    # ----------------

    echo -e "${C_BLUE}[信息] 获取最新版本...${C_RESET}"
    local latest_tag=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    local version=${latest_tag#v}
    local arch
    case "$(uname -m)" in
        x86_64) arch="x86_64-unknown-linux-gnu" ;;
        aarch64) arch="aarch64-unknown-linux-gnu" ;;
        *) echo -e "${C_RED}不支持的架构${C_RESET}"; return 1 ;;
    esac

    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_tag}/shadowsocks-${latest_tag}.${arch}.tar.xz"
    
    echo "下载 Shadowsocks-Rust ${latest_tag}..."
    wget -q --show-progress -O "$TMP_DIR/ss.tar.xz" "$url"
    
    tar -xf "$TMP_DIR/ss.tar.xz" -C "$TMP_DIR"
    if [ ! -f "$TMP_DIR/ssserver" ]; then
        echo -e "${C_RED}解压失败${C_RESET}"
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    mv "$TMP_DIR/ssserver" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    
    mkdir -p "$INSTALL_DIR"
    rm -rf "$TMP_DIR"

    # 写入配置 (使用 2022-blake3-aes-128-gcm)
    cat <<EOF > "$CONFIG_PATH"
{
    "server": "::",
    "server_port": $port,
    "password": "$password",
    "method": "2022-blake3-aes-128-gcm",
    "fast_open": true,
    "mode": "tcp_and_udp"
}
EOF
    chmod 600 "$CONFIG_PATH"

    # 服务文件
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Shadowsocks-Rust Service
After=network.target

[Service]
ExecStart=$BINARY_PATH -c $CONFIG_PATH
Restart=on-failure
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ss-rust
    systemctl start ss-rust
    

    m3_view_config
}

m3_view_config() {
    local CONFIG_PATH="/etc/ss-rust/config.json"
    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${C_RED}[错误] 未找到配置文件${C_RESET}"
        return
    fi
    local port=$(grep '"server_port"' "$CONFIG_PATH" | tr -cd '0-9')
    local password=$(grep '"password"' "$CONFIG_PATH" | cut -d'"' -f4)
    local method="2022-blake3-aes-128-gcm"
    local ip=$(curl -s4 https://api.ipify.org)
    
    local link_str="${method}:${password}"
    local base64_str=$(echo -n "$link_str" | base64 -w 0)
    local link="ss://${base64_str}@${ip}:${port}#SS-2022"
    echo -e "${C_GREEN}[✔] SS-2022 安装完成！${C_RESET}"
	echo -e "${C_YELLOW}默认端口: $port${C_RESET}"
	echo -e "${C_YELLOW}默认密码: $password${C_RESET}"
    echo -e "\n${C_GREEN}=== SS-2022 节点链接 ===${C_RESET}"
    echo "$link"
    echo -e "${C_GREEN}====================${C_RESET}"
}

m3_uninstall_ss() {
    echo "卸载 SS-Rust..."
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f "/etc/systemd/system/ss-rust.service"
    systemctl daemon-reload
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/etc/ss-rust"
    echo -e "${C_GREEN}[成功] 已卸载${C_RESET}"
}

module_ssrust_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=== Shadowsocks-2022 ===${C_RESET}"
        if systemctl is-active --quiet ss-rust; then
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
            3) systemctl restart ss-rust; echo -e "${C_GREEN}已重启${C_RESET}"; pause_key ;;
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
    echo -e "${C_YELLOW}>>> 正在批量检测并安装服务...${C_RESET}"
    
    echo -e "\n${C_CYAN}[1/3] 检测 Socks5...${C_RESET}"
    m1_install_xray
    m1_config_xray
    
    echo -e "\n${C_CYAN}[2/3] 检测 VLESS-Enc...${C_RESET}"
    m2_install_xray
    
    echo -e "\n${C_CYAN}[3/3] 检测 Shadowsocks-2022...${C_RESET}"
    m3_install_ss
    
    echo -e "\n${C_GREEN}=== 所有操作执行完毕 ===${C_RESET}"
    pause_key
}

# ==============================================================================
# 主逻辑入口
# ==============================================================================

uninstall_all() {
    echo -e "${C_RED}警告: 即将卸载所有模块 (Socks5, VLESS-Enc, SS-2022)!${C_RESET}"
    
    # [新增] 命令行模式跳过确认
    if [[ "$CLI_MODE" -eq 0 ]]; then
        read -p "确定继续吗? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            echo "操作取消。"
            return
        fi
    fi

    # 暴力停止所有可能的服务
    systemctl stop xrayL xray ss-rust 2>/dev/null
    systemctl disable xrayL xray ss-rust 2>/dev/null
    
    rm -f /etc/systemd/system/xrayL.service
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/ss-rust.service
    systemctl daemon-reload
    
    rm -f /usr/local/bin/xrayL
    rm -f /usr/local/bin/xray
    rm -f /usr/local/bin/ss-rust
    
    rm -rf /etc/xrayL
    rm -rf /usr/local/etc/xray
    rm -rf /etc/ss-rust
    
    echo -e "${C_GREEN}所有组件已清理完毕。${C_RESET}"
}

check_root

# [新增] 处理命令行参数
if [[ -n "$1" ]]; then
    if [[ "$1" == "--8" ]]; then
        CLI_MODE=1
        install_all_services
        exit 0
    fi
    if [[ "$1" == "--9" ]]; then
        CLI_MODE=1
        uninstall_all
        exit 0
    fi
fi

# 安装基础依赖
if ! command -v curl &>/dev/null || ! command -v unzip &>/dev/null || ! command -v jq &>/dev/null; then
    echo "安装基础依赖 (curl, unzip, jq)..."
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y curl unzip jq wget tar openssl
    elif command -v yum &>/dev/null; then
        yum install -y curl unzip jq wget tar openssl
    fi
fi

while true; do
    clear
    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "${C_CYAN}   三合一代理脚本 (Merged Script)   ${C_RESET}"
    echo -e "${C_GREEN}==============================================${C_RESET}"
    echo -e "1. ${C_YELLOW}Socks5${C_RESET}"
    echo -e "2. ${C_YELLOW}VLESS-Enc${C_RESET}"
    echo -e "3. ${C_YELLOW}Shadowsocks-2022${C_RESET}"
    echo -e "----------------------------------------------"
    echo -e "8. ${C_GREEN}安装所有服务${C_RESET}"
    echo -e "9. ${C_RED}卸载所有服务${C_RESET}"
    echo -e "0. 退出脚本"
    echo -e "${C_GREEN}==============================================${C_RESET}"
    read -p "请输入选项: " main_choice

    case $main_choice in
        1) module_socks5_menu ;;
        2) module_vless_menu ;;
        3) module_ssrust_menu ;;
        8) install_all_services ;;
        9) uninstall_all; pause_key ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause_key ;;
    esac
done
