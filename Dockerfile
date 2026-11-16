# syntax=docker/dockerfile:1
#
# PS5 Dump Forge — Docker image
#
# Builds the CLI binary (ps5-dump-forge) with the web UI embedded, then runs it
# as a lightweight HTTP server on port 8095. The web UI is the same one the PS5
# payload serves: open http://localhost:8095 in any browser.
#
# Build:  docker build -t ps5-dump-forge .
# Run:    docker run -p 8095:8095 -v "$PWD/data":/data ps5-dump-forge
# CLI:    docker run --rm -v "$PWD/data":/data ps5-dump-forge inspect /data/mygame
#
# Multi-arch (needs buildx + QEMU):
#   docker buildx build --platform linux/amd64,linux/arm64 -t ps5-dump-forge:latest .

# ---- Stage 1: Build the web UI (app/dist-http) -------------------------------
FROM node:22-slim AS web
WORKDIR /app
# Cache node_modules layer: only rebuilds when package files change.
COPY app/package.json app/package-lock.json ./
RUN npm ci
# Copy the rest of the app source (node_modules excluded by .dockerignore).
COPY app/ ./
RUN npm run build:http

# ---- Stage 2: Build the Rust CLI with the web UI embedded --------------------
FROM rust:1.100.0-slim-trixie AS builder

# build-essential + g++: UnRAR's C++ source (unrar_sys) and the archive ABI check (cc crate).
# make: unrar_sys build system. pkg-config: conventional, some crates probe for it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential g++ pkg-config make ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy the entire workspace (vendor patches, Cargo.lock, all crates).
COPY . .
# Overlay the web UI built in Stage 1 (the server's build.rs embeds it).
COPY --from=web /app/dist-http app/dist-http

# The repo's rust-toolchain.toml pins macOS targets we don't need on Linux;
# removing it lets cargo use this image's default toolchain (1.100.0).
RUN rm -f rust-toolchain.toml

# FORGE_REQUIRE_WEB=1: build.rs fails if app/dist-http/index.html is missing,
# guaranteeing the web UI is embedded rather than a placeholder page.
ENV FORGE_REQUIRE_WEB=1

# Build the CLI only (not the Tauri GUI, which needs desktop libraries).
# Cache mounts speed up rebuilds; the binary is copied out of the cache dir
# so it survives into the next stage.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/build/target,sharing=locked \
    cargo build --release --locked -p ps5-dump-forge-cli \
    && cp /build/target/release/ps5-dump-forge /build/ps5-dump-forge

# ---- Stage 3: Minimal runtime -----------------------------------------------
FROM debian:trixie-slim AS runtime

# libstdc++6 + libgcc-s1: UnRAR's C++ runtime (statically compiled, dynamically linked CRT).
# ca-certificates: HTTPS fetches. curl: healthcheck.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libstdc++6 libgcc-s1 curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/ps5-dump-forge /usr/local/bin/ps5-dump-forge

# /data is the default --root: mount your game folders here.
RUN mkdir -p /data
VOLUME ["/data"]

EXPOSE 8095

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
    CMD curl -sf http://localhost:8095/ >/dev/null || exit 1

# ENTRYPOINT is the binary itself, so you can run any subcommand:
#   docker run --rm -v "$PWD/data":/data ps5-dump-forge inspect /data/game
#   docker run --rm -v "$PWD/data":/data ps5-dump-forge convert /data/game --to ffpkg -o /data/out.pkg
ENTRYPOINT ["ps5-dump-forge"]
CMD ["serve", "--port", "8095", "--root", "/data"]
