#!/bin/zsh
# Copies the sidecar binaries into the app bundle (runs as an Xcode post-build phase).
#
#   Resources/bin/yt-dlp
#   Resources/bin/ffmpeg
#
# They are the same files the Tauri build bundles: desktop/src-tauri/binaries/<name>-<target triple>, fetched
# by desktop/scripts/fetch-binaries.sh and git-ignored. If they are missing the app still builds and shows a
# "bundled yt-dlp not found" error when a download is started (or uses YTMP_YT_DLP / YTMP_FFMPEG).
set -euo pipefail

ROOT="${SRCROOT:A:h}"
BIN_SRC="$ROOT/desktop/src-tauri/binaries"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
mkdir -p "$DEST"

case "${ARCHS%% *}" in
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *)      TRIPLE="aarch64-apple-darwin" ;;
esac

for name in yt-dlp ffmpeg; do
  src="$BIN_SRC/$name-$TRIPLE"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$DEST/$name"
    chmod 755 "$DEST/$name"
  else
    echo "warning: $src is missing; run desktop/scripts/fetch-binaries.sh" >&2
  fi
done
