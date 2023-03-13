checkOS() {
    if [ "$(which apt 2>/dev/null)" ]; then
        InstallMethod="apt"
        is_debian=1
    elif [ "$(which dnf 2>/dev/null)" ] || [ "$(which yum 2>/dev/null)" ]; then
        InstallMethod="yum"
        is_redhat=1
    fi
}
checkOS

if [ ! "$(command -v jq)" ]; then
  if [ "$InstallMethod"=="yum" ]; then
    $InstallMethod install epel-release -y
  fi
   $InstallMethod install jq -y
fi
if [ ! "$(command -v curl)" ]; then
  $InstallMethod install curl -y
fi
clear
region=$(curl -s https://www.tiktok.com/node/common/web-privacy-config?locale=zh-Hant-TW | jq '.body.appProps.region')
echo "TikTok解锁地区："$region