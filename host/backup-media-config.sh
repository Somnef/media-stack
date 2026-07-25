#!/bin/bash
set -euo pipefail

STACK=/opt/media-stack
DEST=/home/somnef/backups
KEEP=1

mkdir -p "$DEST"
cd "$STACK"

docker compose stop
tar czf "$DEST/media-config-$(date +%F).tar.gz" config/ .env
chown somnef:somnef "$DEST/media-config-$(date +%F).tar.gz"
docker compose start

ls -1t "$DEST"/media-config-*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm --
