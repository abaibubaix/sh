#!/bin/bash
INSTALL_DIR="/etc/gost"
AGENT_BIN="/usr/local/bin/flux-agent"
# Static mirror for all downloadable artifacts (scripts/binaries/configs)
STATIC_BASE="https://panel-static.199028.xyz/network-panel"
GITHUB_DL_BASE="https://github.com/NiuStar/network-panel/releases/latest/download"
# GOST 最新版本 API（已改为镜像加速）
BASE_GOST_REPO_API="https://gh-proxy.org/https://api.github.com/repos/go-gost/gost/releases/latest"
PROXY_PREFIX=""
# 下载源模式：global(默认) | cn | static | github | auto(等价于 global)
SOURCE_MODE="global"
SOURCE_DESC=""

init_source_mode() {
  local mode="$SOURCE_MODE"
  if [[ "$mode" == "auto" ]]; then mode="global"; fi
  case "$mode" in
    cn)
      [[ -z "$PROXY_PREFIX" ]] && PROXY_PREFIX="https://proxy.529851.xyz/"
      SOURCE_DESC="静态镜像 > GitHub(代理) > GitHub(直连) > 面板"
      ;;
    static)
      SOURCE_DESC="静态镜像 > GitHub(直/代理) > 面板"
      ;;
    github)
      SOURCE_DESC="GitHub > 静态镜像 > 面板"
      ;;
    global)
      SOURCE_DESC="GitHub > 静态镜像 > 面板"
      ;;
    *)
      mode="global"
      SOURCE_DESC="GitHub > 静态镜像 > 面板"
      ;;
  esac
  SOURCE_MODE="$mode"
  echo "📡 下载源模式: $SOURCE_MODE${SOURCE_DESC:+ ($SOURCE_DESC)}"
}

build_candidate_urls() {
  local kind="$1" file="$2"
  local urls=() static gh ghp panel
  case "$kind" in
    flux-agent)
      static="${STATIC_BASE}/flux-agent/${file}"
      gh="${GITHUB_DL_BASE}/${file}"
      [[ -n "$PROXY_PREFIX" ]] && ghp="${PROXY_PREFIX}${GITHUB_DL_BASE}/${file}"
      [[ -n "${SERVER_ADDR:-}" ]] && panel="http://${SERVER_ADDR}/flux-agent/${file}"
      ;;
    script)
      static="${STATIC_BASE}/${file}"
      gh="${GITHUB_DL_BASE}/${file}"
      [[ -n "$PROXY_PREFIX" ]] && ghp="${PROXY_PREFIX}${GITHUB_DL_BASE}/${file}"
      ;;
  esac
  case "$SOURCE_MODE" in
    cn) urls+=("$static" "$ghp" "$gh" "$panel") ;;
    static) urls+=("$static" "$gh" "$ghp" "$panel") ;;
    github) urls+=("$gh" "$ghp" "$static" "$panel") ;;
    global|*)
      urls+=("$gh")
      [[ -n "$ghp" ]] && urls+=("$ghp")
      urls+=("$static" "$panel")
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

setup_syslog_cleanup_cron() {
  local cron_file="/etc/cron.d/cleanup-syslog"
  local line="0 3 * * * root find /var/log -maxdepth 1 -type f -name 'syslog.*' -mmin +1440 -delete"
  if [[ -f "$cron_file" ]] && grep -Fq "$line" "$cron_file"; then
    return 0
  fi
  echo "🧹 配置 syslog 清理计划任务 (每日 03:00 清理 24h 前的 syslog.*)"
  if [[ $EUID -ne 0 ]]; then
    printf '%s\n' "$line" | sudo tee "$cron_file" >/dev/null
    sudo chmod 0644 "$cron_file" >/dev/null 2>&1 || true
  else
    printf '%s\n' "$line" > "$cron_file"
    chmod 0644 "$cron_file" >/dev/null 2>&1 || true
  fi
}

show_menu() {
  echo "==============================================="
  echo "              管理脚本"
  echo "==============================================="
  echo "请选择操作："
  echo "1. 安装"
  echo "2. 更新 (自动识别二进制/Docker)"
  echo "3. 卸载 (自动识别二进制/Docker)"
  echo "4. 退出"
  echo "==============================================="
}

