#!/usr/bin/env bash
set -euo pipefail

# Run after the 500GB zero pass completes.
# Re-creates LUKS, formats ext4, initializes restic, sets up auto-mount.
# Must be run as root (or with appropriate sudo).

KEYFILE="/home/vela/.backup-keys/luks-backup.key"
RESTIC_PASSWORD_FILE="/home/vela/.backup-keys/restic-password.txt"
DEV="/dev/sda"
MAPPER="backup-local"
MNT="/mnt/backup-local"

echo "=== Setting up 500GB local backup drive ==="

echo "[1/6] LUKS format"
cryptsetup luksFormat --type luks2 --key-file "$KEYFILE" "$DEV"

echo "[2/6] Open LUKS"
cryptsetup open --type luks2 --key-file "$KEYFILE" "$DEV" "$MAPPER"

echo "[3/6] Format ext4"
mkfs.ext4 -L backup-local /dev/mapper/"$MAPPER"

echo "[4/6] Set ownership and mount"
chown vela:vela "$MNT"
mount /dev/mapper/"$MAPPER" "$MNT"
chown vela:vela "$MNT"

echo "[5/6] Initialize restic repo"
sudo -u vela restic -r "$MNT" --password-file "$RESTIC_PASSWORD_FILE" init

LUKS_UUID=$(blkid -s UUID -o value "$DEV")
FS_UUID=$(blkid -s UUID -o value /dev/mapper/"$MAPPER")

echo "[6/6] Auto-mount configuration"
echo ""
echo "Add to /etc/crypttab:"
echo "  $MAPPER  UUID=$LUKS_UUID  $KEYFILE  luks,nofail"
echo ""
echo "Add to /etc/fstab:"
echo "  /dev/mapper/$MAPPER  $MNT  ext4  defaults,nofail  0  2"
echo ""
echo "LUKS UUID: $LUKS_UUID"
echo "FS UUID:   $FS_UUID"
echo ""
echo "Then run:"
echo "  systemctl daemon-reload"
echo "  sudo cp /home/vela/agent/config/restic-backup.service /etc/systemd/system/"
echo "  sudo cp /home/vela/agent/config/restic-backup.timer /etc/systemd/system/"
echo "  sudo cp /home/vela/agent/config/restic-backup-offsite.service /etc/systemd/system/"
echo "  systemctl daemon-reload"
echo "  systemctl enable --now restic-backup.timer"
echo ""
echo "=== Local backup drive ready ==="
