#!/bin/bash
# Deploys host-level config on a fresh machine. Run with sudo from the repo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo" >&2
  exit 1
fi

echo "== backup script"
install -m 755 "$HERE/backup-media-config.sh" /usr/local/bin/backup-media-config.sh

echo "== systemd units"
install -m 644 "$HERE/media-backup.service" /etc/systemd/system/
install -m 644 "$HERE/media-backup.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now media-backup.timer

echo "== fstab"
if grep -q '/data' /etc/fstab; then
  echo "   /data entry already present, skipping"
else
  cat "$HERE/fstab.line" >> /etc/fstab
  echo "   added — check the UUID matches this machine's disk:"
  cat "$HERE/fstab.line"
fi

echo
echo "NOT applied automatically (review first):"
echo "  netplan.yaml       -> /etc/netplan/00-installer-config.yaml"
echo "                        then: netplan try"
echo "  pull-media-config.ps1 -> the Windows machine, not here"
echo
echo "Also check: static MAC in the hypervisor, DHCP reservation on the router."
