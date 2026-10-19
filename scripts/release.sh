#!/bin/bash
# Builds a self-contained Release of Mangosteen (ffmpeg, ffprobe, cwebp and gif2webp inside the app).
#   scripts/release.sh            build into build/release
#   scripts/release.sh --install  build, then replace /Applications/Mangosteen.app and start it
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -scheme Mangosteen -configuration Release -derivedDataPath build/release build -quiet
APP="build/release/Build/Products/Release/Mangosteen.app"

python3 scripts/bundle_tools.py "$APP"
codesign --force --sign - "$APP"

# The bundled tools must start on their own.
"$APP/Contents/Resources/Tools/ffmpeg" -hide_banner -version | head -1
"$APP/Contents/Resources/Tools/cwebp" -version > /dev/null
du -sh "$APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Mangosteen 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Mangosteen.app
    cp -R "$APP" /Applications/
    open /Applications/Mangosteen.app
    echo "Installed /Applications/Mangosteen.app"
fi
