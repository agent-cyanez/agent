#!/usr/bin/env bash
set -euo pipefail

KEYFILE="/home/vela/.backup-keys/luks-backup.key"
RESTIC_PASSWORD_FILE="/home/vela/.backup-keys/restic-password.txt"
LOGFILE="/home/vela/agent/log/backup.log"

TARGETS=(
    local:/dev/sda:backup-local:/mnt/backup-local
    offsite:/dev/sdb:backup-offsite:/mnt/backup-offsite
)

BACKUP_PATHS=(
    /home/nosferath/projects
    /home/nosferath/Zettelkasten
    /home/nosferath/tools
    /home/nosferath/ubc
    /home/nosferath/aws
    /home/nosferath/dotfiles
    /home/nosferath/data
    "/DATA/3D Prints"
    /DATA/Gallery
    /DATA/Media
    /home/vela
    /etc/cloudflared
    /etc/crypttab
    /etc/fstab
    /etc/systemd/system/restic-backup.service
    /etc/systemd/system/restic-backup.timer
    /etc/systemd/system/restic-backup-offsite.service
    /etc/systemd/system/cloudflared.service
    /etc/systemd/system/cloudflared-update.service
    /etc/systemd/system/cloudflared-update.timer
)

EXCLUDE_PATTERNS=(
    --exclude='/home/nosferath/creditu'
    --exclude='/home/nosferath/projects/immich/data/upload/thumbs'
    --exclude='/home/nosferath/projects/immich/data/upload/encoded-video'
    --exclude='*.pyc'
    --exclude='__pycache__'
    --exclude='node_modules'
    --exclude='.git/objects/pack/*.pack'
    --exclude='/home/vela/.cache'
    --exclude='/home/vela/.local/share/claude/versions'
    --exclude='/home/vela/.local/share/mise'
)

RETENTION_LOCAL=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
RETENTION_OFFSITE=(--keep-monthly 6)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

usage() {
    cat <<EOF
Usage: $0 <command> [target]

Commands:
  run [local|offsite]   Run backup to target (default: local)
  status                Show backup info for all targets
  snapshots [target]    List snapshots
  unlock <target>       Open LUKS and mount
  lock <target>         Unmount and close LUKS
  init <target>         Initialize restic repo on target
  verify <target>       Check repo integrity

The local drive (500GB) is permanently mounted — daily backups via systemd timer.
The offsite drive (1TB) auto-unlocks/locks per run — triggered manually before rotation.
EOF
    exit 1
}

get_target() {
    local name="${1:-local}"
    for t in "${TARGETS[@]}"; do
        IFS=: read -r tname dev mapper mnt <<< "$t"
        if [[ "$tname" == "$name" ]]; then
            echo "$dev $mapper $mnt"
            return 0
        fi
    done
    echo "Unknown target: $name" >&2
    return 1
}

is_open() {
    local mapper="$1"
    [[ -e "/dev/mapper/$mapper" ]]
}

is_mounted() {
    local mnt="$1"
    mountpoint -q "$mnt" 2>/dev/null
}

check_drive() {
    local name="$1"
    read -r dev mapper mnt <<< "$(get_target "$name")"

    if ! sudo blkid "$dev" &>/dev/null; then
        log "ERROR: $dev not found — is the drive connected?"
        return 1
    fi

    if ! sudo cryptsetup isLuks "$dev" 2>/dev/null; then
        log "ERROR: $dev is not a LUKS device"
        return 1
    fi

    return 0
}

do_unlock() {
    local name="$1"
    read -r dev mapper mnt <<< "$(get_target "$name")"

    # Local drive is permanently mounted via crypttab/fstab — just verify
    if [[ "$name" == "local" ]]; then
        if ! is_mounted "$mnt"; then
            log "ERROR: local drive not mounted at $mnt — check crypttab/fstab"
            return 1
        fi
        log "$name drive ready at $mnt"
        return 0
    fi

    # Offsite drive: check presence, unlock, mount
    check_drive "$name" || return 1

    if ! is_open "$mapper"; then
        log "Opening LUKS on $dev as $mapper"
        sudo cryptsetup open --type luks2 --key-file "$KEYFILE" "$dev" "$mapper"
    fi

    if ! is_mounted "$mnt"; then
        log "Mounting $mapper at $mnt"
        sudo mount /dev/mapper/"$mapper" "$mnt"
    fi

    log "$name drive ready at $mnt"
}

do_lock() {
    local name="$1"
    read -r dev mapper mnt <<< "$(get_target "$name")"

    if is_mounted "$mnt"; then
        log "Unmounting $mnt"
        sudo umount "$mnt"
    fi

    if is_open "$mapper"; then
        log "Closing LUKS $mapper"
        sudo cryptsetup close "$mapper"
    fi

    log "$name drive locked"
}

do_init() {
    local name="$1"
    read -r dev mapper mnt <<< "$(get_target "$name")"

    do_unlock "$name"

    if [[ -f "$mnt/config" ]]; then
        log "Restic repo already initialized on $name"
        return 0
    fi

    log "Initializing restic repo on $name"
    restic -r "$mnt" --password-file "$RESTIC_PASSWORD_FILE" init
    log "Restic repo initialized on $name"
}

