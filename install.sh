#!/usr/bin/env bash
# pulse installer — copies pulse.sh to /usr/local/bin/pulse
# Run as root or with sudo.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/pulse.sh"
DEST="/usr/local/bin/pulse"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "Installed: $DEST"
