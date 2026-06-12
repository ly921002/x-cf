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

XRAY_PORT=${XRAY_PORT:-8443}

XHTTP_PATH_LEN=${XHTTP_PATH_LEN:-8} # 随机路径长度
XHTTP_PATH_BASE=${XHTTP_PATH_BASE:-"/api/v1"}     # 固定路径

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
echo "架构识别: $ARCH"

#################################
# 下载Xray
#################################

if [ ! -f xray ]; then
    echo "[+] 下载Xray"
    curl -L -o xray.zip \
    "https://github.com/XTLS/Xray-core/releases/latest/download/xray-linux-${XRAY_ARCH}.zip"
    unzip -q xray.zip xray
    chmod +x xray
    rm -f xray.zip
fi

#################################
# 生成Reality密钥
#################################

echo "[+] 生成Reality密钥"

KEY_OUTPUT=$(./xray x25519 2>/dev/null)

PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "PrivateKey" | head -n1 | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -i "Password" | head -n1 | awk '{print $3}')

# 兜底（防止解析失败）
if [ -z "$PRIVATE_KEY" ]; then
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/ {print $2}')
fi
if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/Password/ {print $2}')
fi

# 随机生成一个 16 字符的 ShortID
SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "[!] Reality密钥解析失败"
    exit 1
fi

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

SERVER_IP=$(curl -s4 ip.sb || echo "无法获取IP")

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
# 输出节点 (在启动前打印，防止被日志淹没或退出)
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

#################################
# 启动Xray (前台运行，接管进程)
#################################

echo "[+] 启动Xray进程中..."

# 使用 exec 替换当前进程，让 Xray 在前台持续运行。容器将保持存活直到 Xray 停止。
exec ./xray run -c config.json
