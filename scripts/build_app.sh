#!/bin/bash
# EasyCut.app 빌드 → dist/EasyCut.app, dist/EasyCut.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/EasyCut.app"
VERSION="1.0.0"

echo "▶ 릴리스 빌드"
swift build -c release --arch arm64 2>&1 | grep -E "error|Compiling|Build complete" || true
BIN="$ROOT/.build/arm64-apple-macosx/release/EasyCut"
[ -x "$BIN" ] || BIN="$ROOT/.build/release/EasyCut"
[ -x "$BIN" ] || { echo "빌드 실패"; exit 1; }

echo "▶ 앱 번들 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EasyCut"

echo "▶ 아이콘 생성"
ICONSET="$ROOT/.build/EasyCut.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$BIN" --make-icon "$ROOT/.build/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/.build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$ROOT/.build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>EasyCut</string>
  <key>CFBundleDisplayName</key><string>EasyCut</string>
  <key>CFBundleIdentifier</key><string>com.contenjoo.easycut</string>
  <key>CFBundleExecutable</key><string>EasyCut</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>영상 속 음성을 텍스트(대본·자막)로 바꾸기 위해 음성 인식을 사용합니다. 인식은 이 Mac 안에서 처리됩니다.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>EasyCut 프로젝트</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>CFBundleTypeExtensions</key><array><string>easycut</string></array>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>기타 영상 (MKV 등)</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>mkv</string><string>webm</string><string>avi</string><string>flv</string><string>wmv</string><string>ts</string><string>mts</string><string>m2ts</string><string>mpg</string><string>mpeg</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>미디어</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.audio</string><string>public.image</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.contenjoo.easycut.project</string>
      <key>UTTypeDescription</key><string>EasyCut 프로젝트</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>easycut</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶ 서명 (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"

if [ "${1:-}" = "--dmg" ]; then
  echo "▶ DMG 생성"
  STAGE="$ROOT/.build/dmg"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$ROOT/dist/EasyCut.dmg"
  hdiutil create -volname "EasyCut" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/EasyCut.dmg" >/dev/null
  echo "  → dist/EasyCut.dmg"
fi
echo "✅ 완료: $APP"
