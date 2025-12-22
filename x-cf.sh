#!/bin/sh
set -e

#################################
# 基础路径与变量
#################################
# WARP_MODE 控制 WARP 接管的流量类型：
#   all  - 接管所有流量 (IPv4 + IPv6) (默认)
#   v4   - 仅接管 IPv4 流量，IPv6 直连
#   v6   - 仅接管 IPv6 流量，IPv4 直连
#   off  - 关闭 WARP，全部直连
WARP_MODE=${WARP_MODE:-"all"}

# WARP 接口地址 (参考 argosbx)
WARP_API="https://ygkkk-warp.renky.eu.org"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$BASE_DIR/x_cf"

### ====== 基础变量 ======
XRAY_PORT=${ARGO_PORT:-5216}
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
ARGO_AUTH=${ARGO_AUTH:-"ey"}
ARGO_DOMAIN=${ARGO_DOMAIN:-"domain"}
CFIP_v4=${CFIP_v4:-"cf.ljy.abrdns.com"}
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
# 网络环境探测
#################################
HAS_IPV6=0
if ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1; then
  HAS_IPV6=1
fi

HAS_IPV4=0
if ip -4 route get 8.8.8.8 >/dev/null 2>&1; then
  HAS_IPV4=1
fi

#################################
# 下载函数
#################################
download_file() {
    url="$1"
    outfile="$2"
    # 纯v6环境处理
    V6_FLAG=""
    [ "$HAS_IPV4" -eq 0 ] && [ "$HAS_IPV6" -eq 1 ] && V6_FLAG="-6"
    
    if command -v curl >/dev/null 2>&1; then
        curl $V6_FLAG -L -o "$outfile" "$url"
    elif command -v wget >/dev/null 2>&1; then
        if [ "$HAS_IPV4" -eq 0 ]; then wget -6 -O "$outfile" "$url"; else wget -O "$outfile" "$url"; fi
    else
        echo "错误: 未找到 curl 或 wget"; exit 1
    fi
}

#################################
# 获取 WARP 账号
#################################
get_warp_config() {
    echo "[+] 正在获取 WARP 账户信息 (API: $WARP_API)..."

    CURL_OPTS="-sm 8 -k"
    [ "$HAS_IPV4" -eq 0 ] && CURL_OPTS="$CURL_OPTS -6"
    [ "$HAS_IPV6" -eq 0 ] && CURL_OPTS="$CURL_OPTS -4"

    # 获取 WARP 内容
    warp_content=$(curl $CURL_OPTS "$WARP_API" 2>/dev/null || wget -qO- --timeout=8 "$WARP_API" 2>/dev/null || echo "failed")

    # 调试输出，可选
    echo "warp_content: $warp_content"

    if echo "$warp_content" | grep -q "ygkkk"; then
        echo "[+] 在线获取成功"

        # 修复解析逻辑：使用正则提取完整内容
        WARP_PVK=$(echo "$warp_content" | grep -oP 'Private_key[:：]\s*\K.*' | xargs)
        WARP_IPV6=$(echo "$warp_content" | grep -oP 'IPV6[:：]\s*\K.*' | xargs)
        WARP_RES=$(echo "$warp_content" | grep -oP 'reserved[:：]\s*\K\[.*?\]' | xargs)

        # 如果解析失败，回退到备用值
        [ -z "$WARP_PVK" ] && WARP_PVK='52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A='
        [ -z "$WARP_IPV6" ] && WARP_IPV6='2606:4700:110:8d8d:1845:c39f:2dd5:a03a'
        [ -z "$WARP_RES" ] && WARP_RES='[215, 69, 233]'
    else
        echo "[!] 在线获取失败，使用内置备用账号"
        WARP_IPV6='2606:4700:110:8d8d:1845:c39f:2dd5:a03a'
        WARP_PVK='52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A='
        WARP_RES='[215, 69, 233]'
    fi

    # 优选端点
    if [ "$HAS_IPV4" -eq 0 ] && [ "$HAS_IPV6" -eq 1 ]; then
        WARP_ENDPOINT="[2606:4700:d0::a29f:c001]:2408"
    else
        WARP_ENDPOINT="162.159.192.1:2408"
    fi

    echo "[+] WARP 配置生成完成"
    echo "    WARP_PVK: $WARP_PVK"
    echo "    WARP_IPV6: $WARP_IPV6"
    echo "    WARP_RES: $WARP_RES"
    echo "    WARP_ENDPOINT: $WARP_ENDPOINT"
}


#################################
# 部署 Xray
#################################
if [ ! -f xray ]; then
  echo "[+] 下载 Xray"
  download_file "https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}" "xray.zip"
  unzip -q xray.zip geoip.dat geosite.dat xray && chmod +x xray && rm -f xray.zip
fi

#################################
# 生成 Xray 配置 (含分流逻辑)
#################################
LISTEN_ADDR="0.0.0.0"
[ "$HAS_IPV6" -eq 1 ] && LISTEN_ADDR="::"

