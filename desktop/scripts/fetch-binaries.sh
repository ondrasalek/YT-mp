#!/usr/bin/env bash
# Stáhne sidecar binárky (yt-dlp + ffmpeg) pro Tauri bundle a pojmenuje je
# podle cílového triple, jak vyžaduje Tauri `externalBin`.
#
# Použití:
#   ./scripts/fetch-binaries.sh                # autodetekce dle hostitele
#   TARGET=aarch64-apple-darwin ./scripts/fetch-binaries.sh
#
# Podporované cíle: aarch64-apple-darwin, x86_64-apple-darwin
set -euo pipefail

FFMPEG_RELEASE="b6.1.1" # eugeneware/ffmpeg-static

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../src-tauri/binaries"
mkdir -p "$BIN_DIR"

# --- zjisti cílový triple ---
if [[ -z "${TARGET:-}" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) TARGET="aarch64-apple-darwin" ;;
    x86_64)        TARGET="x86_64-apple-darwin" ;;
    *) echo "Neznámá architektura $(uname -m); nastav TARGET ručně." >&2; exit 1 ;;
  esac
fi

case "$TARGET" in
  aarch64-apple-darwin) FFMPEG_ARCH="darwin-arm64" ;;
  x86_64-apple-darwin)  FFMPEG_ARCH="darwin-x64" ;;
  *) echo "Nepodporovaný TARGET: $TARGET" >&2; exit 1 ;;
esac

echo "Cíl: $TARGET"

# --- yt-dlp (oficiální release, univerzální macOS binárka) ---
echo "Stahuji yt-dlp…"
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" \
  -o "$BIN_DIR/yt-dlp-$TARGET"

# --- ffmpeg (statický build) ---
echo "Stahuji ffmpeg ($FFMPEG_ARCH)…"
curl -fL "https://github.com/eugeneware/ffmpeg-static/releases/download/$FFMPEG_RELEASE/ffmpeg-$FFMPEG_ARCH.gz" \
  -o "$BIN_DIR/ffmpeg.gz"
gunzip -f "$BIN_DIR/ffmpeg.gz"
mv "$BIN_DIR/ffmpeg" "$BIN_DIR/ffmpeg-$TARGET"

chmod +x "$BIN_DIR/yt-dlp-$TARGET" "$BIN_DIR/ffmpeg-$TARGET"

echo "Hotovo:"
ls -la "$BIN_DIR/yt-dlp-$TARGET" "$BIN_DIR/ffmpeg-$TARGET"
