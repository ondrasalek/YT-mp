# syntax=docker/dockerfile:1

# ---------- Stage 1: build Rust binárky + stažení statického ffmpeg ----------
FROM rust:1-bookworm AS builder
WORKDIR /build

# Nástroje pro stažení a rozbalení statického ffmpeg.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Statický ffmpeg (bez systémových knihoven) — nahrazuje 400+ MB apt vrstvu.
# TARGETARCH dodává buildkit automaticky (amd64 / arm64).
ARG TARGETARCH=amd64
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) FFARCH=amd64 ;; \
      arm64) FFARCH=arm64 ;; \
      *)     FFARCH=amd64 ;; \
    esac; \
    curl -fSL --retry 3 \
      "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${FFARCH}-static.tar.xz" \
      -o /tmp/ffmpeg.tar.xz; \
    mkdir -p /tmp/ffmpeg; \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg --strip-components=1; \
    cp /tmp/ffmpeg/ffmpeg /usr/local/bin/ffmpeg; \
    cp /tmp/ffmpeg/ffprobe /usr/local/bin/ffprobe; \
    /usr/local/bin/ffmpeg -version | head -1

# Cache vrstvy závislostí Rustu (jen manifesty).
COPY rust_backend/Cargo.toml rust_backend/Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs \
    && cargo build --release \
    && rm -rf src

# Skutečné zdrojáky (web/ je potřeba kvůli include_str! ve build-time).
COPY rust_backend/src ./src
COPY rust_backend/web ./web
RUN touch src/main.rs && cargo build --release

# ---------- Stage 2: běhový image ----------
FROM python:3.12-slim AS runtime

# Jen CA certifikáty (pro HTTPS yt-dlp); ffmpeg je statický (níže).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python worker + jeho závislosti (yt-dlp).
COPY python_core/ /app/python_core/
RUN pip install --no-cache-dir -r /app/python_core/requirements.txt

# ffmpeg a ffprobe jako DVĚ samostatné vrstvy (každá < 100 MB kvůli proxy limitu).
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe

# Rust binárka z builderu.
COPY --from=builder /build/target/release/ytmp /usr/local/bin/ytmp

# Dočasné per-job soubory (mažou se po TTL); volitelně mountovatelné volume.
RUN mkdir -p /app/data

# Kde leží worker a jaký interpret použít (autodetekce by také našla python3).
ENV YTMP_SCRIPT=/app/python_core/downloader.py
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

# Naslouchá na 0.0.0.0, aby byl server dostupný mimo kontejner.
CMD ["ytmp", "serve", "--host", "0.0.0.0", "--port", "8080", "--python", "python3", "--data-dir", "/app/data"]