do_backup() {
    local name="$1"
    read -r dev mapper mnt <<< "$(get_target "$name")"

    do_unlock "$name"

    # For offsite: auto-lock on exit (success or failure)
    if [[ "$name" == "offsite" ]]; then
        trap 'do_lock offsite' EXIT
    fi

    log "Starting backup to $name"

    local existing_paths=()
    for p in "${BACKUP_PATHS[@]}"; do
        if [[ -e "$p" ]]; then
            existing_paths+=("$p")
        else
            log "SKIP: $p does not exist"
        fi
    done

    restic -r "$mnt" --password-file "$RESTIC_PASSWORD_FILE" backup \
        "${existing_paths[@]}" \
        "${EXCLUDE_PATTERNS[@]}" \
        --tag "$name" \
        --verbose 2>&1 | tee -a "$LOGFILE"

    log "Backup to $name complete"

    # Docker volume dumps
    do_docker_backup "$name"

    # Retention policy differs per target
    local -a retention
    if [[ "$name" == "offsite" ]]; then
        retention=("${RETENTION_OFFSITE[@]}")
        log "Running retention policy on $name (keep 6 monthly)"
    else
        retention=("${RETENTION_LOCAL[@]}")
        log "Running retention policy on $name (keep 7 daily, 4 weekly, 6 monthly)"
    fi

    restic -r "$mnt" --password-file "$RESTIC_PASSWORD_FILE" forget \
        "${retention[@]}" \
        --prune 2>&1 | tee -a "$LOGFILE"

    log "Retention policy applied on $name"

    # For offsite: trap handles locking
}

do_docker_backup() {
    local name="$1"
    read -r dev mapper mnt <<< "$(get_target "$name")"

    local docker_backup_dir="$mnt/docker-volumes"
    mkdir -p "$docker_backup_dir"

    log "Dumping Docker volumes"

    local important_volumes=(
        "blog_storage"
        "forgejo_docker_certs"
        "kamal-proxy-config"
        "beacon_beacon-data"
    )

    for vol in "${important_volumes[@]}"; do
        if docker volume inspect "$vol" &>/dev/null; then
            log "Backing up volume: $vol"
            docker run --rm \
                -v "$vol":/source:ro \
                -v "$docker_backup_dir":/dest \
                alpine tar czf "/dest/${vol}.tar.gz" -C /source . 2>&1 | tee -a "$LOGFILE"
        fi
    done

    log "Docker volume dumps complete"
}

do_status() {
    for t in "${TARGETS[@]}"; do
        IFS=: read -r tname dev mapper mnt <<< "$t"
        echo "=== $tname ($dev) ==="
        if sudo blkid "$dev" &>/dev/null; then
            echo "  Drive: connected"
        else
            echo "  Drive: NOT connected"
            echo ""
            continue
        fi
        if is_open "$mapper"; then
            echo "  LUKS: open"
        else
            echo "  LUKS: closed"
            echo ""
            continue
        fi
        if is_mounted "$mnt"; then
            echo "  Mount: $mnt"
            local used avail pct
            read -r used avail pct <<< "$(df -h "$mnt" | awk 'NR==2{print $3, $4, $5}')"
            echo "  Space: ${used} used, ${avail} available (${pct})"
            if [[ -f "$mnt/config" ]]; then
                echo "  Restic repo: initialized"
                local snap_count
                snap_count=$(restic -r "$mnt" --password-file "$RESTIC_PASSWORD_FILE" snapshots --compact --no-lock 2>/dev/null | grep -c "^[0-9a-f]" || echo "0")
                echo "  Snapshots: $snap_count"
                local latest
                latest=$(restic -r "$mnt" --password-file "$RESTIC_PASSWORD_FILE" snapshots --latest 1 --compact --no-lock 2>/dev/null | grep "^[0-9a-f]" | awk '{print $2, $3}' || echo "none")
                echo "  Latest: $latest"
            else
                echo "  Restic: not initialized"
            fi
        else
            echo "  Mount: not mounted"
        fi
        echo ""
    done
}

do_snapshots() {
    local name="${1:-local}"
    read -r dev mapper mnt <<< "$(get_target "$name")"
    local was_mounted
    was_mounted=$(is_mounted "$mnt" && echo yes || echo no)
    do_unlock "$name"
    restic -r "$mnt" --password-file "$RESTIC_PASSWORD_FILE" snapshots
    if [[ "$name" != "local" && "$was_mounted" == "no" ]]; then
        do_lock "$name"
    fi
}

do_verify() {
    local name="$1"
    read -r dev mapper mnt <<< "$(get_target "$name")"
    local was_mounted
    was_mounted=$(is_mounted "$mnt" && echo yes || echo no)
    do_unlock "$name"
    log "Verifying $name repo integrity"
    restic -r "$mnt" --password-file "$RESTIC_PASSWORD_FILE" check 2>&1 | tee -a "$LOGFILE"
    log "Verification of $name complete"
    if [[ "$name" != "local" && "$was_mounted" == "no" ]]; then
        do_lock "$name"
    fi
}

cmd="${1:-}"
target="${2:-local}"

case "$cmd" in
    run)     do_backup "$target" ;;
    status)  do_status ;;
    snapshots) do_snapshots "$target" ;;
    unlock)  do_unlock "$target" ;;
    lock)    do_lock "$target" ;;
    init)    do_init "$target" ;;
    verify)  do_verify "$target" ;;
    *)       usage ;;
esac
