# ── Stage 1: Build ────────────────────────────────────────────────────────────
# Swift 6.3 or newer is required: CeolKit's manifest declares
# `swift-tools-version: 6.3`, which older toolchains refuse to parse.
FROM swift:6.3-noble AS build

WORKDIR /build

# Resolve dependencies before copying source so that this layer is cached
# as long as Package.swift and Package.resolved don't change.
COPY Package.swift Package.resolved* ./
RUN swift package resolve

# Copy source and build in release mode.
COPY Sources ./Sources
COPY Tests ./Tests
COPY Resources ./Resources
COPY Public ./Public
RUN swift build -c release --product TNG 2>&1

# Collect the executable and every SwiftPM resource bundle into one staging
# directory. `Bundle.module` resolves resources relative to the executable, so
# these must travel together — CeolKit's SVG renderer loads the Bravura and
# Libertinus Serif fonts this way and throws on every conversion without them.
RUN set -eu; \
    mkdir -p /staging; \
    BIN="$(swift build -c release --show-bin-path)"; \
    cp "$BIN/TNG" /staging/; \
    find -L "$BIN/" -regex '.*\.\(resources\|bundle\)$' -exec cp -Ra {} /staging/ \; ; \
    if [ ! -d /staging/CeolKit_CeolKitSVGRenderer.resources ] \
    && [ ! -d /staging/CeolKit_CeolKitSVGRenderer.bundle ]; then \
      echo "ERROR: CeolKit resource bundle not found in $BIN." >&2; \
      echo "The SVG renderer's fonts would fail to load on every conversion." >&2; \
      exit 1; \
    fi

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM swift:6.3-noble-slim AS runtime

# Runtime dependencies:
#   - libssl / libcurl: for AsyncHTTPClient / Vapor
#   - git: for cloning and pulling svpb-music on webhook events
#   - ca-certificates: for TLS verification against Box and Slack APIs
#   - librsvg2-bin: for converting SVG to PDF when we don't have CoreGraphics
#   - curl: for the compose healthcheck against /health
#
# No font packages: CeolKit writes glyph geometry into every SVG, so
# rsvg-convert never resolves a face through the host font database.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libssl3 \
      libcurl4 \
      libxml2 \
      librsvg2-bin \
      ca-certificates \
      curl \
      git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The executable plus its SwiftPM resource bundles, staged together above.
COPY --from=build /staging/ ./
COPY --from=build /build/Resources ./Resources
COPY --from=build /build/Public ./Public

# Verify the faces the renderer reads outlines from actually shipped.
#
# The faces are never installed system-wide: CeolKit writes glyph geometry into
# each SVG rather than emitting <text>, so rsvg-convert has no font-family to
# resolve and the host font database is irrelevant. What CeolKit does need is to
# read the OTFs out of its own resource bundle at render time — a missing or
# truncated face there fails every conversion.
RUN set -eu; \
    RES="$(find . -maxdepth 1 -name 'CeolKit_CeolKitSVGRenderer.*' -print -quit)"; \
    for face in Bravura LibertinusSerif-Regular LibertinusSerif-Italic; do \
      if [ ! -s "$RES/$face.otf" ]; then \
        echo "ERROR: $face.otf is missing from the CeolKit resource bundle." >&2; \
        echo "The renderer could not extract glyph outlines and every" >&2; \
        echo "conversion would fail." >&2; \
        exit 1; \
      fi; \
    done

# The database and built PDFs live on the named volume, not in the image.
RUN mkdir -p data

EXPOSE 8080

ENTRYPOINT ["./TNG"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
