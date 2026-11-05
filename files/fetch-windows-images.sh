#!/usr/bin/env bash
# Downloads the Windows qcow2 images into files/ at build time.
# The images are too large for Git/GitHub (3.8 GB and 6.4 GB), so they are
# fetched on demand instead of being committed. They are ignored by .gitignore.
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)"
BASE="https://archive.org/download/windows-image-collection"

for name in "Windows 10.qcow2" "Windows 11.qcow2"; do
  url="$BASE/${name// /%20}"
  echo "Downloading $name ..."
  curl -fL --retry 5 -C - -o "$DEST/$name" "$url"
done
