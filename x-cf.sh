#!/bin/sh
set -e

#################################
# 基础路径
#################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASE_DIR/xray"

#################################
# 基础变量
#################################

UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}

XRAY_PORT=${XRAY_PORT:-443}

PATH_LENGTH=${PATH_LENGTH:-8}
RAND=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$PATH_LENGTH")

BASE=${BASE:-"api/v1"}
XHTTP_PATH=${XHTTP_PATH:-"/${BASE}/${RAND}"}

#################################
# 初始化目录
#################################

mkdir -p "$WORKDIR"
cd "$WORKDIR"

#################################
# 架构识别
#################################

ARCH=$(uname -m)

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
# 下载Xray
#################################

if [ ! -f xray ]; then
    echo "[+] 下载Xray"

    curl -L -o xray.zip \
    #"https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
    "https://github.com/XTLS/Xray-core/releases/latest/download/xray-linux-${XRAY_ARCH}.zip"
    unzip -q xray.zip xray
    chmod +x xray

    rm -f xray.zip
fi

#################################
# 生成Reality密钥
#################################

echo "[+] 生成Reality密钥"

KEY_OUTPUT=$(./xray x25519)

PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $3}')

SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

#################################
# Reality伪装站
#################################

REALITY_SITES="
www.microsoft.com
www.apple.com
www.cloudflare.com
www.amazon.com
www.oracle.com
www.visa.com
www.nvidia.com
"

SERVER_NAME=$(echo "$REALITY_SITES" | sed '/^$/d' | shuf -n1)

DEST="${SERVER_NAME}:443"

#################################
# 获取公网IP
#################################

SERVER_IP=$(curl -s4 ip.sb)

#################################
# 生成配置
#################################

cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
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
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [
            "${SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        },
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

#################################
# 启动Xray
#################################

echo "[+] 启动Xray"

pkill -f "$WORKDIR/xray run" 2>/dev/null || true

nohup ./xray run -c config.json > run.log 2>&1 &

sleep 3

if ! pgrep -x xray >/dev/null; then
    echo "[!] Xray启动失败"
    echo
    cat run.log
    exit 1
fi

#################################
# 输出节点
#################################

ENCODED_PATH=$(printf '%s' "$XHTTP_PATH" | sed 's/\//%2F/g')

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${SERVER_NAME}&fp=chrome&type=xhttp&path=${ENCODED_PATH}#VLESS-XHTTP-REALITY"

echo
echo "===================================="
echo "          VLESS + XHTTP + REALITY"
echo "===================================="
echo
echo "IP        : $SERVER_IP"
echo "PORT      : $XRAY_PORT"
echo "UUID      : $UUID"
echo "SNI       : $SERVER_NAME"
echo "PublicKey : $PUBLIC_KEY"
echo "ShortID   : $SHORT_ID"
echo "Path      : $XHTTP_PATH"
echo
echo "$VLESS_LINK"
echo
echo "===================================="