delete_self() {
  echo ""
  echo "🗑️ 操作已完成，正在清理脚本文件..."
  SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  sleep 1
  rm -f "$SCRIPT_PATH" && echo "✅ 脚本文件已删除" || echo "❌ 删除脚本文件失败"
}

check_and_install_tcpkill() {
  if command -v tcpkill &> /dev/null; then
    return 0
  fi
  OS_TYPE=$(uname -s)
  if [[ $EUID -ne 0 ]]; then
    SUDO_CMD="sudo"
  else
    SUDO_CMD=""
  fi
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    if command -v brew &> /dev/null; then
      brew install dsniff &> /dev/null
    fi
    return 0
  fi
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
  elif [ -f /etc/redhat-release ]; then
    DISTRO="rhel"
  elif [ -f /etc/debian_version ]; then
    DISTRO="debian"
  else
    return 0
  fi
  case $DISTRO in
    ubuntu|debian)
      $SUDO_CMD apt update &> /dev/null
      $SUDO_CMD apt install -y dsniff &> /dev/null
      ;;
    centos|rhel|fedora)
      if command -v dnf &> /dev/null; then
        $SUDO_CMD dnf install -y dsniff &> /dev/null
      elif command -v yum &> /dev/null; then
        $SUDO_CMD yum install -y dsniff &> /dev/null
      fi
      ;;
    alpine)
      $SUDO_CMD apk add --no-cache dsniff &> /dev/null
      ;;
    arch|manjaro)
      $SUDO_CMD pacman -S --noconfirm dsniff &> /dev/null
      ;;
    opensuse*|sles)
      $SUDO_CMD zypper install -y dsniff &> /dev/null
      ;;
    gentoo)
      $SUDO_CMD emerge --ask=n net-analyzer/dsniff &> /dev/null
      ;;
    void)
      $SUDO_CMD xbps-install -Sy dsniff &> /dev/null
      ;;
  esac
  return 0
}

check_and_install_diag_tools() {
  if [[ $EUID -ne 0 ]]; then SUDO_CMD="sudo"; else SUDO_CMD=""; fi
  if [ -f /etc/os-release ]; then . /etc/os-release; DISTRO=$ID; else DISTRO=""; fi
  case $DISTRO in
    ubuntu|debian)
      $SUDO_CMD apt update -y >/dev/null 2>&1 || true
      $SUDO_CMD apt install -y netcat-openbsd iperf3 jq >/dev/null 2>&1 || true
      ;;
    centos|rhel|fedora)
      if command -v dnf >/dev/null 2>&1; then
        $SUDO_CMD dnf install -y nmap-ncat iperf3 jq >/dev/null 2>&1 || true
      else
        $SUDO_CMD yum install -y nmap-ncat iperf3 jq >/dev/null 2>&1 || true
      fi
      ;;
    alpine)
      $SUDO_CMD apk add --no-cache netcat-openbsd iperf3 jq >/dev/null 2>&1 || true
      ;;
    arch|manjaro)
      $SUDO_CMD pacman -S --noconfirm gnu-netcat iperf3 jq >/dev/null 2>&1 || true
      ;;
    *)
      command -v nc >/dev/null 2>&1 || echo "⚠️ 请手动安装 netcat/iperf3/jq 以支持诊断"
      ;;
  esac
  if systemctl list-unit-files | grep -q '^iperf3\.service'; then
    $SUDO_CMD systemctl disable iperf3 >/dev/null 2>&1 || true
    $SUDO_CMD systemctl stop iperf3 >/dev/null 2>&1 || true
  fi
}

detect_install_mode() {
  if systemctl list-units --full -all 2>/dev/null | grep -Fq "gost.service" || [ -x "$INSTALL_DIR/gost" ]; then
    echo "binary"; return
  fi
  if command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null | grep -Ei '\bgost\b|go-gost' >/dev/null 2>&1; then
      echo "docker"; return
    fi
  fi
  echo "none"
}

pick_gost_container() {
  docker ps -a --format '{{.ID}} {{.Image}} {{.Names}}' | grep -Ei '\bgost\b|go-gost' | head -n1 | awk '{print $3}'
}

docker_compose_update() {
  local cn="$1"
  local proj dir files svc
  proj=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project"}}' "$cn" 2>/dev/null)
  dir=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cn" 2>/dev/null)
  files=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files"}}' "$cn" 2>/dev/null)
  svc=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service"}}' "$cn" 2>/dev/null)
  if [[ -n "$proj" && -n "$dir" && -n "$files" && -n "$svc" ]]; then
    ( cd "$dir" 2>/dev/null && \
      docker compose -p "$proj" -f "$files" pull "$svc" && \
      docker compose -p "$proj" -f "$files" up -d "$svc" )
    return $?
  fi
  return 2
}

