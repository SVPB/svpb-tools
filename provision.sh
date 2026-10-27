#!/usr/bin/env bash
#
# Turns a fresh Ubuntu 24.04 droplet into a TNG server.
#
# Pass it as user data when creating the droplet, and cloud-init runs it as root
# on first boot (output in /var/log/cloud-init-output.log):
#
#   doctl compute droplet create … --volumes <volume-id> --user-data-file provision.sh
#
# or re-run it by hand at any time, as root, from the checkout it makes:
#
#   /root/svpb-tools/provision.sh
#
# See README § Digital Ocean Droplet for the steps around it. In order, it:
#
#   1. installs git, curl, and Docker from Docker's own apt repository;
#   2. adds a 2 GB swapfile, because rendering a full year of music can spike
#      past the droplet's 2 GB of RAM;
#   3. clones svpb-tools into /root/svpb-tools;
#   4. mounts the Block Storage volume through /etc/fstab, by its stable by-id
#      path, and proves the entry by mounting through it;
#   5. symlinks the volume's .env into the checkout, checks that TNG_STATE_DIR in
#      it points Compose's state binds at the volume, and starts the stack.
#
# Every step checks before it acts, so a re-run changes nothing that is already
# right. It never formats the volume — on a rebuild the volume holds the
# database — and never pulls an existing checkout: updating is Scripts/deploy.sh.
#
# It holds no secrets, and must not: user data stays readable from the metadata
# service at 169.254.169.254 for the life of the droplet, to anything running on
# it. The credentials are in the .env on the volume. With no .env there yet, the
# first time, it stops before step 5 and says what to do.

set -euo pipefail

