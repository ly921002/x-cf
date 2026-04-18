#!/bin/sh
set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASE_DIR/x_cf"

### ===== 基础变量 =====
XRAY_PORT=${ARGO_PORT:-5216}
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

ARGO_AUTH=${ARGO_AUTH:-""}
ARGO_DOMAIN=${ARGO_DOMAIN:-""}

CFIP_v4=${CFIP_v4:-"ip.sb"}
CFPORT=${CFPORT:-443}

### ===== SOCKS5 出口 =====
SOCKS_IP=${SOCKS_IP:-"1.2.3.4"}
SOCKS_PORT=${SOCKS_PORT:-1080}
SOCKS_USER=${SOCKS_USER:-"user"}
SOCKS_PASS=${SOCKS_PASS:-"password"}

mkdir -p "$WORKDIR"
cd "$WORKDIR"

#################################
# 架构
#################################
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) XRAY_ARCH="64"; CF_ARCH="amd64";;
  aarch64|arm64) XRAY_ARCH="arm64-v8a"; CF_ARCH="arm64";;
  *) echo "不支持架构"; exit 1;;
esac

#################################
# 下载 Xray
#################################
if [ ! -f xray ]; then
  echo "[+] 下载 Xray"
  curl -L -o xray.zip \
    "https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
  unzip -q xray.zip xray
  chmod +x xray
  rm -f xray.zip
fi

#################################
# 写配置（核心：SOCKS 出口）
#################################
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },

  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${UUID}", "alterId": 0 }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess-argo" }
      }
    }
  ],

  "outbounds": [
    {
      "tag": "socks-out",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "${SOCKS_IP}",
            "port": ${SOCKS_PORT},
            "users": [
              {
                "user": "${SOCKS_USER}",
                "pass": "${SOCKS_PASS}"
              }
            ]
          }
        ]
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],

  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "socks-out",
        "network": "tcp"
      }
    ]
  }
}
EOF

#################################
# 启动 Xray
#################################
pkill -f "$WORKDIR/xray" || true
nohup ./xray run -c config.json > run.log 2>&1 &

sleep 2
pgrep xray >/dev/null || { echo "Xray 启动失败"; exit 1; }

#################################
# 下载 cloudflared
#################################
if [ ! -f cloudflared ]; then
  echo "[+] 下载 cloudflared"
  curl -L -o cloudflared \
    "https://download.lycn.qzz.io/cloudflared-linux-${CF_ARCH}"
  chmod +x cloudflared
fi

#################################
# 启动 Argo
#################################
pkill -f cloudflared || true

if [ -n "$ARGO_AUTH" ]; then
  echo "[+] 固定隧道"
  nohup ./cloudflared tunnel \
    --no-autoupdate \
    --url http://127.0.0.1:${XRAY_PORT} \
    run --token "$ARGO_AUTH" \
    > argo.log 2>&1 &
  DOMAIN="$ARGO_DOMAIN"
else
  echo "[+] 临时隧道"
  nohup ./cloudflared tunnel \
    --url http://127.0.0.1:${XRAY_PORT} \
    > argo.log 2>&1 &

  for i in $(seq 1 20); do
    DOMAIN=$(grep -o 'https://.*trycloudflare.com' argo.log \
      | head -n1 | sed 's#https://##')
    [ -n "$DOMAIN" ] && break
    sleep 1
  done
fi

#################################
# 输出 vmess
#################################
VMESS_JSON=$(cat <<EOF
{
  "v":"2",
  "ps":"ARGO-SOCKS",
  "add":"${CFIP_v4}",
  "port":"${CFPORT}",
  "id":"${UUID}",
  "aid":"0",
  "net":"ws",
  "type":"none",
  "host":"${DOMAIN}",
  "path":"/vmess-argo",
  "tls":"tls",
  "sni":"${DOMAIN}"
}
EOF
)

VMESS_LINK="vmess://$(echo "$VMESS_JSON" | base64 | tr -d '\n')"

echo
echo "========= 成功 ========="
echo "Argo域名: $DOMAIN"
echo
echo "$VMESS_LINK"
echo
echo "出口 SOCKS5:"
echo "${SOCKS_USER}:${SOCKS_PASS}@${SOCKS_IP}:${SOCKS_PORT}"
echo "======================="
