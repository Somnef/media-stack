#!/bin/bash
# Restore config/ and .env from a backup tarball.
# Usage: ./restore-config.sh /path/to/media-config-YYYY-MM-DD.tar.gz
set -euo pipefail

STACK=/opt/media-stack
ARCHIVE="${1:-}"

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "usage: $0 <media-config-YYYY-MM-DD.tar.gz>" >&2
  exit 1
fi

echo "== archive contents (top level)"
tar tzf "$ARCHIVE" | cut -d/ -f1 | sort -u

echo
read -rp "This overwrites $STACK/config and $STACK/.env. Continue? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || exit 1

cd "$STACK"

if [[ -d config ]]; then
  mv config "config.pre-restore-$(date +%s)"
  echo "== existing config moved aside"
fi

docker compose down
tar xzf "$ARCHIVE" -C "$STACK"
chown -R "$(id -u somnef):$(id -g somnef)" "$STACK/config" "$STACK/.env"
docker compose up -d

echo
echo "== restored. check:"
echo "   docker compose ps"
echo "   docker exec qbittorrent curl -s ifconfig.io"
echo
echo "If /data is empty but the databases are full, the *arr apps will"
echo "re-download everything. Unmonitor first if that isn't what you want."
