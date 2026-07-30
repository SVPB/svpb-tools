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
#   - fontconfig: for fc-cache, so rsvg-convert can resolve the bundled fonts
#   - curl: for the compose healthcheck against /health
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libssl3 \
      libcurl4 \
      libxml2 \
      librsvg2-bin \
      fontconfig \
      ca-certificates \
      curl \
      git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The executable plus its SwiftPM resource bundles, staged together above.
COPY --from=build /staging/ ./
COPY --from=build /build/Resources ./Resources
COPY --from=build /build/Public ./Public

# Install the bundled faces where fontconfig can find them.
#
# On Apple platforms SVGPDFKit rasterises in-process through CoreGraphics, and
# `CeolKitFonts.register()` in configure.swift makes the faces resolvable there.
# Neither applies here: this build shells out to /usr/bin/rsvg-convert, and
# librsvg resolves font-family strictly through fontconfig — it ignores the
# @font-face data URIs CeolKit embeds in every SVG. Process-scope registration
# could not reach a separate process anyway. Without this, scores rasterise in
# whatever fontconfig substitutes: staff lines and stems, but no noteheads,
# clefs, rests, or accidentals.
RUN set -eu; \
    RES="$(find . -maxdepth 1 -name 'CeolKit_CeolKitSVGRenderer.*' -print -quit)"; \
    install -d /usr/local/share/fonts/ceolkit; \
    cp "$RES"/*.otf /usr/local/share/fonts/ceolkit/; \
    fc-cache -f; \
    for family in Bravura "Libertinus Serif"; do \
      if ! fc-list : family | grep -qF "$family"; then \
        echo "ERROR: $family is not resolvable through fontconfig." >&2; \
        echo "Every score would rasterise in a substitute font." >&2; \
        exit 1; \
      fi; \
    done

# The database and built PDFs live on the named volume, not in the image.
RUN mkdir -p data

EXPOSE 8080

ENTRYPOINT ["./TNG"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
