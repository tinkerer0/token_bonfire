#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${TOKEN_BONFIRE_OUTPUT_APP:-$ROOT/dist/TokenBonfire.app}"
VERSION="${TOKEN_BONFIRE_VERSION:-0.1.0}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
read -r -a architectures <<< "${ARCHS:-$(uname -m)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid TOKEN_BONFIRE_VERSION' >&2; exit 1; }
mkdir -p "$ROOT/.build/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
binaries=()
for architecture in "${architectures[@]}"; do
  case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
  binary="$ROOT/.build/TokenBonfire-$architecture"
  xcrun swiftc -swift-version 5 -O -sdk "$SDK" \
    -target "$architecture-apple-macos13.0" \
    -module-cache-path "$ROOT/.build/module-cache" \
    "$ROOT"/Sources/*.swift -framework AppKit -framework ServiceManagement -o "$binary"
  binaries+=("$binary")
done
xcrun lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/TokenBonfire"
cp "$ROOT"/Resources/fire-*-atlas.png "$ROOT/Resources/coin-atlas.png" "$ROOT/Resources/digits-atlas.png" "$ROOT/Resources/digits-goal-atlas.png" \
   "$ROOT/Resources/manifest.json" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.jinwoo.tokenbonfire</string>
<key>CFBundleName</key><string>Token Bonfire</string>
<key>CFBundleDisplayName</key><string>Token Bonfire</string>
<key>CFBundleExecutable</key><string>TokenBonfire</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built: %s\n' "$APP"