docker_update_recreate() {
  local cn="$1"
  local img opts="" envs ports binds net rp priv cmd ep
  img=$(docker inspect -f '{{ .Config.Image }}' "$cn") || return 1
  docker pull "$img" || true
  envs=$(docker inspect "$cn" | jq -r '.[0].Config.Env[]? | "-e \(. )"')
  ports=$(docker inspect "$cn" | jq -r '
    .[0].HostConfig.PortBindings // {} | to_entries[]? as $e |
    ($e.key | split("/") | .[0]) as $cport |
    $e.value[]? | "-p \((.HostIp // "") as $ip | if $ip != "" then "\($ip):" else "" end)\(.HostPort):\($cport)"')
  if [[ -z "$ports" ]]; then
    ports=$(docker inspect "$cn" | jq -r '.[0].NetworkSettings.Ports // {} | to_entries[]? | select(.value!=null) | .value[]? | select(.HostPort) | "-p \(.HostPort):\(.key | split("/")[0])"')
  fi
  binds=$(docker inspect "$cn" | jq -r '.[0].HostConfig.Binds[]? | "-v \(.)"')
  net=$(docker inspect -f '{{ .HostConfig.NetworkMode }}' "$cn" 2>/dev/null)
  [[ -n "$net" && "$net" != "default" ]] && opts+=" --network $net"
  rp=$(docker inspect -f '{{ .HostConfig.RestartPolicy.Name }}' "$cn" 2>/dev/null)
  [[ -n "$rp" && "$rp" != "no" ]] && opts+=" --restart $rp"
  priv=$(docker inspect -f '{{ .HostConfig.Privileged }}' "$cn" 2>/dev/null)
  [[ "$priv" == "true" ]] && opts+=" --privileged"
  ep=$(docker inspect "$cn" | jq -r '.[0].Config.Entrypoint? | if type=="array" then ("--entrypoint \(.[0])") elif type=="string" then ("--entrypoint \(.)") else empty end')
  cmd=$(docker inspect "$cn" | jq -r '.[0].Config.Cmd? | @sh' | sed "s/^'//;s/'$//")
  docker stop "$cn" >/dev/null 2>&1 || true
  docker rm "$cn" >/dev/null 2>&1 || true
  docker run -d --name "$cn" $opts $envs $binds $ports ${ep:-} "$img" ${cmd:-} || return 1
  return 0
}

get_config_params() {
  if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
    echo "请输入配置参数："
    if [[ -z "$SERVER_ADDR" ]]; then
      read -p "服务器地址: " SERVER_ADDR
    fi
    if [[ -z "$SECRET" ]]; then
      read -p "密钥: " SECRET
    fi
    if [[ -z "$SERVER_ADDR" || -z "$SECRET" ]]; then
      echo "❌ 参数不完整，操作取消。"
      exit 1
    fi
  fi
}

install_flux_agent_go_bin() {
  local arch="$(uname -m)" os="linux"
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    FreeBSD) os="freebsd" ;;
  esac
  local file=""
  case "$arch" in
    x86_64|amd64) file="flux-agent-${os}-amd64" ;;
    aarch64|arm64) file="flux-agent-${os}-arm64" ;;
    armv7l|armv7|armhf) file="flux-agent-${os}-armv7" ;;
    *) file="flux-agent-${os}-amd64" ;;
  esac
  local target="$INSTALL_DIR/flux-agent"
  local urls=()
  while read -r u; do urls+=("$u"); done < <(build_candidate_urls "flux-agent" "$file")
  if download_from_urls "$target" "${urls[@]}"; then
    chmod +x "$target"; return 0
  fi
  echo "❌ 无法下载 flux-agent 二进制"
  return 1
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
  local tmpfile
  local AGENT_FILE="$INSTALL_DIR/flux-agent"
  tmpfile=$(mktemp -p /tmp flux-agent.XXXX || echo "/tmp/flux-agent.tmp")
  local urls=()
  while read -r u; do urls+=("$u"); done < <(build_candidate_urls "flux-agent" "$file")
  if download_from_urls "$tmpfile" "${urls[@]}"; then
    install -m 0755 "$tmpfile" "$AGENT_FILE" && rm -f "$tmpfile"
  else
    echo "❌ 无法下载 flux-agent 二进制"
    return 1
  fi
  local AGENT_ENV="/etc/default/flux-agent"
  if [[ ! -f "$AGENT_ENV" ]]; then
    cat > "$AGENT_ENV" <<EOF
