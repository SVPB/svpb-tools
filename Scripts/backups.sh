#!/usr/bin/env bash
#
# Lists, verifies, and restores the off-site database backups (#4).
#
# Run on the server, from anywhere inside the checkout:
#
#   Scripts/backups.sh list               every stored backup, oldest first
#   Scripts/backups.sh check [KEY]        download a backup (default: the newest) and prove
#                                         it restores, without touching the live server
#   Scripts/backups.sh restore [KEY]      check it, then replace the live database with it
#   Scripts/backups.sh expire DAYS        set the bucket to delete backups older than DAYS
#
# TNG takes the backups itself, nightly (Sources/App/Services/DatabaseBackup.swift), and
# reads where to put them from the BACKUP_* variables in .env. This script reads the same
# ones; a variable set in the environment wins over .env, so `expire` can be run once with
# a key that may change the bucket's settings without that key ever living on the server.
#
# `check` is what makes a backup a backup. It runs SQLite's integrity check on the copy,
# counts the rows in every table, and then boots the very image the server runs against a
# scratch copy of it and reads /health — the same proof the README asks for after a
# migration. The scratch server has no network and dummy credentials: the database holds
# the live Box refresh token, and a second server renewing it would retire the one
# production is using.
#
# `restore` keeps the database it replaces, under $TNG_STATE_DIR/data/pre-restore-<time>/.
# Afterwards Box may need re-authorising from the Connections page: Box rotates its
# refresh token on every renewal, and the backup holds whichever token was current when it
# was taken.
#
# Requires: docker compose, curl 7.75 or later (for --aws-sigv4), openssl.

set -euo pipefail

SERVICE="tng"
CHECK_CONTAINER="tng-restore-check"
SQLITE_IMAGE="alpine:3.20"
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

# ── Configuration ────────────────────────────────────────────────────────────

# The value of NAME from the environment, else from .env, with surrounding quotes removed.
setting() {
    local name=$1
    if [[ -n "${!name:-}" ]]; then
        printf '%s' "${!name}"
    elif [[ -f .env ]]; then
        { grep -E "^${name}=" .env || true; } | tail -n1 | cut -d= -f2- \
            | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
    fi
}

