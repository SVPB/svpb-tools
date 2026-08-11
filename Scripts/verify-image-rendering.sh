#!/usr/bin/env bash
#
# Verifies that a built TNG image can actually rasterise a score.
#
# `swift test` proves the Swift code is correct on a Linux host that happens to
# be configured properly. It says nothing about the image we ship, which is built
# by a Dockerfile no unit test executes.
#
# What can go wrong there has changed. CeolKit renders glyphs as geometry
# (TextRendering.outlines): every notehead, clef, rest, and letter is a <path> in
# <defs> drawn by a <use>, and the document carries no @font-face block and no
# <text> element. Nothing resolves a font family at conversion time, so the host
# font database — the old failure mode, which produced a valid PDF of staff lines
# and stems with no music on them — is out of the picture entirely.
#
# Two things can still break, and both are silent:
#
#   1. The image's rsvg-convert does not put referenced geometry on the page.
#      Checked by converting a probe twice, once with its <use> elements and once
#      without: a rasteriser that drew the glyphs produces the larger PDF.
#   2. CeolKit's resource bundle did not ship its faces. The renderer reads the
#      OTFs to extract outlines, so a missing face fails every conversion — at
#      runtime, on the first webhook, not at build time.
#
# The conversion runs inside the image, through the same /usr/bin/rsvg-convert
# that SVGPDFKit shells out to at runtime. Only the assertions run outside, where
# the full toolchain is available (the runtime image is slim and has no
# `strings`).
#
# Usage: Scripts/verify-image-rendering.sh [image-tag]

set -euo pipefail

IMAGE="${1:-ghcr.io/svpb/svpb-tools:dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/Tests/Fixtures"
FIXTURE="outline-rendering-probe.svg"
# The probe's three glyph outlines add roughly 2 KB of compressed path data to
# the PDF. Anything close to that margin means they were not drawn; the bar is
# set well below it so that cairo version differences cannot trip it.
MIN_GLYPH_BYTES=500
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$FIXTURE_DIR/$FIXTURE" ]; then
    echo "ERROR: fixture not found: $FIXTURE_DIR/$FIXTURE" >&2
    exit 1
fi
cp "$FIXTURE_DIR/$FIXTURE" "$WORK/probe.svg"

# The same document with nothing drawn: the baseline a rasteriser that ignored
# every <use> would produce.
grep -v '<use ' "$WORK/probe.svg" > "$WORK/control.svg"

echo "==> Verifying score rendering inside $IMAGE"

# 1. The faces the renderer extracts outlines from must have shipped. Checked
#    first because it localises the failure: this is a packaging problem, while
#    anything below is a rasteriser problem.
for face in Bravura LibertinusSerif-Regular LibertinusSerif-Italic; do
    # The face travels as an environment variable so the probe stays a single
    # fixed-quoting string that the outer shell does not have to interpolate into.
    if ! docker run --rm --entrypoint sh -e "FACE=$face" "$IMAGE" -c \
        'RES=$(find . -maxdepth 1 -name "CeolKit_CeolKitSVGRenderer.*" -print -quit); [ -s "$RES/$FACE.otf" ]'; then
        echo "ERROR: $face.otf is missing from the CeolKit resource bundle." >&2
        echo "       The renderer cannot extract glyph outlines and every" >&2
        echo "       conversion this image attempts will fail." >&2
        exit 1
    fi
    echo "    resource bundle carries $face.otf"
done

# 2. Convert both documents inside the image, exactly as SVGPDFKit does at runtime.
for doc in probe control; do
    docker run --rm \
        --entrypoint rsvg-convert \
        -v "$WORK:/probe" \
        "$IMAGE" \
        --format=pdf -o "/probe/$doc.pdf" "/probe/$doc.svg"

    if [ ! -s "$WORK/$doc.pdf" ]; then
        echo "ERROR: converting $doc.svg produced no output." >&2
        exit 1
    fi
done

fail=0

# 3. The glyphs must have reached the page. Both PDFs draw the same (empty)
#    background, so the difference is the referenced geometry and nothing else.
# The arithmetic expansion also strips the padding `wc` writes on some platforms.
probe_bytes=$(( $(wc -c < "$WORK/probe.pdf") ))
control_bytes=$(( $(wc -c < "$WORK/control.pdf") ))
delta=$(( probe_bytes - control_bytes ))
echo "    PDF with glyphs: $probe_bytes bytes; without: $control_bytes (+$delta)"

if [ "$delta" -lt "$MIN_GLYPH_BYTES" ]; then
    echo "ERROR: drawing three glyph outlines added only $delta bytes to the PDF." >&2
    echo "       This image's rsvg-convert is not resolving <use href>, so every" >&2
    echo "       score it renders has staff lines and stems but no notes." >&2
    fail=1
fi

# 4. Nothing may resolve through a host font. A font dictionary here means some
#    run reached the page as text rather than geometry — the output would then be
#    correct only on a host whose font database happens to match.
fonts="$(grep -ao '/BaseFont */[A-Za-z0-9+-]*' "$WORK/probe.pdf" \
         | sed 's|.*/||; s/^[A-Z]\{6\}+//' \
         | sort -u || true)"

if [ -n "$fonts" ]; then
    echo "ERROR: the PDF embeds fonts: $(echo "$fonts" | tr '\n' ' ')" >&2
    echo "       Glyphs reached the page as text rather than geometry." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "==> FAILED: $IMAGE cannot render scores correctly." >&2
    exit 1
fi

echo "==> OK: $IMAGE draws glyph outlines and depends on no host font."