VOLUME_NAME=${TNG_VOLUME_NAME:-tng-state}
REPO_URL=${TNG_REPO_URL:-https://github.com/SVPB/svpb-tools.git}
CHECKOUT=${TNG_CHECKOUT:-/root/svpb-tools}
SWAP_SIZE=${TNG_SWAP_SIZE:-2G}

DEVICE=/dev/disk/by-id/scsi-0DO_Volume_$VOLUME_NAME
# Where Digital Ocean mounts a volume itself: /mnt/<name>, hyphens as underscores.
MOUNTPOINT=/mnt/${VOLUME_NAME//-/_}
ENV_FILE=$MOUNTPOINT/.env

DEVICE_TIMEOUT=${DEVICE_TIMEOUT:-120}  # a volume attached at creation can appear after boot
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-300}  # first start also pulls both images

# cloud-init runs this with next to no environment.
export HOME=${HOME:-/root}
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root"

# On first boot unattended-upgrades holds the dpkg lock for a minute or two.
apt_get() { apt-get -o DPkg::Lock::Timeout=600 "$@"; }

# Only what is missing: reinstalling on a live server would upgrade Docker, and
# that restarts the stack.
apt_install() {
    local missing=() package
    for package in "$@"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' \
            || missing+=("$package")
    done
    (( ${#missing[@]} )) || return 0
    apt_get update
    apt_get install -y "${missing[@]}"
}

# ── 1. Packages ──────────────────────────────────────────────────────────────

log "Installing packages"
apt_install ca-certificates curl git

if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
fi
# Written whole, not appended, so a re-run leaves one line.
# shellcheck disable=SC1091
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc]" \
    "https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ── 2. Swap ──────────────────────────────────────────────────────────────────

log "Adding swap"
if [[ ! -f /swapfile ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
fi
swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile
awk '$1 == "/swapfile" { found = 1 } END { exit !found }' /etc/fstab \
    || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ── 3. Checkout ──────────────────────────────────────────────────────────────

log "Cloning $REPO_URL"
if [[ -d $CHECKOUT/.git ]]; then
    echo "    $CHECKOUT exists; leaving it as it is"
elif [[ -e $CHECKOUT ]]; then
    fail "$CHECKOUT exists and is not a git checkout"
else
    git clone "$REPO_URL" "$CHECKOUT"
fi

# ── 4. Volume ────────────────────────────────────────────────────────────────

log "Mounting volume $VOLUME_NAME at $MOUNTPOINT"
deadline=$(( SECONDS + DEVICE_TIMEOUT ))
until [[ -e $DEVICE ]]; do
    (( SECONDS < deadline )) || fail "no $DEVICE after ${DEVICE_TIMEOUT}s — attach the $VOLUME_NAME volume to this droplet, then re-run $CHECKOUT/provision.sh"
    udevadm settle --timeout=5 || sleep 5
done
DISK=$(realpath "$DEVICE")

# blkid exits non-zero when it finds no filesystem.
FSTYPE=$(blkid -o value -s TYPE "$DEVICE" || true)
[[ -n $FSTYPE ]] || fail "$DEVICE has no filesystem. If this volume is new and empty, format it with
    mkfs.ext4 -F $DEVICE
and re-run. Never do that to a volume that has been in use: it erases the database."

# One fstab entry, for this device at this mountpoint. Digital Ocean may have
# written its own when it attached the volume; that one counts.
fstab_device=$(awk -v mp="$MOUNTPOINT" '$2 == mp { print $1 }' /etc/fstab)
proved=0
if [[ -z $fstab_device ]]; then
    echo "$DEVICE $MOUNTPOINT $FSTYPE defaults,nofail,discard 0 2" >> /etc/fstab
    systemctl daemon-reload
elif [[ $(realpath "$fstab_device" 2>/dev/null) != "$DISK" ]]; then
    fail "/etc/fstab already mounts $fstab_device at $MOUNTPOINT, not $DEVICE"
else
    proved=1
fi

mkdir -p "$MOUNTPOINT"
mounted=$(findmnt -n -o SOURCE --mountpoint "$MOUNTPOINT" || true)
if [[ -n $mounted && $(realpath "$mounted") != "$DISK" ]]; then
    fail "$MOUNTPOINT is mounted from $mounted, not $DEVICE"
fi
# A new entry is proved by mounting through it. Digital Ocean's ad-hoc mount at
# attach time would otherwise hide a broken one until the next reboot, when
# nofail would swallow the error and the stack would write to the boot disk.
if [[ -n $mounted ]] && (( ! proved )); then
    umount "$MOUNTPOINT"
    mounted=
fi
[[ -n $mounted ]] || mount "$MOUNTPOINT"
[[ $(realpath "$(findmnt -n -o SOURCE --mountpoint "$MOUNTPOINT")") == "$DISK" ]] \
    || fail "$MOUNTPOINT did not mount from $DEVICE"
findmnt --mountpoint "$MOUNTPOINT"

mkdir -p "$MOUNTPOINT/data" "$MOUNTPOINT/caddy/data" "$MOUNTPOINT/caddy/config"

# ── 5. Configuration and start ───────────────────────────────────────────────

cd "$CHECKOUT"

log "Linking $ENV_FILE into the checkout"
if [[ -L .env ]]; then
    [[ $(readlink .env) == "$ENV_FILE" ]] || fail "$CHECKOUT/.env links to $(readlink .env), not $ENV_FILE"
elif [[ -e .env ]]; then
    fail "$CHECKOUT/.env is a file, not a link to $ENV_FILE — move it onto the volume first"
else
    ln -s "$ENV_FILE" .env
fi

if [[ ! -f $ENV_FILE ]]; then
    log "No $ENV_FILE yet — the machine is ready, but there is nothing to start"
    cat <<EOF
    This is the first time. Create the configuration on the volume, where it
    survives the droplet:

        cp $CHECKOUT/.env.example $ENV_FILE
        chmod 600 $ENV_FILE
        \$EDITOR $ENV_FILE     # every value, and TNG_STATE_DIR=$MOUNTPOINT

    then re-run $CHECKOUT/provision.sh.
EOF
    exit 0
fi

# Compose reads TNG_STATE_DIR through the symlink. If it does not resolve to
# the volume, starting now would create an empty database on the boot disk.
log "Checking the state binds"
binds=$(docker compose config --format json | python3 -c '
import json, sys
for name, service in json.load(sys.stdin)["services"].items():
    for v in service.get("volumes", []):
        if v["type"] == "bind" and v["target"] in ("/app/data", "/data", "/config"):
            print(v["source"])
')
while read -r source; do
    echo "    $source"
    [[ $source == "$MOUNTPOINT"/* ]] \
        || fail "state bind $source is not on the volume — set TNG_STATE_DIR=$MOUNTPOINT in $ENV_FILE"
done <<<"$binds"

log "Starting the stack"
docker compose up -d

log "Waiting for tng to report healthy"
deadline=$(( SECONDS + HEALTH_TIMEOUT ))
while :; do
    container=$(docker compose ps -q tng)
    health=$([[ -n "$container" ]] && docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)
    case "$health" in
        healthy)   break ;;
        unhealthy) docker compose logs --tail 50 tng >&2
                   fail "tng is unhealthy" ;;
    esac
    if (( SECONDS >= deadline )); then
        docker compose logs --tail 50 tng >&2
        fail "tng not healthy after ${HEALTH_TIMEOUT}s (status: $health)"
    fi
    sleep 5
done
docker compose exec -T tng curl -fsS http://localhost:8080/health && echo

log "Provisioned. From outside, check: curl https://\$DOMAIN/health"
