#!/bin/sh
set -e

#################################
# 基础路径
#################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASE_DIR/x_cf"

### ====== 基础变量 ======
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
XRAY_PORT=${XRAY_PORT:-8001}  # 本地 Xray 监听端口
CFIP=${CFIP:-"www.visa.cn"}  # CDN 域名
CFPORT=${CFPORT:-443}         # CDN 端口

XHTTP_PATH_LEN=${XHTTP_PATH_LEN:-8} # 随机路径长度
XHTTP_PATH_BASE=${XHTTP_PATH_BASE:-"/api/v1"} # 固定路径

if [ "$XHTTP_PATH_LEN" -gt 0 ]; then
  RAND=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$XHTTP_PATH_LEN")
  XHTTP_PATH="${XHTTP_PATH_BASE}/${RAND}"
else
  XHTTP_PATH="${XHTTP_PATH_BASE}"
fi

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
    ;;
  aarch64|arm64)
    XRAY_ARCH="arm64-v8a"
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
  curl -L -o xray.zip "https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
  unzip -q xray.zip xray
  chmod +x xray
  rm -f xray.zip
fi

#################################
# 生成 Xray 配置
#################################
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${CFIP}",
          "allowInsecure": false,
          "certificates": [
            {
              "certificateFile": "/app/x_cf/cert.pem",
              "keyFile": "/app/x_cf/key.pem"
            }
          ]
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

#################################
# 启动 Xray
#################################
echo "[+] 启动 Xray"
pkill -f "$WORKDIR/xray run" || true
nohup ./xray run -c config.json > run.log 2>&1 &
sleep 1
if ! pgrep xray >/dev/null; then
  echo "[!] Xray 启动失败"
  echo "====== 错误日志 ======"
  cat run.log
  exit 1
fi

#################################
# 输出节点信息
#################################
ENCODED_PATH=$(printf '%s' "$XHTTP_PATH" | sed 's/\//%2F/g')

VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&type=xhttp&path=${ENCODED_PATH}&host=${CFIP}&sni=${CFIP}#VLESS-XHTTP-CDN"

echo
echo "========= 节点信息 ========="
echo "UUID: $UUID"
echo "CDN 域名: $CFIP"
echo "SNI: $CFIP"
echo "XHTTP_PATH: ${ENCODED_PATH}"
echo "$VLESS_LINK"
echo "============================"
