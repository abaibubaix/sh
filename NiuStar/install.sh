#!/bin/bash

INSTALL_DIR="/etc/gost"

# 镜像加速，推荐 moeyy.cn，也可换成 mirror.ghproxy.com
BASE_GOST_REPO_API="https://github.moeyy.cn/https://api.github.com/repos/go-gost/gost/releases/latest"
STATIC_BASE="https://panel-static.199028.xyz/network-panel"

AGENT_BIN="/usr/local/bin/flux-agent"
GITHUB_DL_BASE="https://github.moeyy.cn/https://github.com/NiuStar/network-panel/releases/latest/download"

SOURCE_MODE="global"
PROXY_PREFIX=""

# 自动安装 jq 依赖
if ! command -v jq >/dev/null 2>&1; then
  echo "⚡ 自动安装 jq 工具..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y jq
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq
  elif command -v apk >/dev/null 2>&1; then
    apk add jq
  else
    echo "❌ 请手动安装 jq 工具"
    exit 1
  fi
fi

init_source_mode() {
  echo "📡 下载源模式: $SOURCE_MODE"
}

build_candidate_urls() {
  local kind="$1" file="$2"
  local urls=()
  case "$kind" in
    flux-agent)
      urls+=("${STATIC_BASE}/flux-agent/${file}")
      urls+=("${GITHUB_DL_BASE}/${file}")
      [[ -n "$PROXY_PREFIX" ]] && urls+=("${PROXY_PREFIX}${GITHUB_DL_BASE}/${file}")
      ;;
    script)
      urls+=("${STATIC_BASE}/${file}")
      urls+=("${GITHUB_DL_BASE}/${file}")
      [[ -n "$PROXY_PREFIX" ]] && urls+=("${PROXY_PREFIX}${GITHUB_DL_BASE}/${file}")
      ;;
  esac
  printf '%s\n' "${urls[@]}" | awk '!seen[$0]++ && NF {print}'
}

download_from_urls() {
  local target="$1"; shift
  local url
  for url in "$@"; do
    [[ -z "$url" ]] && continue
    echo "尝试: $url"
    if curl -fSL --retry 3 --retry-delay 1 "$url" -o "$target"; then
      return 0
    fi
  done
  return 1
}

resolve_latest_gost_url() {
  local arch="$(uname -m)"
  local token=""
  case "$arch" in
    x86_64|amd64) token="amd64" ;;
    aarch64|arm64) token="arm64" ;;
    armv7l|armv7|armhf) token="armv7" ;;
    i386|i686) token="386" ;;
    mips64el) token="mips64le" ;;
    mipsel) token="mipsle" ;;
    mips) token="mips" ;;
    loongarch64) token="loong64" ;;
    riscv64) token="riscv64" ;;
    s390x) token="s390x" ;;
    *) token="amd64" ;;
  esac
  local api="$BASE_GOST_REPO_API"
  local urls=$(curl -fsSL "$api" | jq -r '.assets[].browser_download_url' 2>/dev/null || true)
  for u in $urls; do
    if [[ "$u" == *linux* && "$u" == *$token* && "$u" == *.tar.gz ]]; then
      echo "$u"
      return 0
    fi
  done
  echo "❌ 无法解析最新 GOST 下载地址"
  return 1
}

download_and_install_gost() {
  local url="$1"
  local tmpdir; tmpdir=$(mktemp -d)
  echo "⬇️ 下载 GOST: $url"
  if ! curl -fSL --retry 3 --retry-delay 1 "$url" -o "$tmpdir/pkg"; then
    echo "❌ 下载失败: $url"; rm -rf "$tmpdir"; return 1
  fi
  mkdir -p "$INSTALL_DIR"
  tar -xzf "$tmpdir/pkg" -C "$tmpdir"
  local bin
  bin=$(find "$tmpdir" -type f -name gost -perm -111 | head -n1 || true)
  if [[ -z "$bin" ]]; then bin=$(find "$tmpdir" -type f -name gost | head -n1 || true); fi
  if [[ -z "$bin" ]]; then echo "❌ 未在压缩包内找到 gost"; rm -rf "$tmpdir"; return 1; fi
  install -m 0755 "$bin" "$INSTALL_DIR/gost"
  rm -rf "$tmpdir"
  echo "🔎 安装完成，版本：$($INSTALL_DIR/gost -V || true)"
}

install_flux_agent() {
  echo "🛠️ 安装 Go 诊断 Agent..."
  mkdir -p "$INSTALL_DIR"
  local arch="$(uname -m)" os="linux" file=""
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    FreeBSD) os="freebsd" ;;
  esac
  case "$arch" in
    x86_64|amd64) file="flux-agent-${os}-amd64" ;;
    aarch64|arm64) file="flux-agent-${os}-arm64" ;;
    armv7l|armv7|armhf) file="flux-agent-${os}-armv7" ;;
    *) file="flux-agent-${os}-amd64" ;;
  esac
  local AGENT_FILE="$INSTALL_DIR/flux-agent"
  local urls=()
  while read -r u; do urls+=("$u"); done < <(build_candidate_urls "flux-agent" "$file")
  local tmpfile
  tmpfile=$(mktemp -p /tmp flux-agent.XXXX || echo "/tmp/flux-agent.tmp")
  if download_from_urls "$tmpfile" "${urls[@]}"; then
    install -m 0755 "$tmpfile" "$AGENT_FILE" && rm -f "$tmpfile"
  else
    echo "❌ 无法下载 flux-agent 二进制"
    return 1
  fi
  # 写 systemd 服务
  cat > "/etc/systemd/system/flux-agent.service" <<EOF
