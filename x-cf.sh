#!/bin/sh
set -eu

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$BASE_DIR/xray}"

UUID="${UUID:-}"
XRAY_PORT="${XRAY_PORT:-8443}"
XHTTP_PATH="${XHTTP_PATH:-}"
XHTTP_PATH_BASE="${XHTTP_PATH_BASE:-${BASE:-/api/v1}}"
XHTTP_PATH_LEN="${XHTTP_PATH_LEN:-${PATH_LENGTH:-8}}"
SERVER_NAME="${SERVER_NAME:-}"
SERVER_REGION="${SERVER_REGION:-us}"
SERVER_IP="${SERVER_IP:-}"
PRIVATE_KEY="${PRIVATE_KEY:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
SHORT_ID="${SHORT_ID:-}"
XRAY_FORCE_UPDATE="${XRAY_FORCE_UPDATE:-false}"
VLESS_NAME="${VLESS_NAME:-VLESS-XHTTP-REALITY}"

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
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
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
load_or_create_reality_keys() {
  if [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ]; then
    printf '%s' "$PRIVATE_KEY" > private_key.txt
    printf '%s' "$PUBLIC_KEY" > public_key.txt
    return
  fi

  if [ -s private_key.txt ] && [ -s public_key.txt ]; then
    PRIVATE_KEY="$(cat private_key.txt)"
    PUBLIC_KEY="$(cat public_key.txt)"
    return
  fi

  key_output="$(./xray x25519 2>/dev/null)"
  PRIVATE_KEY="$(echo "$key_output" | awk -F': ' '/Private/ {print $2; exit}')"
  PUBLIC_KEY="$(echo "$key_output" | awk -F': ' '/Public/ {print $2; exit}')"

  [ -n "$PRIVATE_KEY" ] || die "failed to parse Reality private key"
  [ -n "$PUBLIC_KEY" ] || die "failed to parse Reality public key"

  printf '%s' "$PRIVATE_KEY" > private_key.txt
  printf '%s' "$PUBLIC_KEY" > public_key.txt
}

load_or_create_short_id() {
  if [ -n "$SHORT_ID" ]; then
    printf '%s' "$SHORT_ID" > short_id.txt
    echo "$SHORT_ID"
  elif [ -s short_id.txt ]; then
    cat short_id.txt
  else
    value="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$value" > short_id.txt
    echo "$value"
  fi
}

pick_server_name() {
  if [ -n "$SERVER_NAME" ]; then
    echo "$SERVER_NAME"
    return
  fi

  if [ -s server_name.txt ]; then
    cat server_name.txt
    return
  fi

  if [ -n "$SERVERS" ]; then
    value="$(printf '%s\n' "$SERVERS" | shuf -n1)"
  else
    case "$SERVER_REGION" in
      us)
        value="$(printf '%s\n' \
          mirrors.ocf.berkeley.edu \
          mirrors.us.kernel.org \
          archive.linux.duke.edu \
          mirrors.mit.edu | shuf -n1)"
        ;;
      jp)
        value="$(printf '%s\n' \
          ftp.tsukuba.wide.ad.jp \
          linux.yz.yamagata-u.ac.jp | shuf -n1)"
        ;;
      de)
        value="$(printf '%s\n' \
          ftp.rz.tu-bs.de \
          drmirror.physi.uni-heidelberg.de | shuf -n1)"
        ;;
    esac
  fi

  printf '%s' "$value" > server_name.txt
  echo "$value"
}

detect_public_ip() {
  if [ -n "$SERVER_IP" ]; then
    echo "$SERVER_IP"
    return
  fi

  ip="$(curl -fsS4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -fsS4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  [ -n "$ip" ] || ip="YOUR_SERVER_IP"
  echo "$ip"
}

UUID="$(load_or_create_uuid)"
XHTTP_PATH="$(load_or_create_path)"

detect_arch
download_xray
show_xray_version
xray_vlessenc
load_or_create_reality_keys

SHORT_ID="$(load_or_create_short_id)"
SERVER_NAME="$(pick_server_name)"
SERVER_IP="$(detect_public_ip)"
DEST="${SERVER_NAME}:443"

cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
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
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SERVER_NAME}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
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
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=${ENKEY}&security=reality&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${SERVER_NAME}&fp=chrome&type=xhttp&flow=xtls-rprx-vision&path=${ENCODED_PATH}#${VLESS_NAME}"

echo
echo "========= Node Info ========="
echo "Xray      : $XRAY_VERSION"
echo "Mode      : Reality"
echo "Address   : ${SERVER_IP}:${XRAY_PORT}"
echo "UUID      : $UUID"
echo "SNI       : $SERVER_NAME"
echo "PublicKey : $PUBLIC_KEY"
echo "ShortID   : $SHORT_ID"
echo "Path      : $XHTTP_PATH"
echo "Link      : $VLESS_LINK"
echo "Encryption: $ENKEY"
echo "============================="
echo
echo "[+] Starting Xray"

exec ./xray run -c config.json
