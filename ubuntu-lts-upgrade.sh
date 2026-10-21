#!/usr/bin/env bash
#
# ubuntu-lts-upgrade.sh
# Upgrades Ubuntu 20.04 -> 22.04 -> 24.04 unattended, resuming after each reboot.
#
# Usage (run once, as root):
#   sudo bash ubuntu-lts-upgrade.sh
#
# On first run it installs a systemd service that re-runs this script at boot.
# When the system reaches 24.04 the service removes itself.
#
# Log file: /var/log/ubuntu-lts-upgrade.log

set -u

INSTALL_PATH=/usr/local/sbin/ubuntu-lts-upgrade.sh
SERVICE_NAME=ubuntu-lts-upgrade.service
SERVICE_PATH=/etc/systemd/system/$SERVICE_NAME
STATE_DIR=/var/lib/ubuntu-lts-upgrade
LOG=/var/log/ubuntu-lts-upgrade.log
MAX_ATTEMPTS=2          # tries per release before giving up (prevents reboot loops)

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo bash $0"
    exit 1
fi

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1

# Only one instance at a time
exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then
    echo "Another instance is already running. Exiting."
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APT_OPTS=(-y -o DPkg::Lock::Timeout=900
          -o Dpkg::Options::=--force-confdef
          -o Dpkg::Options::=--force-confold)

log() { echo "[$(date '+%F %T')] $*"; }

install_service() {
    if [ "$(readlink -f "$0")" != "$INSTALL_PATH" ]; then
        cp -f "$(readlink -f "$0")" "$INSTALL_PATH"
        chmod 755 "$INSTALL_PATH"
    fi
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Resume Ubuntu LTS release upgrade
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
TimeoutStartSec=infinity
KillMode=process
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

remove_service() {
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload || true
}

do_reboot() {
    log "Rebooting in 10 seconds..."
    sync
    sleep 10
    systemctl reboot
    sleep 60
    exit 0
}

get_version() {
    . /etc/os-release
    echo "${VERSION_ID:-unknown}"
}

VER="$(get_version)"
log "=== Started. Current Ubuntu version: $VER ==="

case "$VER" in
    24.04)
        log "Final package update on 24.04..."
        apt-get update
        apt-get "${APT_OPTS[@]}" dist-upgrade
        apt-get "${APT_OPTS[@]}" autoremove
        remove_service
        rm -rf "$STATE_DIR/attempts-"* "$STATE_DIR/prepped-"*
        log "=== Done: system is on Ubuntu 24.04. Service removed. ==="
        if [ -f /var/run/reboot-required ]; then
            log "A final reboot is recommended and will happen now."
            do_reboot
        fi
        exit 0
        ;;
    20.04|22.04)
        ;;
    *)
        log "Unsupported starting version '$VER' (expected 20.04 or 22.04). Aborting."
        remove_service
        exit 1
        ;;
esac

# Make sure the script resumes after reboot
install_service

# Give up if we've already tried too many times on this release
ATTEMPTS_FILE="$STATE_DIR/attempts-$VER"
ATTEMPTS=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    log "Already attempted the $VER upgrade $ATTEMPTS times. Stopping to avoid a reboot loop."
    log "Check the log, fix the problem, then run: sudo rm -rf $STATE_DIR && sudo bash $INSTALL_PATH"
    remove_service
    exit 1
fi

# Step 1: bring the current release fully up to date
log "Updating packages on $VER..."
sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades 2>/dev/null || true
apt-get update || { log "apt-get update failed. Check network/repositories."; exit 1; }
apt-get "${APT_OPTS[@]}" dist-upgrade || { log "dist-upgrade failed."; exit 1; }
apt-get "${APT_OPTS[@]}" install update-manager-core || { log "Could not install update-manager-core."; exit 1; }
apt-get "${APT_OPTS[@]}" autoremove

# Step 2: reboot once if the updates need it (e.g. new kernel), then resume
if [ -f /var/run/reboot-required ] && [ ! -f "$STATE_DIR/prepped-$VER" ]; then
    touch "$STATE_DIR/prepped-$VER"
    log "Pre-upgrade updates require a reboot. Rebooting, then continuing."
    do_reboot
fi

# Step 3: the release upgrade itself
echo $((ATTEMPTS + 1)) > "$ATTEMPTS_FILE"
log "Starting do-release-upgrade from $VER (this can take a long time)..."
do-release-upgrade -f DistUpgradeViewNonInteractive
RC=$?

if [ "$RC" -ne 0 ]; then
    log "do-release-upgrade exited with code $RC. NOT rebooting."
    log "Review $LOG and /var/log/dist-upgrade/ for details."
    log "To retry after fixing: sudo bash $INSTALL_PATH"
    remove_service
    exit "$RC"
fi

rm -f "$STATE_DIR/prepped-$VER"
log "Release upgrade from $VER finished. Rebooting into the new release."
do_reboot
