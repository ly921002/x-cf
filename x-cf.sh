#!/bin/sh
set -eu

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$BASE_DIR/x_cf}"

UUID="${UUID:-}"
PORT="${PORT:-${XRAY_PORT:-8001}}"
DOMAIN="${DOMAIN:-}"
CFIP="${CFIP:-}"
CFPORT="${CFPORT:-}"
CERT_FILE="${CERT_FILE:-/cert/cert.pem}"
KEY_FILE="${KEY_FILE:-/cert/key.key}"
XHTTP_PATH="${XHTTP_PATH:-}"
XHTTP_PATH_BASE="${XHTTP_PATH_BASE:-/api/v1}"
XHTTP_PATH_LEN="${XHTTP_PATH_LEN:-8}"
XRAY_FORCE_UPDATE="${XRAY_FORCE_UPDATE:-false}"
VLESS_NAME="${VLESS_NAME:-VLESS-XHTTP-CDN}"
PIN_CERT="${PIN_CERT:-}"
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
      ;;
    aarch64|arm64)
      XRAY_ARCH="arm64-v8a"
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
show_xray_version() {
  XRAY_VERSION="$(./xray version | head -n1)"
}
xray_vlessenc() {
    if [ -s enc_dekey.txt ] && [ -s enc_enkey.txt ]; then
        DEKEY=$(cat enc_dekey.txt)
        ENKEY=$(cat enc_enkey.txt)
        return
    fi

    ./xray vlessenc > enc.json

    DEKEY=$(awk -F'"' '/decryption/ {print $4}' enc.json | tail -1)
    ENKEY=$(awk -F'"' '/encryption/ {print $4}' enc.json | tail -1)

    echo "$DEKEY" > enc_dekey.txt
    echo "$ENKEY" > enc_enkey.txt

    rm -f enc.json
}
[ -n "$DOMAIN" ] || die "DOMAIN is required"
[ -f "$CERT_FILE" ] || die "certificate file not found: $CERT_FILE"
[ -f "$KEY_FILE" ] || die "private key file not found: $KEY_FILE"

generate_pin() {
    if [ -n "$PIN_CERT" ]; then
        return
    fi

    PIN_CERT=$(openssl s_client \
    -connect "${DOMAIN}:443" \
    -servername "${DOMAIN}" </dev/null 2>/dev/null \
    | openssl x509 -pubkey -noout \
    | openssl pkey -pubin -outform der \
    | openssl dgst -sha256  \
    | awk '{print $2}')

}


CONNECT_HOST="${CFIP:-$DOMAIN}"
CONNECT_PORT="${CFPORT:-$PORT}"

UUID="$(load_or_create_uuid)"
XHTTP_PATH="$(load_or_create_path)"

detect_arch
download_xray
show_xray_version
xray_vlessenc
generate_pin
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${DEKEY}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "alpn": ["h3", "h2"],
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

ENCODED_PATH="$(printf '%s' "$XHTTP_PATH" | sed 's/\//%2F/g')"
VLESS_LINK="vless://${UUID}@${CONNECT_HOST}:${CONNECT_PORT}?encryption=${ENKEY}&security=tls&type=xhttp&flow=xtls-rprx-vision&path=${ENCODED_PATH}&host=${DOMAIN}&sni=${DOMAIN}#${VLESS_NAME}"

echo
echo "========= Node Info ========="
echo "Xray   : $XRAY_VERSION"
echo "Mode   : CDN"
echo "UUID   : $UUID"
echo "Domain : $DOMAIN"
echo "Port   : $PORT"
echo "PinSHA256 : $PIN_CERT"
echo "Connect: ${CONNECT_HOST}:${CONNECT_PORT}"
echo "Path   : $XHTTP_PATH"
echo "Link   : $VLESS_LINK"
echo "Encryption : $ENKEY"
echo "============================="
echo
echo "[+] Starting Xray"

exec ./xray run -c config.json
