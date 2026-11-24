#!/bin/zsh
# Construye TrackDrum.app y la instala en /Applications.
#   ./Scripts/build-app.sh            → compila, empaqueta e instala
#   ./Scripts/build-app.sh --no-install → deja la app en ./build/TrackDrum.app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0"
APP="build/TrackDrum.app"

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TrackDrum "$APP/Contents/MacOS/TrackDrum"
cp -R .build/release/TrackDrum_TrackDrum.bundle/Web "$APP/Contents/Resources/Web"

# Icono: Art/AppIcon.png (1024) → AppIcon.icns
[[ -f Art/AppIcon.png ]] || swift Scripts/make-icon.swift
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Art/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Art/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TrackDrum</string>
  <key>CFBundleDisplayName</key><string>TrackDrum</string>
  <key>CFBundleIdentifier</key><string>com.trackdrum.TrackDrum</string>
  <key>CFBundleExecutable</key><string>TrackDrum</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>TrackDrum</string>
</dict>
</plist>
EOF

# Firma local (ad hoc): suficiente para usarla en este Mac.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Hecho: $APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x TrackDrum 2>/dev/null && sleep 1 || true
  rm -rf /Applications/TrackDrum.app
  cp -R "$APP" /Applications/
  echo "Instalada en /Applications/TrackDrum.app"
fi
