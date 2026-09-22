# ── Image for running the test suite on Linux ──────────────────────────────────
# What CI runs (`.github/workflows/ci.yml`), in a container on a developer's
# machine: Swift 6.3 — CeolKit's manifest declares `swift-tools-version: 6.3`,
# which older toolchains refuse to parse — and rsvg-convert, which is how
# SVGPDFKit rasterises when CoreGraphics is not there. No font packages: CeolKit
# writes glyph geometry into every SVG (`TextRendering.outlines`), so
# rsvg-convert never consults fontconfig for a face.
#
# `clang` is in the toolchain image already, and the entrypoint uses it to build
# the `fineres.so` shim that keeps XCTest from hanging under Docker Desktop; see
# `Scripts/linux-tests.sh` and CLAUDE.md.
#
# Driven by `Scripts/linux-tests.sh`, which is also this image's entrypoint:
#
#     Scripts/linux-tests.sh                        # the whole suite
#     Scripts/linux-tests.sh --filter BinderTests   # arguments reach swift test
FROM swift:6.3-noble AS test

RUN apt-get update \
 && apt-get install -y --no-install-recommends librsvg2-bin \
 && rm -rf /var/lib/apt/lists/*

# The repository is mounted here, read-write because SwiftPM wants to update
# Package.resolved; the build tree stays outside it, in the volume the runner
# mounts at $TNG_LINUX_TESTS_SCRATCH. Keeping it out of the working tree is what
# stops this build and a macOS `swift build` from fighting over `.build`, whose
# Linux module cache is stamped with the absolute path it was built at.
WORKDIR /src

ENV TNG_LINUX_TESTS_IN_CONTAINER=1 \
    TNG_LINUX_TESTS_SCRATCH=/linuxbuild

COPY Scripts/linux-tests.sh /usr/local/bin/linux-tests
ENTRYPOINT ["/usr/local/bin/linux-tests"]
