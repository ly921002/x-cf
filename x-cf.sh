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
ARGO_AUTH=${ARGO_AUTH:-"ey"}
ARGO_DOMAIN=${ARGO_DOMAIN:-"domain"}
CFIP_v4=${CFIP_v4:-"ip.sb"}
CFPORT=${CFPORT:-443}
CFIP_v6=${CFIP_v6:-"ip.sb"}
#################################
# 初始化目录
#################################
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
# IPv6 探测
#################################
HAS_IPV6=0
if ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1; then
  HAS_IPV6=1
fi

#################################
# 下载 Xray
#################################
# 针对纯 IPv6 环境，强制 使用 IPv6 下载
V6=""
[ "$HAS_IPV6" -eq 1 ] && V6="-6"

if [ ! -f xray ]; then
  echo "[+] 下载 Xray"
  curl $V6 -L -o xray.zip \
    "https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
  unzip -q xray.zip xray
  chmod +x xray
  rm -f xray.zip
fi

#################################
# 生成 Xray 配置
#################################
# 统一监听地址：IPv6 开启则听 ::，否则听 0.0.0.0
LISTEN_ADDR="127.0.0.1"
[ "$HAS_IPV6" -eq 1 ] && LISTEN_ADDR_V6="::1"


cat > config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "listen": "$LISTEN_ADDR",
      "port": ${XRAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${UUID}", "alterId": 0 }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess-argo" }
      }
    },
    {
      "listen": "$LISTEN_ADDR_V6",
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
  "outbounds": [{ "protocol": "freedom" }]
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
  if ! ss -lnt | grep -q ":${XRAY_PORT}"; then
    echo "[!] Xray 未监听端口 ${XRAY_PORT}"
    exit 1
  fi
  echo "[!] Xray 启动失败"
  exit 1
fi
sleep 1

#################################
# 下载 cloudflared
#################################
if [ ! -f cloudflared ]; then
  echo "[+] 下载 cloudflared"
  curl $V6 -L -o cloudflared \
    "https://download.lycn.qzz.io/cloudflared-linux-${CF_ARCH}"
  chmod +x cloudflared
fi

#################################
# 启动 Cloudflare Tunnel
#################################
DOMAIN=""
pkill -f "$WORKDIR/cloudflared tunnel" || true

LOCAL_ADDR="127.0.0.1"
[ "$HAS_IPV6" -eq 1 ] && LOCAL_ADDR="[::1]" && echo "[+] IPV6 LOCAL_ADDR为[::1]"

CF_ARGS="--no-autoupdate --protocol auto"

# 纯 IPv6 环境强制用 v6，否则默认 v4
if [ "$HAS_IPV6" -eq 1 ]; then
  echo "启动 Cloudflare Tunnel，IPv6 环境强制用 v6"
  CF_ARGS="$CF_ARGS --edge-ip-version 6"
else
  echo "启动 Cloudflare Tunnel，非IPv6 环境使用默认"
  CF_ARGS="$CF_ARGS --edge-ip-version 4"
fi

if [ -n "$ARGO_AUTH" ]; then
  echo "[+] 使用固定 Argo 隧道"
  nohup ./cloudflared tunnel $CF_ARGS \
    --url http://${LOCAL_ADDR}:${XRAY_PORT} \
    run --token "$ARGO_AUTH" \
    >> run.log 2>&1 &
  DOMAIN="$ARGO_DOMAIN"
else
  echo "[+] 使用临时 TryCloudflare 隧道"
  nohup ./cloudflared tunnel $CF_ARGS \
    --url http://${LOCAL_ADDR}:${XRAY_PORT} \
    > cf.log 2>&1 &

  echo "[*] 等待域名生成..."
  for i in $(seq 1 20); do
    DOMAIN=$(grep -o 'https://.*trycloudflare.com' cf.log \
      | head -n1 | sed 's#https://##')
    [ -n "$DOMAIN" ] && break
    sleep 1
  done
fi
sleep 1
if ! pgrep cloudflared >/dev/null; then
  echo "[!] cloudflared 启动失败"
  exit 1
fi

#################################
# 输出节点信息
#################################
CFIP="$CFIP_v4"
[ "$HAS_IPV6" -eq 1 ] && CFIP="$CFIP_v6"

VMESS_JSON=$(cat <<EOF
{
  "v":"2",
  "ps":"ARGO-VMESS",
  "add":"${CFIP}",
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

# 编码为 vmess 链接
VMESS_LINK="vmess://$(echo "$VMESS_JSON" | base64 | tr -d '\n')"

echo
echo "========= 节点信息 ========="
echo "Argo 域名: $DOMAIN"
echo "SNI: $DOMAIN"
echo "本地 IP 类型: $( [ "$HAS_IPV6" -eq 1 ] && echo "IPv6" || echo "IPv4" )"
echo
echo "$VMESS_LINK"
echo "============================"
