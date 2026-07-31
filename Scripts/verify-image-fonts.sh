#!/usr/bin/env bash
#
# Verifies that a built TNG image can actually rasterise a score.
#
# `swift test` proves the Swift code is correct on a Linux host that happens to
# be configured properly. It says nothing about the image we ship: the fonts are
# installed by the Dockerfile's runtime stage, which no unit test executes. A
# regression there produces a container that starts, serves, converts, returns a
# perfectly valid PDF — and renders every score in a substitute font, with no
# noteheads, clefs, rests, or accidentals. That is the failure this catches.
#
# The conversion runs inside the image, through the same /usr/bin/rsvg-convert
# that SVGPDFKit shells out to at runtime. Only the assertions run outside, where
# the full toolchain is available (the runtime image is slim and has no
# `strings`).
#
# Usage: Scripts/verify-image-fonts.sh [image-tag]

set -euo pipefail

IMAGE="${1:-ghcr.io/svpb/svpb-tools:dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/Tests/Fixtures"
FIXTURE="font-resolution-probe.svg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$FIXTURE_DIR/$FIXTURE" ]; then
    echo "ERROR: fixture not found: $FIXTURE_DIR/$FIXTURE" >&2
    exit 1
fi
cp "$FIXTURE_DIR/$FIXTURE" "$WORK/"

echo "==> Verifying font resolution inside $IMAGE"

# 1. fontconfig must resolve both families to the bundled files. Checked first
#    because it localises the failure: if this passes but the conversion below
#    does not, the problem is in rsvg-convert, not in the font installation.
for family in Bravura "Libertinus Serif"; do
    match="$(docker run --rm --entrypoint fc-match "$IMAGE" "$family")"
    echo "    fc-match $family -> $match"
    case "$family" in
        Bravura)          expect="Bravura.otf" ;;
        "Libertinus Serif") expect="LibertinusSerif" ;;
    esac
    if [[ "$match" != *"$expect"* ]]; then
        echo "ERROR: '$family' resolves to '$match', not the bundled face." >&2
        echo "       Every score this image renders will use a substitute font." >&2
        exit 1
    fi
done

# 2. Convert inside the image, exactly as SVGPDFKit does at runtime.
docker run --rm \
    --entrypoint rsvg-convert \
    -v "$WORK:/probe" \
    "$IMAGE" \
    --format=pdf -o "/probe/out.pdf" "/probe/$FIXTURE"

if [ ! -s "$WORK/out.pdf" ]; then
    echo "ERROR: conversion produced no output." >&2
    exit 1
fi

# 3. Inspect which faces the PDF actually embeds. Subset tags look like
#    "ABCDEF+Bravura"; strip them. librsvg writes font dictionaries
#    uncompressed, so no stream has to be inflated.
fonts="$(grep -ao '/BaseFont */[A-Za-z0-9+-]*' "$WORK/out.pdf" \
         | sed 's|.*/||; s/^[A-Z]\{6\}+//' \
         | sort -u)"

echo "    embedded fonts: $(echo "$fonts" | tr '\n' ' ')"

if [ -z "$fonts" ]; then
    echo "ERROR: the PDF embeds no fonts at all." >&2
    exit 1
fi

fail=0
grep -qx 'Bravura' <<<"$fonts" || {
    echo "ERROR: Bravura is not embedded — noteheads, clefs, rests, and" >&2
    echo "       accidentals are missing from this image's output." >&2
    fail=1
}
grep -q '^LibertinusSerif' <<<"$fonts" || {
    echo "ERROR: Libertinus Serif is not embedded — titles and footers" >&2
    echo "       rasterised in some other face." >&2
    fail=1
}
substituted="$(grep -vx 'Bravura' <<<"$fonts" | grep -v '^LibertinusSerif' || true)"
if [ -n "$substituted" ]; then
    echo "ERROR: fontconfig substituted: $(echo "$substituted" | tr '\n' ' ')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "==> FAILED: $IMAGE cannot render scores correctly." >&2
    exit 1
fi

echo "==> OK: $IMAGE resolves and embeds both bundled faces."