# Flux Agent 环境配置
ADDR=
SECRET=
SCHEME=ws
EOF
  fi
  local AGENT_SERVICE="/etc/systemd/system/flux-agent.service"
  cat > "$AGENT_SERVICE" <<EOF
[Unit]
Description=Flux Diagnose Go Agent
After=network-online.target gost.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/flux-agent
ExecStart=$AGENT_FILE
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=2
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable flux-agent >/dev/null 2>&1 || true
  systemctl start flux-agent >/dev/null 2>&1 || true
  echo "✅ Go Agent 已安装并启用 (flux-agent.service)"
}

PROXY_MODE=""
while getopts "a:s:p:m:" opt; do
  case $opt in
    a) SERVER_ADDR="$OPTARG" ;;
    s) SECRET="$OPTARG" ;;
    p) PROXY_MODE="$OPTARG" ;;
    m) SOURCE_MODE="$OPTARG" ;;
    *) echo "❌ 无效参数"; exit 1 ;;
  esac
done

if [[ "$PROXY_MODE" == "4" ]]; then
  PROXY_PREFIX="https://proxy.529851.xyz/"
elif [[ "$PROXY_MODE" == "6" ]]; then
  PROXY_PREFIX="http://[240b:4000:93:de01:ffff:c725:3c65:47ff]:5000/"
fi
init_source_mode

