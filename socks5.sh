#!/bin/bash

# ================= 默认参数 =================
DEFAULT_START_PORT=51665
DEFAULT_SOCKS_USERNAME="abai"
DEFAULT_SOCKS_PASSWORD="abai569"

# ================= 卸载函数 =================
uninstall_xray() {
	echo "开始卸载 Xray..."

	systemctl stop xrayL.service 2>/dev/null
	systemctl disable xrayL.service 2>/dev/null

	rm -f /etc/systemd/system/xrayL.service
	rm -f /etc/systemd/system/multi-user.target.wants/xrayL.service
	systemctl daemon-reload

	rm -f /usr/local/bin/xrayL
	rm -rf /etc/xrayL
	rm -f Xray-linux-64.zip

	echo "Xray 已卸载完成"
	exit 0
}

# ================= 主入口（先判断卸载） =================
main() {
	if [ "$1" == "--uninstall" ]; then
		uninstall_xray
	fi

	# ================= IP 列表 =================
	IPV4_LIST=()
	IPV6_LIST=()

	echo "开始检测公网 IP..."

	# -------- IPv4（接口级，站群） --------
	while read ip; do
	  [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168|127\.) ]] && continue
	  if curl --interface "$ip" -s4 --max-time 4 ip.sb | grep -q "$ip"; then
	    IPV4_LIST+=("$ip")
	  fi
	done < <(ip -4 addr show scope global | awk '{print $2}' | cut -d/ -f1)

	# -------- IPv4（NAT 出口，云） --------
	PUB_IPV4=$(curl -s4 --max-time 4 ip.sb | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
	[ -n "$PUB_IPV4" ] && IPV4_LIST+=("$PUB_IPV4")

	# -------- IPv6 --------
	while read ip; do
	  [[ "$ip" =~ ^(fd|fe80) ]] && continue
	  if curl --interface "$ip" -s6 --max-time 4 ip.sb | grep -q ':'; then
	    IPV6_LIST+=("$ip")
	  fi
	done < <(ip -6 addr show scope global | awk '{print $2}' | cut -d/ -f1)

	# 去重
	IPV4_LIST=($(printf "%s\n" "${IPV4_LIST[@]}" | sort -u))
	IPV6_LIST=($(printf "%s\n" "${IPV6_LIST[@]}" | sort -u))

	# ================= 安装 Xray =================
	[ -x "$(command -v xrayL)" ] || install_xray
	config_xray
}

# ================= 安装 Xray =================
install_xray() {
	echo "安装 Xray..."
	apt-get install -y unzip curl || yum install -y unzip curl
	wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
	unzip -o Xray-linux-64.zip
	mv xray /usr/local/bin/xrayL
	chmod +x /usr/local/bin/xrayL

	cat <<EOF >/etc/systemd/system/xrayL.service
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.toml
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
	echo "Xray 安装完成."
}

# ================= 配置 SOCKS =================
config_xray() {
	mkdir -p /etc/xrayL

	START_PORT=$DEFAULT_START_PORT
	USER=$DEFAULT_SOCKS_USERNAME
	PASS=$DEFAULT_SOCKS_PASSWORD

	config_content=""
	index=0

	for ip in "${IPV4_LIST[@]}" "${IPV6_LIST[@]}"; do
		PORT=$((START_PORT + index))

		config_content+="[[inbounds]]\n"
		config_content+="port = $PORT\n"
		config_content+="protocol = \"socks\"\n"
		config_content+="tag = \"tag_$index\"\n"
		config_content+="[inbounds.settings]\n"
		config_content+="auth = \"password\"\n"
		config_content+="udp = true\n"
		config_content+="[[inbounds.settings.accounts]]\n"
		config_content+="user = \"$USER\"\n"
		config_content+="pass = \"$PASS\"\n"

		config_content+="[[outbounds]]\n"
		config_content+="protocol = \"freedom\"\n"
		config_content+="tag = \"tag_$index\"\n\n"

		config_content+="[[routing.rules]]\n"
		config_content+="type = \"field\"\n"
		config_content+="inboundTag = \"tag_$index\"\n"
		config_content+="outboundTag = \"tag_$index\"\n\n"

		index=$((index + 1))
	done

	echo -e "$config_content" >/etc/xrayL/config.toml
	systemctl restart xrayL.service

	echo "SOCKS5 代理生成结果："

	index=0
	for ip in "${IPV4_LIST[@]}" "${IPV6_LIST[@]}"; do
		PORT=$((START_PORT + index))
		index=$((index + 1))

		if [[ "$ip" =~ ":" ]]; then
			printf "socks5://%s:%s@[%s]:%s\n" "$USER" "$PASS" "$ip" "$PORT"
		else
			printf "socks5://%s:%s@%s:%s\n" "$USER" "$PASS" "$ip" "$PORT"
		fi
	done
}

main "$@"