load_store() {
    ENDPOINT=$(setting BACKUP_ENDPOINT); ENDPOINT=${ENDPOINT%/}
    BUCKET=$(setting BACKUP_BUCKET)
    ACCESS_KEY=$(setting BACKUP_ACCESS_KEY)
    SECRET_KEY=$(setting BACKUP_SECRET_KEY)
    PREFIX=$(setting BACKUP_PREFIX); PREFIX=${PREFIX:-tng/}
    PREFIX=${PREFIX#/}; [[ "$PREFIX" == */ ]] || PREFIX="$PREFIX/"
    for name in ENDPOINT BUCKET ACCESS_KEY SECRET_KEY; do
        [[ -n "${!name}" ]] || fail "BACKUP_$name is not set in .env or the environment"
    done

    # The same rule as DatabaseBackup.Configuration.defaultRegion.
    REGION=$(setting BACKUP_REGION)
    if [[ -z "$REGION" ]]; then
        local host=${ENDPOINT#*://}; host=${host%%[:/]*}
        if [[ "$host" == *.digitaloceanspaces.com ]]; then REGION=${host%%.*}; else REGION=us-east-1; fi
    fi
}

# curl, signed for the store. Arguments after the path go to curl.
store() {
    local path=$1; shift
    curl -fsS --aws-sigv4 "aws:amz:$REGION:s3" --user "$ACCESS_KEY:$SECRET_KEY" \
        "$@" "$ENDPOINT/$BUCKET$path"
}

# Every backup key under the prefix, oldest first. Keys carry a UTC timestamp, so text
# order is time order.
keys() {
    store "?list-type=2&prefix=$PREFIX" \
        | { grep -o '<Key>[^<]*</Key>' || true; } | sed -e 's/<Key>//' -e 's#</Key>##' | sort
}

state_dir() {
    local dir; dir=$(setting TNG_STATE_DIR)
    printf '%s' "${dir:-./state}"
}

image() {
    { docker compose config --images || true; } | { grep "svpb-tools" || true; } | head -n1
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_list() {
    load_store
    keys
}

# Downloads KEY (default: the newest) into $WORK/tng.sqlite and proves it restores.
cmd_check() {
    load_store
    local key=${1:-}
    if [[ -z "$key" ]]; then
        key=$(keys | tail -n1)
        [[ -n "$key" ]] || fail "no backups under $BUCKET/$PREFIX"
    fi

    WORK=$(mktemp -d)
    trap 'docker rm -f "$CHECK_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

    log "Downloading $key"
    store "/$key" -o "$WORK/tng.sqlite"
    printf '    %s bytes\n' "$(wc -c <"$WORK/tng.sqlite" | tr -d ' ')"

    log "Checking integrity and counting rows"
    docker run --rm -v "$WORK:/backup:ro" "$SQLITE_IMAGE" sh -euc '
        apk add --quiet --no-progress sqlite >/dev/null
        db="sqlite3 -readonly /backup/tng.sqlite"
        result=$($db "PRAGMA integrity_check;")
        echo "    integrity_check: $result"
        [ "$result" = ok ] || exit 1
        for table in $($db "SELECT name FROM sqlite_master WHERE type = '\''table'\'' AND name NOT LIKE '\''sqlite_%'\'' ORDER BY name;"); do
            printf "    %-22s %s\n" "$table" "$($db "SELECT count(*) FROM \"$table\";")"
        done
    ' || fail "$key is not a sound SQLite database"

    # Booted against a copy, because starting the server writes to its database
    # (migrations, the keep-alive's outcome) and `restore` wants the download untouched.
    local image; image=$(image)
    [[ -n "$image" ]] || fail "could not resolve the $SERVICE image from docker compose config"
    log "Starting $image against a scratch copy, with no network"
    mkdir "$WORK/scratch"
    cp "$WORK/tng.sqlite" "$WORK/scratch/tng.sqlite"
    local dummy=() name
    for name in GITHUB_WEBHOOK_SECRET SVPB_MUSIC_REPO_URL BOX_CLIENT_ID BOX_CLIENT_SECRET \
                BOX_FOLDER_ID SLACK_BOT_TOKEN SLACK_SIGNING_SECRET SLACK_WEBHOOK_URL \
                INITIAL_ADMIN_SLACK_USER_ID; do
        dummy+=(-e "$name=restore-check")
    done
    docker run -d --name "$CHECK_CONTAINER" --network none \
        -v "$WORK/scratch:/app/data" -e DATABASE_PATH=/app/data/tng.sqlite \
        "${dummy[@]}" "$image" >/dev/null

    local deadline=$(( SECONDS + HEALTH_TIMEOUT )) health
    until health=$(docker exec "$CHECK_CONTAINER" curl -fsS http://localhost:8080/health 2>/dev/null); do
        if ! docker inspect -f '{{.State.Running}}' "$CHECK_CONTAINER" 2>/dev/null | grep -q true \
           || (( SECONDS >= deadline )); then
            docker logs --tail 50 "$CHECK_CONTAINER" >&2
            fail "the server did not start against $key"
        fi
        sleep 2
    done
    printf '    %s\n' "$health"
    docker rm -f "$CHECK_CONTAINER" >/dev/null

    CHECKED_KEY=$key
    log "$key restores"
}

cmd_restore() {
    local yes=0 key=""
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) yes=1 ;;
            *) key=$arg ;;
        esac
    done

    cmd_check "$key"

    local data; data="$(state_dir)/data"
    [[ -d "$data" ]] || fail "$data does not exist — is TNG_STATE_DIR right?"
    if (( ! yes )); then
        printf 'Replace %s/tng.sqlite with %s? [y/N] ' "$data" "$CHECKED_KEY"
        read -r answer
        [[ "$answer" == [yY]* ]] || fail "not restored"
    fi

    log "Stopping $SERVICE"
    docker compose stop "$SERVICE"

    local aside; aside="$data/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
    log "Keeping the current database in $aside"
    mkdir "$aside"
    for file in "$data"/tng.sqlite "$data"/tng.sqlite-wal "$data"/tng.sqlite-shm "$data"/tng.sqlite-journal; do
        [[ -e "$file" ]] && mv "$file" "$aside/"
    done
    cp "$WORK/tng.sqlite" "$data/tng.sqlite"

    # `start`, not `up`: a restore should not also change which image is running.
    log "Starting $SERVICE"
    docker compose start "$SERVICE"
    local deadline=$(( SECONDS + HEALTH_TIMEOUT )) container health
    while :; do
        container=$(docker compose ps -q "$SERVICE")
        health=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)
        [[ "$health" == healthy ]] && break
        if [[ "$health" == unhealthy ]] || (( SECONDS >= deadline )); then
            docker compose logs --tail 50 "$SERVICE" >&2
            fail "$SERVICE is $health after the restore; the previous database is in $aside"
        fi
        sleep 5
    done
    docker compose exec -T "$SERVICE" curl -fsS http://localhost:8080/health && echo

    log "Restored $CHECKED_KEY"
    cat <<EOF

Box rotates its refresh token on every renewal, and this backup holds the one that was
current when it was taken. If the Connections page shows Box failing, re-authorise it there.
EOF
}

cmd_expire() {
    local days=${1:-}
    [[ "$days" =~ ^[1-9][0-9]*$ ]] || fail "usage: $0 expire DAYS"
    load_store

    local body
    body="<LifecycleConfiguration><Rule><ID>expire-tng-backups</ID><Prefix>$PREFIX</Prefix><Status>Enabled</Status><Expiration><Days>$days</Days></Expiration></Rule></LifecycleConfiguration>"
    log "Expiring $BUCKET/$PREFIX* after $days day(s)"
    store "?lifecycle" -X PUT -H "Content-Type: application/xml" \
        -H "Content-MD5: $(printf '%s' "$body" | openssl dgst -md5 -binary | base64)" \
        --data-binary "$body" >/dev/null
    store "?lifecycle" && echo
}

case "${1:-}" in
    list)    shift; cmd_list "$@" ;;
    check)   shift; cmd_check "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    expire)  shift; cmd_expire "$@" ;;
    -h|--help) usage 0 ;;
    *) usage 2 >&2 ;;
esac