resolve_latest_gost_url() {
  local arch="$(uname -m)" token=""
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
  local prefer_static=1
  if [[ "$SOURCE_MODE" == "github" || "$SOURCE_MODE" == "global" ]]; then
    prefer_static=0
  fi
  local static_base="${STATIC_BASE}/gost"
  local name url
  if (( prefer_static )); then
    for name in \
      "gost-linux-${token}.tar.gz" \
      "gost-linux-${token}.tgz" \
      "gost-linux-${token}.gz" \
      "gost-linux-${token}.zip"
    do
      url="${static_base}/${name}"
      if curl -fsI "$url" >/dev/null 2>&1; then
        echo "$url"; return 0
      fi
    done
  fi
  local api_list=()
  if [[ "$SOURCE_MODE" == "cn" || "$SOURCE_MODE" == "static" ]]; then
    [[ -n "$PROXY_PREFIX" ]] && api_list+=("${PROXY_PREFIX}${BASE_GOST_REPO_API}")
    api_list+=("$BASE_GOST_REPO_API")
  else
    api_list+=("$BASE_GOST_REPO_API")
    [[ -n "$PROXY_PREFIX" ]] && api_list+=("${PROXY_PREFIX}${BASE_GOST_REPO_API}")
  fi
  local prefer_proxy_dl=0
  if [[ "$SOURCE_MODE" == "cn" || "$SOURCE_MODE" == "static" ]]; then prefer_proxy_dl=1; fi

  local api urls cand
  for api in "${api_list[@]}"; do
    urls=$(curl -fsSL "$api" | jq -r '.assets[].browser_download_url' 2>/dev/null || true)
    if [[ -z "$urls" ]]; then continue; fi
    for cand in $urls; do
      if [[ "$cand" == *linux* && "$cand" == *$token* && ( "$cand" == *.tar.gz || "$cand" == *.tgz || "$cand" == *.gz || "$cand" == *.zip ) ]]; then
        if (( prefer_proxy_dl )) && [[ -n "$PROXY_PREFIX" ]] && [[ "$cand" == https://github.com/* ]]; then
          echo "${PROXY_PREFIX}${cand}"
        else
          echo "$cand"
        fi
        return 0
      fi
    done
  done
  if (( ! prefer_static )); then
    for name in \
      "gost-linux-${token}.tar.gz" \
      "gost-linux-${token}.tgz" \
      "gost-linux-${token}.gz" \
      "gost-linux-${token}.zip"
    do
      url="${static_base}/${name}"
      if curl -fsI "$url" >/dev/null 2>&1; then
        echo "$url"; return 0
      fi
    done
  fi
  return 1
}

download_and_install_gost() {
  local url="$1"
  local tmpdir; tmpdir=$(mktemp -d)
  echo "⬇️ 下载: $url"
  if ! curl -fSL --retry 3 --retry-delay 1 "$url" -o "$tmpdir/pkg"; then
    echo "❌ 下载失败: $url"; rm -rf "$tmpdir"; return 1
  fi
  mkdir -p "$INSTALL_DIR"
  if [[ "$url" =~ \.tar\.gz$|\.tgz$ ]]; then
    tar -xzf "$tmpdir/pkg" -C "$tmpdir"
    local bin
    bin=$(find "$tmpdir" -type f -name gost -perm -111 | head -n1 || true)
    if [[ -z "$bin" ]]; then bin=$(find "$tmpdir" -type f -name gost | head -n1 || true); fi
    if [[ -z "$bin" ]]; then echo "❌ 未在压缩包内找到 gost"; rm -rf "$tmpdir"; return 1; fi
    install -m 0755 "$bin" "$INSTALL_DIR/gost"
  elif [[ "$url" =~ \.zip$ ]]; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -o "$tmpdir/pkg" -d "$tmpdir" >/dev/null
      local bin
      bin=$(find "$tmpdir" -type f -name gost -perm -111 | head -n1 || true)
      if [[ -z "$bin" ]]; then bin=$(find "$tmpdir" -type f -name gost | head -n1 || true); fi
      if [[ -z "$bin" ]]; then echo "❌ 未在压缩包内找到 gost"; rm -rf "$tmpdir"; return 1; fi
      install -m 0755 "$bin" "$INSTALL_DIR/gost"
    else
      echo "⚠️ 未安装 unzip，无法解压 .zip 包"; rm -rf "$tmpdir"; return 1
    fi
  elif [[ "$url" =~ \.gz$ ]]; then
    gunzip -c "$tmpdir/pkg" > "$INSTALL_DIR/gost"
    chmod +x "$INSTALL_DIR/gost"
  else
    install -m 0755 "$tmpdir/pkg" "$INSTALL_DIR/gost"
  fi
  rm -rf "$tmpdir"
  echo "🔎 版本：$($INSTALL_DIR/gost -V || true)"
}

install_gost() {
  echo "🚀 开始安装 GOST..."
  get_config_params
  check_and_install_tcpkill
  check_and_install_diag_tools
  mkdir -p "$INSTALL_DIR"
  if systemctl list-units --full -all | grep -Fq "gost.service"; then
    echo "🔍 检测到已存在的gost服务"
    systemctl stop gost 2>/dev/null && echo "🛑 停止服务"
    systemctl disable gost 2>/dev/null && echo "🚫 禁用自启"
  fi
  [[ -f "$INSTALL_DIR/gost" ]] && echo "🧹 删除旧文件 gost" && rm -f "$INSTALL_DIR/gost"
  echo "⬇️ 解析最新 GOST 下载地址..."
  local GOST_URL
  if ! GOST_URL=$(resolve_latest_gost_url); then
    echo "❌ 无法解析最新 GOST 下载地址"; exit 1
  fi
  download_and_install_gost "$GOST_URL"
  echo "🔎 gost 版本：$($INSTALL_DIR/gost -V)"
  CONFIG_FILE="$INSTALL_DIR/config.json"
  echo "📄 创建新配置: config.json"
  cat > "$CONFIG_FILE" <<EOF
{
  "addr": "$SERVER_ADDR",
  "secret": "$SECRET"
}
EOF

  GOST_CONFIG="$INSTALL_DIR/gost.json"
  if [[ -f "$GOST_CONFIG" ]]; then
    echo "⏭️ 跳过配置文件: gost.json (已存在)"
  else
    echo "📄 创建新配置: gost.json"
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
  setup_syslog_cleanup_cron
}

update_gost() {
  echo "🔄 开始更新 GOST..."
  local mode
  mode=$(detect_install_mode)
  if [[ "$mode" == "docker" ]]; then
    if ! command -v docker >/dev/null 2>&1; then echo "❌ 未检测到 docker"; return 1; fi
    check_and_install_diag_tools
    local cn
    cn=$(pick_gost_container)
    if [[ -z "$cn" ]]; then echo "❌ 未找到 gost 容器"; return 1; fi
    echo "🐳 检测到 Docker 安装，容器: $cn"
    if docker_compose_update "$cn"; then
      echo "✅ Docker Compose 更新完成"
      return 0
    fi
    if docker_update_recreate "$cn"; then
      echo "✅ Docker 容器已使用最新镜像重建并启动"
      return 0
    else
      echo "❌ Docker 容器更新失败"
      return 1
    fi
  elif [[ "$mode" == "binary" ]]; then
    if [[ ! -d "$INSTALL_DIR" ]]; then
      echo "❌ GOST 未安装，请先选择安装。"; return 1
    fi
    check_and_install_tcpkill
    check_and_install_diag_tools
    if systemctl list-units --full -all | grep -Fq "gost.service"; then
      echo "🛑 停止 gost 服务..."; systemctl stop gost || true
    fi
    echo "⬇️ 解析最新 GOST 下载地址..."
    local GOST_URL
    if ! GOST_URL=$(resolve_latest_gost_url); then echo "❌ 无法解析最新 GOST 下载地址"; return 1; fi
    download_and_install_gost "$GOST_URL" || return 1
    echo "🔎 新版本：$($INSTALL_DIR/gost -V || true)"
    echo "🔄 重启服务..."; systemctl start gost || true
    systemctl daemon-reload
    systemctl restart flux-agent >/dev/null 2>&1 || systemctl start flux-agent >/dev/null 2>&1 || true
    echo "✅ 更新完成，gost 与 flux-agent 均已重新启动。"
    return 0
  else
    echo "ℹ️ 未检测到已安装的 GOST。"
    return 1
  fi
}

uninstall_gost() {
  echo "🗑️ 开始卸载 GOST..."
  read -p "确认卸载 GOST 吗？此操作将删除所有相关文件 (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "❌ 取消卸载"; return 0; fi
  local mode; mode=$(detect_install_mode)
  if [[ "$mode" == "docker" ]]; then
    if ! command -v docker >/dev/null 2>&1; then echo "❌ 未检测到 docker"; return 1; fi
    local lines; lines=$(docker ps -a --format '{{.Names}}' | grep -Ei '\bgost\b|go-gost' || true)
    if [[ -z "$lines" ]]; then echo "ℹ️ 未找到 gost 容器"; else
      echo "$lines" | while read -r cn; do
        echo "🛑 停止容器: $cn"; docker stop "$cn" >/dev/null 2>&1 || true
        echo "🧹 删除容器: $cn"; docker rm "$cn" >/dev/null 2>&1 || true
      done
    fi
    echo "✅ Docker 卸载完成"
    return 0
  fi
  if systemctl list-units --full -all | grep -Fq "gost.service"; then
    echo "🛑 停止并禁用服务..."; systemctl stop gost 2>/dev/null; systemctl disable gost 2>/dev/null
  fi
  if [[ -f "/etc/systemd/system/gost.service" ]]; then rm -f "/etc/systemd/system/gost.service"; echo "🧹 删除服务文件"; fi
  if systemctl list-units --full -all | grep -Fq "flux-agent.service"; then
    echo "🛑 停止并禁用 flux-agent 服务..."; systemctl stop flux-agent 2>/dev/null; systemctl disable flux-agent 2>/dev/null; rm -f "/etc/systemd/system/flux-agent.service"
  fi
  if [[ -f "$INSTALL_DIR/flux-agent" ]]; then rm -f "$INSTALL_DIR/flux-agent"; echo "🧹 删除 flux-agent 二进制"; fi
  if [[ -d "$INSTALL_DIR" ]]; then rm -rf "$INSTALL_DIR"; echo "🧹 删除安装目录: $INSTALL_DIR"; fi
  systemctl daemon-reload
  echo "✅ 卸载完成"
}

main() {
  if [[ -n "$SERVER_ADDR" && -n "$SECRET" ]]; then
    install_gost
    delete_self
    exit 0
  fi
  while true; do
    show_menu
    read -p "请输入选项 (1-4): " choice
    case $choice in
      1) install_gost; delete_self; exit 0 ;;
      2) update_gost; delete_self; exit 0 ;;
      3) uninstall_gost; delete_self; exit 0 ;;
      4) echo "👋 退出脚本"; delete_self; exit 0 ;;
      *) echo "❌ 无效选项，请输入 1-5"; echo "" ;;
    esac
  done
}

main
