# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM swift:6.2-noble AS build

WORKDIR /build

# Resolve dependencies before copying source so that this layer is cached
# as long as Package.swift and Package.resolved don't change.
COPY Package.swift Package.resolved* ./
RUN swift package resolve

# Copy source and build in release mode.
COPY Sources ./Sources
COPY Tests ./Tests
COPY Resources ./Resources
RUN swift build -c release --product TNG 2>&1

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM swift:6.2-noble-slim AS runtime

# Runtime dependencies:
#   - libssl / libcurl: for AsyncHTTPClient / Vapor
#   - git: for cloning and pulling svpb-music on webhook events
#   - ca-certificates: for TLS verification against Box and Slack APIs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libssl3 \
      libcurl4 \
      libxml2 \
      ca-certificates \
      git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /build/.build/release/TNG .
COPY --from=build /build/Resources ./Resources

# The database and built PDFs live on the named volume, not in the image.
RUN mkdir -p data

EXPOSE 8080

ENTRYPOINT ["./TNG"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
