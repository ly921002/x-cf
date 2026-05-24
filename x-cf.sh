#!/bin/sh
set -e

#################################
# 基础路径
#################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASE_DIR/x_cf"

### ====== 基础变量 ======
XRAY_PORT=${ARGO_PORT:-5216}
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
ARGO_AUTH=${ARGO_AUTH:-""}
ARGO_DOMAIN=${ARGO_DOMAIN:-"domain"}
CFIP=${CFIP:-"ip.sb"}
CFPORT=${CFPORT:-443}
#################################
# 初始化目录
#################################
mkdir -p "$WORKDIR"
cd "$WORKDIR"

#################################
# 架构判断
#################################
ARCH=$(uname -m)
echo "识别架构: $ARCH"
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
# 下载 Xray
#################################

if [ ! -f xray ]; then
  echo "[+] 下载 Xray"
  echo "下载地址: https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
  curl -L -o xray.zip \
    "https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
  unzip -q xray.zip xray
  chmod +x xray
  rm -f xray.zip
fi

#################################
# 生成 Xray 配置
#################################

cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/live"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

#################################
# 启动 Xray
#################################
echo "[+] 启动 Xray"
# 杀死旧进程防止端口占用
pkill -f "$WORKDIR/xray run" || true

nohup ./xray run -c config.json > run.log 2>&1 &
sleep 1
if ! pgrep xray >/dev/null; then
  echo "[!] Xray 启动失败"
  echo "====== 错误日志 ======"
  cat run.log
  exit 1
fi
sleep 1

#################################
# 下载 cloudflared
#################################
if [ ! -f cloudflared ]; then
  echo "[+] 下载 cloudflared"
  echo "下载地址: https://download.lycn.qzz.io/cloudflared-linux-${CF_ARCH}"
  curl -4 -L -o cloudflared \
    "https://download.lycn.qzz.io/cloudflared-linux-${CF_ARCH}"
  chmod +x cloudflared
fi

#################################
# 启动 Cloudflare Tunnel
#################################
DOMAIN=""
pkill -f "$WORKDIR/cloudflared tunnel" || true
nohup ./cloudflared tunnel run --token "$ARGO_AUTH" \
  >> run.log 2>&1 &
DOMAIN="$ARGO_DOMAIN"

sleep 1
if ! pgrep cloudflared >/dev/null; then
  echo "[!] cloudflared 启动失败"
  echo "====== 错误日志 ======"
  cat run.log
  exit 1
fi

#################################
# 输出节点信息
#################################
VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=%2Fvless&sni=${DOMAIN}#ARGO-VLESS"

echo
echo "========= 节点信息 ========="
echo "Argo 域名: $DOMAIN"
echo "SNI: $DOMAIN"
echo
echo "$VLESS_LINK"
echo "============================"
