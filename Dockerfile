# syntax=docker/dockerfile:1

# ---------- Stage 1: build Rust binárky ----------
FROM rust:1-bookworm AS builder
WORKDIR /build

# Nejprve jen manifesty -> cache vrstvy závislostí.
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

# ffmpeg pro extrakci audia / remux (systémová závislost yt-dlp).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python worker + jeho závislosti (yt-dlp). V oficiálním python image
# není pip "externally-managed", takže instalace globálně je v pořádku.
COPY python_core/ /app/python_core/
RUN pip install --no-cache-dir -r /app/python_core/requirements.txt

# Rust binárka z builderu.
COPY --from=builder /build/target/release/ytmp /usr/local/bin/ytmp

# Adresář pro výstupy (mountuje se přes compose volume).
RUN mkdir -p /app/downloads

# Kde leží worker a jaký interpret použít (autodetekce by také našla python3).
ENV YTMP_SCRIPT=/app/python_core/downloader.py
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

# Naslouchá na 0.0.0.0, aby byl server dostupný mimo kontejner.
CMD ["ytmp", "serve", "--host", "0.0.0.0", "--port", "8080", "--python", "python3"]