[Unit]
Description=Flux Diagnose Go Agent
After=network-online.target gost.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$AGENT_FILE
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable flux-agent >/dev/null 2>&1 || true
  systemctl start flux-agent >/dev/null 2>&1 || true
  echo "✅ Go Agent 安装并启用 (flux-agent.service)"
}

get_config_params() {
  if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
    echo "请输入配置参数："
    if [[ -z "$SERVER_ADDR" ]]; then read -p "服务器地址: " SERVER_ADDR; fi
    if [[ -z "$SECRET" ]]; then read -p "密钥: " SECRET; fi
    if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
      echo "❌ 参数不完整，操作取消。"
      exit 1
    fi
  fi
}

install_gost() {
  echo "🚀 开始安装 GOST..."
  get_config_params
  mkdir -p "$INSTALL_DIR"
  [[ -f "$INSTALL_DIR/gost" ]] && rm -f "$INSTALL_DIR/gost"
  echo "⬇️ 解析最新 GOST 下载地址..."
  local GOST_URL
  GOST_URL=$(resolve_latest_gost_url) || { echo "❌ 无法解析最新 GOST 下载地址"; exit 1; }
  download_and_install_gost "$GOST_URL"
  echo "🔎 gost 版本：$($INSTALL_DIR/gost -V)"

  CONFIG_FILE="$INSTALL_DIR/config.json"
  cat > "$CONFIG_FILE" <<EOF
{
  "addr": "$SERVER_ADDR",
  "secret": "$SECRET"
}
EOF

  GOST_CONFIG="$INSTALL_DIR/gost.json"
  if [[ ! -f "$GOST_CONFIG" ]]; then
    cat > "$GOST_CONFIG" <<EOF
{}
EOF
  fi
  chmod 600 "$INSTALL_DIR"/*.json

  SERVICE_FILE="/etc/systemd/system/gost.service"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gost Proxy Service
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/gost -C /etc/gost/gost.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable gost
  systemctl start gost

  echo "🔄 检查服务状态..."
  if systemctl is-active --quiet gost; then
    echo "✅ 安装完成，gost服务已启动并设置为开机启动。"
    echo "📁 配置目录: $INSTALL_DIR"
    echo "🔧 服务状态: $(systemctl is-active gost)"
  else
    echo "❌ gost服务启动失败，请执行以下命令查看日志："
    echo "journalctl -u gost -f"
  fi

  install_flux_agent
  systemctl daemon-reload
  systemctl restart flux-agent >/dev/null 2>&1 || systemctl start flux-agent >/dev/null 2>&1 || true
}

update_gost() {
  echo "🔄 开始更新 GOST..."
  [[ ! -d "$INSTALL_DIR" ]] && { echo "❌ GOST 未安装，请先选择安装。"; return 1; }
  systemctl stop gost || true
  echo "⬇️ 解析最新 GOST 下载地址..."
  local GOST_URL
  GOST_URL=$(resolve_latest_gost_url) || { echo "❌ 无法解析最新 GOST 下载地址"; return 1; }
  download_and_install_gost "$GOST_URL" || return 1
  echo "🔎 新版本：$($INSTALL_DIR/gost -V || true)"
  systemctl start gost || true
  systemctl daemon-reload
  systemctl restart flux-agent >/dev/null 2>&1 || systemctl start flux-agent >/dev/null 2>&1 || true
  echo "✅ 更新完成，gost 与 flux-agent 均已重新启动。"
  return 0
}

uninstall_gost() {
  echo "🗑️ 开始卸载 GOST..."
  read -p "确认卸载 GOST 吗？此操作将删除所有相关文件 (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "❌ 取消卸载"; return 0; fi
  systemctl stop gost 2>/dev/null
  systemctl disable gost 2>/dev/null
  rm -f "/etc/systemd/system/gost.service"
  systemctl stop flux-agent 2>/dev/null
  systemctl disable flux-agent 2>/dev/null
  rm -f "/etc/systemd/system/flux-agent.service"
  [[ -f "$INSTALL_DIR/flux-agent" ]] && rm -f "$INSTALL_DIR/flux-agent"
  [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
  systemctl daemon-reload
  echo "✅ 卸载完成"
}

show_menu() {
  echo "==============================================="
  echo "              GOST 管理脚本"
  echo "==============================================="
  echo "请选择操作："
  echo "1. 安装"
  echo "2. 更新"
  echo "3. 卸载"
  echo "4. 退出"
  echo "==============================================="
}

main() {
  while true; do
    show_menu
    read -p "请输入选项 (1-4): " choice
    case $choice in
      1) install_gost; exit 0 ;;
      2) update_gost; exit 0 ;;
      3) uninstall_gost; exit 0 ;;
      4) echo "👋 退出脚本"; exit 0 ;;
      *) echo "❌ 无效选项，请输入 1-4"; echo "" ;;
    esac
  done
}

# 命令行参数支持 SERVER_ADDR/SECRET
while getopts "a:s:" opt; do
  case $opt in
    a) SERVER_ADDR="$OPTARG" ;;
    s) SECRET="$OPTARG" ;;
    *) echo "❌ 无效参数"; exit 1 ;;
  esac
done

main
