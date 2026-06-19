#!/bin/sh
set -eu

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$BASE_DIR/x_cf}"

UUID="${UUID:-}"
XRAY_PORT="${ARGO_PORT:-${XRAY_PORT:-8001}}"
ARGO_AUTH="${ARGO_AUTH:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
CFIP="${CFIP:-www.visa.cn}"
CFPORT="${CFPORT:-443}"
XHTTP_PATH="${XHTTP_PATH:-}"
XHTTP_PATH_BASE="${XHTTP_PATH_BASE:-/api/v1}"
XHTTP_PATH_LEN="${XHTTP_PATH_LEN:-8}"
XRAY_FORCE_UPDATE="${XRAY_FORCE_UPDATE:-false}"
CLOUDFLARED_FORCE_UPDATE="${CLOUDFLARED_FORCE_UPDATE:-false}"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

die() {
  echo "[!] $*" >&2
  exit 1
}

random_path() {
  if [ "$XHTTP_PATH_LEN" -gt 0 ] 2>/dev/null; then
    rand="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$XHTTP_PATH_LEN")"
    printf '%s/%s' "$XHTTP_PATH_BASE" "$rand"
  else
    printf '%s' "$XHTTP_PATH_BASE"
  fi
}

load_or_create_uuid() {
  if [ -n "$UUID" ]; then
    printf '%s' "$UUID" > uuid.txt
    echo "$UUID"
  elif [ -s uuid.txt ]; then
    cat uuid.txt
  else
    value="$(cat /proc/sys/kernel/random/uuid)"
    printf '%s' "$value" > uuid.txt
    echo "$value"
  fi
}

load_or_create_path() {
  if [ -n "$XHTTP_PATH" ]; then
    printf '%s' "$XHTTP_PATH" > xhttp_path.txt
    echo "$XHTTP_PATH"
  elif [ -s xhttp_path.txt ]; then
    cat xhttp_path.txt
  else
    value="$(random_path)"
    printf '%s' "$value" > xhttp_path.txt
    echo "$value"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      XRAY_ARCH="64"
      CF_ARCH="amd64"
      ;;
    aarch64|arm64)
      XRAY_ARCH="arm64-v8a"
      CF_ARCH="arm64"
      ;;
    *)
      die "unsupported architecture: $(uname -m)"
      ;;
  esac
}

download_xray() {
  if [ ! -x xray ] || [ "$XRAY_FORCE_UPDATE" = "true" ]; then
    url="https://download.lycn.qzz.io/xray-linux-${XRAY_ARCH}"
    echo "[+] Downloading Xray: $url"
    curl -fL --retry 3 --connect-timeout 15 -o xray.zip "$url"
    unzip -q -o xray.zip xray
    chmod +x xray
    rm -f xray.zip
  fi
}

download_cloudflared() {
  if [ ! -x cloudflared ] || [ "$CLOUDFLARED_FORCE_UPDATE" = "true" ]; then
    url="https://download.lycn.qzz.io/cloudflared-linux-${CF_ARCH}"
    echo "[+] Downloading cloudflared: $url"
    curl -fL --retry 3 --connect-timeout 15 -o cloudflared "$url"
    chmod +x cloudflared
  fi
}

cleanup() {
  [ -n "${CLOUDFLARED_PID:-}" ] && kill "$CLOUDFLARED_PID" 2>/dev/null || true
  [ -n "${XRAY_PID:-}" ] && kill "$XRAY_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

[ -n "$ARGO_AUTH" ] || die "ARGO_AUTH is required"
[ -n "$ARGO_DOMAIN" ] || die "ARGO_DOMAIN is required"

UUID="$(load_or_create_uuid)"
XHTTP_PATH="$(load_or_create_path)"

detect_arch
download_xray

cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "host": "",
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

echo "[+] Starting Xray on 127.0.0.1:${XRAY_PORT}"
./xray run -c config.json > run.log 2>&1 &
XRAY_PID="$!"
sleep 1
kill -0 "$XRAY_PID" 2>/dev/null || {
  cat run.log >&2
  die "Xray failed to start"
}

download_cloudflared

ENCODED_PATH="$(printf '%s' "$XHTTP_PATH" | sed 's/\//%2F/g')"
VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&type=xhttp&path=${ENCODED_PATH}&host=${ARGO_DOMAIN}&sni=${ARGO_DOMAIN}#VLESS-XHTTP-ARGO"

echo
echo "========= Node Info ========="
echo "Mode       : Argo Tunnel"
echo "UUID       : $UUID"
echo "Local port : $XRAY_PORT"
echo "Argo host  : $ARGO_DOMAIN"
echo "CF address : ${CFIP}:${CFPORT}"
echo "Path       : $XHTTP_PATH"
echo "Link       : $VLESS_LINK"
echo "============================="
echo
echo "[+] Starting cloudflared tunnel"

./cloudflared tunnel run --token "$ARGO_AUTH" &
CLOUDFLARED_PID="$!"
wait "$CLOUDFLARED_PID"
