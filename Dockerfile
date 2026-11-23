# syntax=docker/dockerfile:1.29@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183
# Multi-stage Dockerfile for BackVault — one static binary in a distroless static image.
# Platform: linux/amd64 only.
#
# The builder is the official Rust image on Alpine, whose toolchain targets musl natively and
# which ships gcc and musl-dev, so the one C-backed crate in the tree (ring, via rustls) builds
# without a package manager. `--locked` honours Cargo.lock exactly; crates.io is the only
# network access and only for those pinned versions. rust-toolchain.toml is excluded by
# .dockerignore so rustup never downloads a toolchain here (IMAGE-BUILD-008).
#
# The runtime is Chainguard's static image: no shell, no package manager, no interpreter,
# no libc. It holds exactly one file the project built. The restore tool is never copied in.

# ============================================
# Builder stage
# ============================================
FROM docker.io/library/rust:1.99.1-alpine@sha256:44819b27be4c97b0e4d7203bd2e02c4820f97700211b6a37fb4c246a2de59383 AS builder

WORKDIR /build

COPY Cargo.toml Cargo.lock ./
COPY crates ./crates

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked -p backvault --target x86_64-unknown-linux-musl \
    && cp target/x86_64-unknown-linux-musl/release/backvault /backvault

# ============================================
# Runtime stage — distroless static
# ============================================
FROM cgr.dev/chainguard/static:latest@sha256:54b5f14edad6f2554774d499539e837588a501bd5bf22ac6cd97b1068c35d44d

USER 1000:1000
WORKDIR /app

COPY --from=builder --chown=1000:1000 /backvault /app/backvault

ENV HOME=/app

ENTRYPOINT ["/app/backvault"]