# 1. 构建 WARP 出站配置 (Outbound)
if [ "$WARP_MODE" != "off" ]; then
    get_warp_config
    
    # 这里的 allowedIPs 设为全通，具体的流量控制交给 Routing
    WARP_OUTBOUND=$(cat <<EOF
    {
      "tag": "warp-out",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${WARP_PVK}",
        "address": [ "172.16.0.2/32", "${WARP_IPV6}/128" ],
        "peers": [
          {
            "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "allowedIPs": ["0.0.0.0/0", "::/0"],
            "endpoint": "${WARP_ENDPOINT}"
          }
        ],
        "reserved": ${WARP_RES}
      }
    },
EOF
)
else
    WARP_OUTBOUND=""
fi

# 2. 构建路由规则 (Routing Rules)
# 通过 ip 列表来匹配流量并导向 warp-out
if [ "$WARP_MODE" != "off" ]; then
    case "$WARP_MODE" in
        v4)
            # 只有 IPv4 地址走 WARP，IPv6 走默认(直连)
            ROUTE_IP_LIST='"0.0.0.0/0"'
            ;;
        v6)
            # 只有 IPv6 地址走 WARP，IPv4 走默认(直连)
            ROUTE_IP_LIST='"::/0"'
            ;;
        all)
            # 所有地址走 WARP
            ROUTE_IP_LIST='"0.0.0.0/0", "::/0"'
            ;;
        *)
            # 默认全走 (容错)
            ROUTE_IP_LIST='"0.0.0.0/0", "::/0"'
            ;;
    esac

    ROUTING_BLOCK=$(cat <<EOF
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [ ${ROUTE_IP_LIST} ],
        "outboundTag": "warp-out"
      }
    ]
  },
EOF
)
else
    ROUTING_BLOCK=""
fi

# 3. 写入最终 config.json
cat > config.json <<EOF
{
  "log": { "loglevel": "none" },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1"]
  },

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
    }
  ],
  "outbounds": [
    ${WARP_OUTBOUND}
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIP" },
      "tag": "direct"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["youtube.com", "www.youtube.com", "m.youtube.com" ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": [ "0.0.0.0/0" ],
        "outboundTag": "$( [ "$WARP_MODE" = "v4" ] || [ "$WARP_MODE" = "all" ] && echo "warp-out" || echo "direct" )"
      },
      {
        "type": "field",
        "ip": [ "::/0" ],
        "outboundTag": "$( [ "$WARP_MODE" = "v6" ] || [ "$WARP_MODE" = "all" ] && echo "warp-out" || echo "direct" )"
      }
    ]
  }
}
EOF

#################################
# 启动服务
#################################
echo "[+] 启动 Xray..."
pkill -9 xray || true
nohup ./xray run -c config.json > run.log 2>&1 &
sleep 1
pgrep xray >/dev/null || { echo "[!] Xray 启动失败"; cat run.log; exit 1; }

echo "[+] 启动 Cloudflare Tunnel..."
if [ ! -f cloudflared ]; then
  download_file "https://download.lycn.qzz.io/cloudflared-linux-${CF_ARCH}" "cloudflared"
  chmod +x cloudflared
fi

pkill -9 cloudflared || true
LOCAL_ADDR="localhost"
[ "$HAS_IPV6" -eq 1 ] && LOCAL_ADDR="[::1]"
CF_V6_FLAG=""
[ "$HAS_IPV4" -eq 0 ] && [ "$HAS_IPV6" -eq 1 ] && CF_V6_FLAG="--edge-ip-version 6"

DOMAIN=""
if [ -n "$ARGO_AUTH" ] && [ "$ARGO_AUTH" != "ey" ]; then
  nohup ./cloudflared tunnel $CF_V6_FLAG run --token "$ARGO_AUTH" >> run.log 2>&1 &
  DOMAIN="$ARGO_DOMAIN"
else
  nohup ./cloudflared tunnel $CF_V6_FLAG --url http://${LOCAL_ADDR}:${XRAY_PORT} > cf.log 2>&1 &
  echo "[*] 等待域名生成..."
  for i in $(seq 1 20); do
    DOMAIN=$(grep -o 'https://.*trycloudflare.com' cf.log | head -n1 | sed 's#https://##')
    [ -n "$DOMAIN" ] && break
    sleep 1
  done
fi

#################################
# 结果输出
#################################
CFIP="$CFIP_v4"
[ "$HAS_IPV6" -eq 1 ] && CFIP="$CFIP_v6"

VMESS_JSON=$(cat <<EOF
{
  "v":"2",
  "ps":"ARGO-WARP[${WARP_MODE}]",
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
VMESS_LINK="vmess://$(echo "$VMESS_JSON" | base64 | tr -d '\n')"

echo
echo "======================================"
echo "Argo 域名: $DOMAIN"
echo "WARP 模式: $WARP_MODE"
case "$WARP_MODE" in
  all) echo "   -> IPv4 和 IPv6 流量均通过 WARP 出站 (隐藏 VPS IP)" ;;
  v4)  echo "   -> 仅 IPv4 流量通过 WARP，IPv6 直连" ;;
  v6)  echo "   -> 仅 IPv6 流量通过 WARP，IPv4 直连" ;;
  off) echo "   -> WARP 未启用，全部直连" ;;
esac
echo "======================================"
echo "$VMESS_LINK"
echo "======================================"
