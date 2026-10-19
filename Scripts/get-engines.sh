#!/bin/bash
# Downloads static, dependency-free engine binaries into
#   ~/Library/Application Support/Clementine/engine
# so Clementine works without Homebrew (Intel Macs on new macOS releases have no
# bottles and brew compiles for an hour). Re-run any time to update.
set -euo pipefail
DIR="$HOME/Library/Application Support/Clementine/engine"
mkdir -p "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ARCH=$(uname -m)          # x86_64 or arm64

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

echo "→ ffmpeg + ffprobe (static builds)"
MR=$([[ "$ARCH" == "x86_64" ]] && echo amd64 || echo arm64)
for tool in ffmpeg ffprobe; do
  if fetch "https://ffmpeg.martin-riedl.de/redirect/latest/macos/${MR}/release/${tool}.zip" "$TMP/$tool.zip" \
     || { [[ "$ARCH" == "x86_64" ]] && fetch "https://evermeet.cx/ffmpeg/getrelease/$([[ $tool == ffmpeg ]] && echo zip || echo ffprobe/zip)" "$TMP/$tool.zip"; }; then
    ditto -x -k "$TMP/$tool.zip" "$TMP/$tool.d" && cp "$(find "$TMP/$tool.d" -type f -name "$tool" | head -1)" "$DIR/$tool"
  else
    echo "   $tool: no static download reachable (brew install ffmpeg works too)"
  fi
done

echo "→ pandoc (GitHub release, static)"
ASSET=$(curl -fsSL https://api.github.com/repos/jgm/pandoc/releases/latest | grep -o "https://[^\"]*-${ARCH}-macOS.zip" | head -1)
if [[ -n "$ASSET" ]]; then
  fetch "$ASSET" "$TMP/pandoc.zip" && ditto -x -k "$TMP/pandoc.zip" "$TMP/pandoc"
  cp "$(find "$TMP/pandoc" -type f -name pandoc | head -1)" "$DIR/pandoc"
fi

echo "→ cwebp (Google libwebp prebuilt)"
WARCH=$([[ "$ARCH" == "x86_64" ]] && echo "x86-64" || echo "arm64")
for V in 1.6.0 1.5.0 1.4.0; do
  if fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${V}-mac-${WARCH}.tar.gz" "$TMP/webp.tgz"; then
    tar -xzf "$TMP/webp.tgz" -C "$TMP"
    cp "$(find "$TMP" -type f -path '*/bin/cwebp' | head -1)" "$DIR/cwebp"
    break
  fi
done

chmod +x "$DIR"/* 2>/dev/null || true
xattr -dr com.apple.quarantine "$DIR" 2>/dev/null || true
echo
echo "Installed in $DIR:"
ls -la "$DIR"
echo "Check with:  Clementine engines"
