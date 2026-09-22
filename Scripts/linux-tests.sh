#!/usr/bin/env bash
#
# Runs the test suite on Linux, in a container, the way CI does.
#
# The suite passing on a Mac says less than it looks. SVGPDFKit rasterises
# through CoreGraphics on Apple platforms and through rsvg-convert everywhere
# else, and the two have produced different PDFs from byte-identical input —
# sbeitzel/SVGPDFKit#4 put every page against the top-left corner of its media
# box on Linux only, which is how the 2027 binder's margins went wrong in a way
# no local build could show (#62). Anything about a converted PDF wants checking
# here as well as in Xcode.
#
# Usage:
#
#     Scripts/linux-tests.sh                              # the whole suite
#     Scripts/linux-tests.sh --filter EngravedPageSize     # args reach swift test
#
# The build tree lives in a named Docker volume rather than in `.build`, so runs
# are incremental without colliding with a macOS build: `.build`'s Linux module
# cache is stamped with the absolute path it was built at, and a container that
# mounts the repository anywhere else fails with `missing required module
# 'SwiftShims'`. Remove the volume to start clean:
#
#     docker volume rm tng_linux_build
#
# This script is both the host-side runner and the image's entrypoint; the
# container half is below, and `test.dockerfile` is what sets the environment
# variable that tells them apart.
set -euo pipefail

IMAGE=tng-test:latest
VOLUME=tng_linux_build

if [ "${TNG_LINUX_TESTS_IN_CONTAINER:-0}" != "1" ]; then
    cd "$(dirname "$0")/.."
    docker build --tag "$IMAGE" --target test --file test.dockerfile .
    exec docker run --rm --tty \
        --volume "$PWD":/src \
        --volume "$VOLUME":/linuxbuild \
        "$IMAGE" "$@"
fi

# ── Inside the container ──────────────────────────────────────────────────────

SCRATCH="${TNG_LINUX_TESTS_SCRATCH:-/linuxbuild}"

# Resolving first puts the dependency checkouts where the shim source can be
# found, and keeps a failure to fetch separate from a failure to compile.
swift package resolve --scratch-path "$SCRATCH"

# Docker Desktop's VM kernel reports CLOCK_MONOTONIC's resolution as 1 ms, and
# swift-corelibs-foundation derives CoreFoundation's timebase from it, so every
# CFRunLoop deadline is computed in the past and `RunLoop.run(mode:before:)`
# never returns — which hangs XCTest's teardown part way through the suite, with
# the test process asleep in ppoll at no CPU and nothing wrong in the test.
# SVGPDFKit ships the workaround as an LD_PRELOAD shim reporting the 1 ns
# resolution the timebase calculation assumes; it changes no clock value.
# swift-corelibs-foundation#5485 fixes it upstream, in no released toolchain yet.
for source in "$SCRATCH"/checkouts/SVGPDFKit/Scripts/fineres.c \
              .build/checkouts/SVGPDFKit/Scripts/fineres.c; do
    if [ -f "$source" ]; then
        clang -shared -fPIC -o /tmp/fineres.so "$source"
        export LD_PRELOAD=/tmp/fineres.so
        break
    fi
done

if [ -z "${LD_PRELOAD:-}" ]; then
    echo "warning: no fineres.c in the SVGPDFKit checkout — if this run stops" >&2
    echo "         part way through and burns no CPU, that is why. See CLAUDE.md." >&2
fi

exec swift test --scratch-path "$SCRATCH" "$@"
