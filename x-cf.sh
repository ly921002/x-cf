#!/bin/sh
set -e

#################################
# 基础路径与环境
#################################
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASE_DIR/x_cf"

### ====== 基础变量 ======
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
PORT=${PORT:-8001}                 # 本地 Xray 监听端口
DOMAIN=${DOMAIN:-"domain"}         # CDN 域名
XRAY_FORCE_UPDATE=${XRAY_FORCE_UPDATE:-false} # 统一强制更新变量名

# 证书路径变量化，方便跨环境迁移
CERT_FILE=${CERT_FILE:-"/cert/cert.pem"}
KEY_FILE=${KEY_FILE:-"/cert/key.key"}

# 路径变量
XHTTP_PATH_LEN=${XHTTP_PATH_LEN:-8}           # 随机路径长度
XHTTP_PATH_BASE=${XHTTP_PATH_BASE:-"/api/v1"} # 固定路径

if [ "$XHTTP_PATH_LEN" -gt 0 ]; then
  RAND=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$XHTTP_PATH_LEN")
  XHTTP_PATH="${XHTTP_PATH_BASE}/${RAND}"
else
  XHTTP_PATH="${XHTTP_PATH_BASE}"
fi

#################################
# 初始化与架构判断
#################################
mkdir -p "$WORKDIR"
cd "$WORKDIR"

ARCH=$(uname -m)
echo "[*] 识别系统架构: $ARCH"
case "$ARCH" in
  x86_64)
    XRAY_ARCH="64" # 注意: 官方通常为 amd64，此处依你的镜像源保持 64
    ;;
  aarch64|arm64)
    XRAY_ARCH="arm64-v8a"
    ;;
  *)
    echo "[!] 不支持的架构: $ARCH"
    exit 1
    ;;
esac

#################################
# 证书检测
#################################
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  echo "[!] 证书或私钥缺失，请检查路径:"
  echo "    Cert: $CERT_FILE"
  echo "    Key:  $KEY_FILE"
  exit 1
fi

#################################
# 下载 Xray
#################################
if [ ! -f xray ] || [ "$XRAY_FORCE_UPDATE" = "true" ]; then
  echo "[+] 开始下载/更新 Xray (架构: ${XRAY_ARCH})"
  DOWNLOAD_URL="https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
  echo "    地址: $DOWNLOAD_URL"
  
  # 增加 -f 避免下载 404 页面，增加 -o 强制覆盖旧文件
  curl -fL -o xray.zip "$DOWNLOAD_URL"
  unzip -q -o xray.zip xray
  chmod +x xray
  rm -f xray.zip
fi

#################################
# 生成 Xray 配置
#################################
echo "[+] 生成 Xray 配置文件"
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "alpn": ["h3","h2"],
          "minVersion": "1.3",
          "certificates": [
            {
              "certificateFile": "${CERT_FILE}",
              "keyFile": "${KEY_FILE}"
            }
          ]
        },
        "xhttpSettings": {
          "host": "",
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

#################################
# 启动 Xray
#################################
echo "[+] 启动 Xray 进程"
pkill -f "$WORKDIR/xray run" || true

nohup ./xray run -c config.json > run.log 2>&1 &
XRAY_PID=$! # 捕获特定后台进程的 PID

sleep 1

# 精确检查刚启动的 PID 是否存活
if ! kill -0 $XRAY_PID 2>/dev/null; then
  echo "[!] Xray 启动失败！"
  echo "====== 错误日志 ======"
  cat run.log
  exit 1
fi

echo "[*] Xray 成功运行 (PID: $XRAY_PID)"

#################################
# 输出节点信息
#################################
ENCODED_PATH=$(printf '%s' "$XHTTP_PATH" | sed 's/\//%2F/g')

VLESS_LINK="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&type=xhttp&path=${ENCODED_PATH}&host=${DOMAIN}&sni=${DOMAIN}#VLESS-XHTTP-CDN"

echo
echo "========= 节点信息 ========="
echo "UUID: $UUID"
echo "CDN 域名: $DOMAIN"
echo "XHTTP_PATH: ${XHTTP_PATH}"
echo "----------------------------"
echo "VLESS 分享链接:"
echo "$VLESS_LINK"
echo "============================"
