#!/bin/sh
set -e

#################################
# 基础变量
#################################

# WARP_MODE:
#   all  - IPv4 + IPv6 全走 WARP
#   v4   - 仅 IPv4 走 WARP（推荐）
#   v6   - 仅 IPv6 走 WARP
#   off  - 关闭 WARP
WARP_MODE=${WARP_MODE:-v4}

XRAY_PORT=${ARGO_PORT:-5216}
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

ARGO_AUTH=${ARGO_AUTH:-}
ARGO_DOMAIN=${ARGO_DOMAIN:-}

CFIP_v4=${CFIP_v4:-cf.ljy.abrdns.com}
CFIP_v6=${CFIP_v6:-ip.sb}
CFPORT=${CFPORT:-443}

WARP_API="https://ygkkk-warp.renky.eu.org"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASE_DIR/x_cf"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

#################################
# 架构判断
#################################
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    XRAY_ARCH="64"
    CF_ARCH="amd64"
    ;;
  aarch64|arm64)
    XRAY_ARCH="arm64-v8a"
    CF_ARCH="arm64"
    ;;
  *)
    echo "不支持架构: $ARCH"
    exit 1
    ;;
esac

#################################
# IPv4 / IPv6 探测
#################################
HAS_IPV4=0
HAS_IPV6=0

ip -4 route get 8.8.8.8 >/dev/null 2>&1 && HAS_IPV4=1
ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1 && HAS_IPV6=1

#################################
# 下载工具函数
#################################
download() {
  url="$1"
  out="$2"

  if command -v curl >/dev/null 2>&1; then
    if [ "$HAS_IPV4" -eq 0 ] && [ "$HAS_IPV6" -eq 1 ]; then
      curl -6 -L -o "$out" "$url"
    else
      curl -L -o "$out" "$url"
    fi
  else
    wget -O "$out" "$url"
  fi
}

#################################
# 下载 Xray
#################################
if [ ! -f xray ]; then
  echo "[+] 下载 Xray"
  download "https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}" xray.zip
  unzip -q xray.zip xray geoip.dat geosite.dat
  chmod +x xray
  rm -f xray.zip
fi

#################################
# 获取 WARP 账号（仅在开启时）
#################################
if [ "$WARP_MODE" != "off" ]; then
  echo "[+] 获取 WARP 账号"

  WARP_RAW="$(curl -s --max-time 8 "$WARP_API" || true)"

  WARP_PVK="$(echo "$WARP_RAW" | grep 'Private_key' | sed 's/.*[:：] *//')"
  WARP_IPV6="$(echo "$WARP_RAW" | grep 'IPV6' | sed 's/.*[:：] *//')"
  WARP_RES="$(echo "$WARP_RAW" | grep 'reserved' | sed 's/.*[:：] *//')"

  [ -z "$WARP_PVK" ] && WARP_PVK="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
  [ -z "$WARP_IPV6" ] && WARP_IPV6="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
  [ -z "$WARP_RES" ] && WARP_RES="[215, 69, 233]"

  if [ "$HAS_IPV4" -eq 0 ] && [ "$HAS_IPV6" -eq 1 ]; then
    WARP_ENDPOINT="[2606:4700:d0::a29f:c001]:2408"
  else
    WARP_ENDPOINT="162.159.192.1:2408"
  fi
fi

#################################
# 生成 Xray 配置
#################################
LISTEN_ADDR="0.0.0.0"
[ "$HAS_IPV6" -eq 1 ] && LISTEN_ADDR="::"

OUT_WARP=""
RULE_V4="direct"
RULE_V6="direct"

if [ "$WARP_MODE" != "off" ]; then
  OUT_WARP='{
    "tag": "warp-out",
    "protocol": "wireguard",
    "settings": {
      "secretKey": "'"$WARP_PVK"'",
      "address": ["172.16.0.2/32", "'"$WARP_IPV6"'/128"],
      "peers": [{
        "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "allowedIPs": ["0.0.0.0/0", "::/0"],
        "endpoint": "'"$WARP_ENDPOINT"'"
      }],
      "reserved": '"$WARP_RES"'
    }
  },'
fi

case "$WARP_MODE" in
  all) RULE_V4="warp-out"; RULE_V6="warp-out" ;;
  v4)  RULE_V4="warp-out" ;;
  v6)  RULE_V6="warp-out" ;;
esac

cat > config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "listen": "$LISTEN_ADDR",
    "port": $XRAY_PORT,
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "$UUID", "alterId": 0 }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "/vmess-argo" }
    }
  }],
  "outbounds": [
    $OUT_WARP
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": ["youtube.com", "*.youtube.com", "cloudflare.com", "*.cloudflare.com"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["0.0.0.0/0"],
        "outboundTag": "$RULE_V4"
      },
      {
        "type": "field",
        "ip": ["::/0"],
        "outboundTag": "$RULE_V6"
      }
    ]
  }
}
EOF

#################################
# 启动 Xray
#################################
pkill -9 xray || true
nohup ./xray run -c config.json > run.log 2>&1 &
sleep 1

#################################
# 下载 cloudflared
#################################
if [ ! -f cloudflared ]; then
  echo "[+] 下载 cloudflared"
  download "https://download.lycn.qzz.io/cloudflared-linux-${CF_ARCH}" cloudflared
  chmod +x cloudflared
fi

#################################
# 启动 Cloudflare Tunnel（不走 WARP）
#################################
pkill -9 cloudflared || true

LOCAL_ADDR="localhost"
[ "$HAS_IPV6" -eq 1 ] && LOCAL_ADDR="[::1]"

CF_V6_FLAG=""
[ "$HAS_IPV4" -eq 0 ] && [ "$HAS_IPV6" -eq 1 ] && CF_V6_FLAG="--edge-ip-version 6"

DOMAIN=""

if [ -n "$ARGO_AUTH" ]; then
  nohup ./cloudflared tunnel $CF_V6_FLAG \
    --protocol http2 \
    --no-autoupdate \
    run --token "$ARGO_AUTH"  \
    > run.log 2>&1 &
  DOMAIN="$ARGO_DOMAIN"
else
  nohup ./cloudflared tunnel $CF_V6_FLAG \
    --protocol http2 \
    --no-autoupdate \
    --url http://${LOCAL_ADDR}:${XRAY_PORT} \
    > cf.log 2>&1 &
  sleep 2
  DOMAIN="$(grep trycloudflare.com cf.log | head -n1 | sed 's#https://##')"
fi

#################################
# 输出节点
#################################
CFIP="$CFIP_v4"
[ "$HAS_IPV6" -eq 1 ] && CFIP="$CFIP_v6"

VMESS_JSON=$(cat <<EOF
{
  "v":"2",
  "ps":"ARGO-WARP[$WARP_MODE]",
  "add":"$CFIP",
  "port":"$CFPORT",
  "id":"$UUID",
  "aid":"0",
  "net":"ws",
  "type":"none",
  "host":"$DOMAIN",
  "path":"/vmess-argo",
  "tls":"tls",
  "sni":"$DOMAIN"
}
EOF
)

echo
echo "=============================="
echo "Argo 域名: $DOMAIN"
echo "WARP_MODE: $WARP_MODE"
echo "=============================="
echo "vmess://$(echo "$VMESS_JSON" | base64 | tr -d '\n')"
echo "=============================="
