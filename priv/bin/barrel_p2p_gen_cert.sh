#!/usr/bin/env bash
#
# barrel_p2p_gen_cert.sh — generate a self-signed QUIC TLS cert for a
# barrel_p2p node.
#
# The kernel boots `-proto_dist quic` distribution before barrel_p2p's
# application code runs, so the cert must already exist on disk;
# `quic_dist:listen/2' fails with `{credentials, no_credentials}'
# otherwise. Run this once before the first boot.
#
# Usage:
#   barrel_p2p_gen_cert.sh [options]
#
# Options:
#   -d, --out-dir DIR   output directory (default ./data/quic)
#   -c, --cn NAME       certificate Common Name (default barrel_p2p)
#   -D, --days N        validity in days (default 365)
#   -k, --key-bits N    RSA key size (default 2048)
#   -f, --force         overwrite existing files
#   -h, --help          show this help
#
# Exit codes: 0 success, 2 usage error, 3 openssl missing or failed.

set -euo pipefail

usage() {
    sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
}

OUT_DIR="./data/quic"
CN="barrel_p2p"
DAYS=365
KEY_BITS=2048
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--out-dir)  OUT_DIR="$2"; shift 2 ;;
        -c|--cn)       CN="$2"; shift 2 ;;
        -D|--days)     DAYS="$2"; shift 2 ;;
        -k|--key-bits) KEY_BITS="$2"; shift 2 ;;
        -f|--force)    FORCE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "barrel_p2p_gen_cert: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if ! command -v openssl >/dev/null 2>&1; then
    echo "barrel_p2p_gen_cert: openssl not found in PATH" >&2
    exit 3
fi

CERT="$OUT_DIR/node.crt"
KEY="$OUT_DIR/node.key"

if [[ -f "$CERT" && -f "$KEY" && $FORCE -eq 0 ]]; then
    echo "barrel_p2p_gen_cert: $CERT and $KEY already exist (use --force to overwrite)"
    exit 0
fi

mkdir -p "$OUT_DIR"

if ! openssl req -x509 \
        -newkey "rsa:$KEY_BITS" -nodes \
        -days "$DAYS" \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$CN" 2>/dev/null
then
    echo "barrel_p2p_gen_cert: openssl failed" >&2
    exit 3
fi

chmod 600 "$KEY"
echo "barrel_p2p_gen_cert: wrote $CERT and $KEY (CN=$CN, valid $DAYS days)"
