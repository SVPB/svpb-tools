#!/usr/bin/env bash
#
# Moves the running stack onto the latest published image.
#
# Run on the server, from anywhere inside the checkout:
#
#   Scripts/deploy.sh             wait for the image to finish publishing, then deploy
#   Scripts/deploy.sh --no-wait   deploy whatever the registry holds right now
#
# The raw sequence is `git pull && docker compose pull && docker compose up -d`.
# Each step below exists because that sequence fails silently in some way:
#
#   1. Build gate. Branch tags (develop, main, latest) are mutable. Pulling while
#      the publish workflow is still running fetches the *previous* image with no
#      error, so we wait for the workflow run for the commit the tag is about to
#      point at, and refuse to deploy if it failed.
#   2. Pull and recreate.
#   3. Health gate. `up -d` returns as soon as the container starts, not when it
#      is serving. We wait for Docker's own healthcheck (docker-compose.yml) to
#      report healthy, and exit non-zero if it does not.
#   4. Report what landed. A mutable tag says nothing about the commit, but the
#      publish workflow stamps it into the image's OCI labels.
#   5. Prune dangling images. Each pull strands the superseded build. Rollback is
#      always "pin TNG_IMAGE_TAG and re-pull", never the local cache, so keeping
#      them buys nothing. `prune -f` removes only untagged images, which leaves
#      caddy and any deliberately pinned release alone.
#
# Requires: git, docker compose, curl, python3 (present on stock Ubuntu). The
# repository is public, so the GitHub API needs no token; set GITHUB_TOKEN to
# lift the unauthenticated rate limit if polling ever hits it.

set -euo pipefail

REPO="SVPB/svpb-tools"
WORKFLOW="publish.yml"
SERVICE="tng"

GATE_TIMEOUT=${GATE_TIMEOUT:-1800}     # the publish job takes several minutes; allow for queueing
GATE_INTERVAL=${GATE_INTERVAL:-30}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}  # start_period 40s + a few 30s check intervals

WAIT=1
case "${1:-}" in
    "") ;;
    --no-wait) WAIT=0 ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--no-wait]" >&2; exit 2 ;;
esac

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

log()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

github_api() {
    local auth=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/$1"
}

# ── Which image, and which commit should it be? ──────────────────────────────

# Pull first, so compose changes (including a new default tag) are in effect
# before the image name is resolved.
log "Updating checkout"
git pull --ff-only

IMAGE=$(docker compose config --images | grep "svpb-tools" | head -n1)
[[ -n "$IMAGE" ]] || fail "could not resolve the $SERVICE image from docker compose config"
TAG=${IMAGE##*:}

# Map the image tag back to the git ref whose push publishes it
# (see the tag list at the top of .github/workflows/publish.yml).
case "$TAG" in
    latest)             REF=main;       REF_KIND=heads ;;
    [0-9]*.[0-9]*.[0-9]*) REF="v$TAG";  REF_KIND=tags ;;
    *)                  REF=$TAG;       REF_KIND=heads ;;
esac

# The commit the tag will point at once publishing finishes. An annotated git tag
# lists twice, and only the peeled `^{}` line names the commit; a branch or
# lightweight tag has just the plain line.
EXPECTED_SHA=$(git ls-remote origin "refs/$REF_KIND/$REF" "refs/$REF_KIND/$REF^{}" \
    | awk '/\^\{\}$/ { peeled = $1 } NR == 1 { plain = $1 } END { print peeled ? peeled : plain }')
[[ -n "$EXPECTED_SHA" ]] || fail "no ref $REF on origin for image tag '$TAG'"

log "Image $IMAGE, expecting commit ${EXPECTED_SHA:0:12} ($REF)"

# ── 1. Build gate ────────────────────────────────────────────────────────────

if (( WAIT )); then
    log "Waiting for the $WORKFLOW run for ${EXPECTED_SHA:0:12}"
    deadline=$(( SECONDS + GATE_TIMEOUT ))
    while :; do
        # Most recent run for this exact commit, as "status conclusion url".
        # No run yet is normal for a few seconds after a push.
        run=$(github_api "actions/workflows/$WORKFLOW/runs?head_sha=$EXPECTED_SHA&per_page=1" \
            | python3 -c '
import json, sys
runs = json.load(sys.stdin)["workflow_runs"]
if runs:
    r = runs[0]
    print(r["status"], r["conclusion"] or "-", r["html_url"])
') || fail "GitHub API request failed"

        read -r status conclusion url <<<"${run:-none - -}"
        if [[ "$status" == completed ]]; then
            [[ "$conclusion" == success ]] || fail "publish run concluded '$conclusion': $url"
            echo "    published: $url"
            break
        fi
        (( SECONDS < deadline )) || fail "timed out after ${GATE_TIMEOUT}s waiting for publish (last status: $status)"
        echo "    $status… (next check in ${GATE_INTERVAL}s)"
        sleep "$GATE_INTERVAL"
    done
else
    log "Skipping the build gate (--no-wait)"
fi

# ── 2. Pull and recreate ─────────────────────────────────────────────────────

log "Pulling images"
docker compose pull

log "Recreating containers"
docker compose up -d

# ── 3. Health gate ───────────────────────────────────────────────────────────

log "Waiting for $SERVICE to report healthy"
deadline=$(( SECONDS + HEALTH_TIMEOUT ))
while :; do
    container=$(docker compose ps -q "$SERVICE")
    health=$([[ -n "$container" ]] && docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)
    case "$health" in
        healthy)   break ;;
        unhealthy) docker compose logs --tail 50 "$SERVICE" >&2
                   fail "$SERVICE is unhealthy" ;;
    esac
    if (( SECONDS >= deadline )); then
        docker compose logs --tail 50 "$SERVICE" >&2
        fail "$SERVICE not healthy after ${HEALTH_TIMEOUT}s (status: $health)"
    fi
    sleep 5
done
docker compose exec -T "$SERVICE" curl -fsS http://localhost:8080/health && echo

# ── 4. Report what landed ────────────────────────────────────────────────────

REVISION=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$container")
log "Running revision ${REVISION:-unknown}"
if [[ "$REVISION" != "$EXPECTED_SHA" ]]; then
    # Only reachable with --no-wait, or if a newer push landed mid-deploy.
    fail "running ${REVISION:0:12}, but $REF is at ${EXPECTED_SHA:0:12} — re-run once its image is published"
fi

# ── 5. Prune ─────────────────────────────────────────────────────────────────

log "Pruning dangling images"
docker image prune -f

log "Deployed ${REVISION:0:12}"
