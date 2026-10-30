#!/bin/bash
# 빌드 결과는 ZIP/DMG로 보관. --install이면 /Applications/EasyCut.app에 설치
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
MAKE_DMG=false
INSTALL_APP=false
for arg in "$@"; do
  case "$arg" in
    --dmg) MAKE_DMG=true ;;
    --install) INSTALL_APP=true ;;
    *) echo "사용법: $0 [--dmg] [--install]" >&2; exit 2 ;;
  esac
done
mkdir -p "$ROOT/.build" "$ROOT/dist"
WORK=$(mktemp -d "$ROOT/.build/app-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/EasyCut.app"
VERSION="1.13.0"

# 서명: 키체인에 'EasyCut Self-Signed' 인증서가 있으면 그것으로 (업데이트해도 macOS 권한이 유지됨), 없으면 ad-hoc
SIGN_ID="${EASYCUT_SIGN_ID:-EasyCut Self-Signed}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  echo "▶ 서명 인증서: $SIGN_ID"
else
  echo "▶ 서명 인증서 없음 → ad-hoc 서명 (업데이트마다 화면 녹화·카메라 권한을 다시 물을 수 있음)"
  SIGN_ID="-"
fi

echo "▶ 릴리스 빌드"
BUILD_LOG=$(mktemp)
if ! swift build -c release --arch arm64 > "$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG"
  rm -f "$BUILD_LOG"
  exit 1
fi
grep -E "error|Compiling|Build complete" "$BUILD_LOG" || true
rm -f "$BUILD_LOG"
BIN="$ROOT/.build/arm64-apple-macosx/release/EasyCut"
[ -x "$BIN" ] || BIN="$ROOT/.build/release/EasyCut"
[ -x "$BIN" ] || { echo "빌드 실패"; exit 1; }

echo "▶ 앱 번들 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 언어: 한국어(원문) + 영어 (앱 문구는 LocTable, 권한 안내문은 InfoPlist.strings)
mkdir -p "$APP/Contents/Resources/ko.lproj" "$APP/Contents/Resources/en.lproj"
: > "$APP/Contents/Resources/ko.lproj/InfoPlist.strings"
# 한국어는 원문 그대로(키 = 한국어), 영어 문구표는 scripts/gen_strings.py 로 만든다
echo '"EasyCut" = "EasyCut";' > "$APP/Contents/Resources/ko.lproj/Localizable.strings"
python3 "$ROOT/scripts/gen_strings.py" >/dev/null && cp "$ROOT/Resources/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSCameraUsageDescription" = "EasyCut uses the camera to record your face along with the screen.";
"NSMicrophoneUsageDescription" = "EasyCut uses the microphone to record your voice.";
"NSSpeechRecognitionUsageDescription" = "EasyCut uses speech recognition to turn speech in your videos into text (transcripts and captions). Recognition runs on this Mac.";
STRINGS
cp "$BIN" "$APP/Contents/MacOS/EasyCut"
cp "$ROOT/Resources/VideoSkillNotices.txt" "$APP/Contents/Resources/VideoSkillNotices.txt"

echo "▶ 내장 도구 (Whisper·ffmpeg)"
if [ -x "$ROOT/vendor/bin/whisper-cli" ] && [ -x "$ROOT/vendor/bin/ffmpeg" ]; then
  mkdir -p "$APP/Contents/Resources/bin" "$APP/Contents/Resources/licenses"
  for tool in whisper-cli ffmpeg ffprobe; do
    if [ -f "$ROOT/vendor/bin/$tool" ]; then
      COPYFILE_DISABLE=1 cp "$ROOT/vendor/bin/$tool" "$APP/Contents/Resources/bin/"
    fi
  done
  cp "$ROOT/vendor/licenses/"* "$APP/Contents/Resources/licenses/" 2>/dev/null || true
  xattr -cr "$APP/Contents/Resources/bin"
  for b in "$APP/Contents/Resources/bin/"*; do codesign --force --sign "$SIGN_ID" --timestamp=none "$b"; done
else
  echo "  (vendor/bin 없음 — ./scripts/build_deps.sh 를 먼저 실행하면 Whisper·ffmpeg가 내장됩니다)"
fi

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
  <key>CFBundleVersion</key><string>26</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>ko</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSRequiresNativeExecution</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>화면 녹화와 함께 얼굴(카메라)을 녹화하기 위해 카메라를 사용합니다.</string>
  <key>NSMicrophoneUsageDescription</key><string>녹화할 때 목소리를 함께 담기 위해 마이크를 사용합니다.</string>
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

echo "▶ 앱 서명"
xattr -cr "$APP"
codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$APP"

if [ "$MAKE_DMG" = true ]; then
  echo "▶ DMG 생성"
  STAGE="$WORK/dmg"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "$ROOT/scripts/설치 방법.txt" "$STAGE/설치 방법.txt"
  cp "$ROOT/scripts/How to Install.txt" "$STAGE/How to Install.txt"
  rm -f "$ROOT/dist/EasyCut.dmg" "$ROOT/dist/EasyCut-$VERSION.dmg"
  hdiutil create -volname "EasyCut $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/EasyCut-$VERSION.dmg" >/dev/null
  echo "  → dist/EasyCut-$VERSION.dmg ($(du -h "$ROOT/dist/EasyCut-$VERSION.dmg" | cut -f1))"
fi
echo "▶ 앱 압축 보관"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/EasyCut.app.zip"
unzip -tq "$WORK/EasyCut.app.zip" >/dev/null
mv -f "$WORK/EasyCut.app.zip" "$ROOT/dist/EasyCut.app.zip"
if [ "$INSTALL_APP" = true ]; then
  # 정상 종료는 저장 확인창을 거친다. 취소하면 설치하지 않는다.
  osascript -e 'if application id "com.contenjoo.easycut" is running then tell application id "com.contenjoo.easycut" to quit'
  running_status=0
  # AppKit의 정상 종료가 반환된 뒤 프로세스가 사라지기까지 잠깐 걸릴 수 있다.
  # 종료를 기다리기만 하며 저장 취소나 실행 중인 앱을 강제로 종료하지 않는다.
  for attempt in {1..50}; do
    running_status=0
    pgrep -f '^/Applications/EasyCut.app/Contents/MacOS/EasyCut([[:space:]]|$)' >/dev/null || running_status=$?
    if [ "$running_status" -ne 0 ]; then break; fi
    sleep 0.2
  done
  if [ "$running_status" -ne 1 ]; then
    echo "EasyCut을 종료한 뒤 다시 설치해 주세요." >&2
    exit 1
  fi
  # Replace the bundle instead of merging: stale files invalidate the new signature.
  PREVIOUS="$WORK/previous.app"
  if [ -d /Applications/EasyCut.app ]; then
    BACKUP="$ROOT/dist/EasyCut-before-$VERSION-install.app.zip"
    ditto -c -k --sequesterRsrc --keepParent /Applications/EasyCut.app "$WORK/previous.app.zip"
    unzip -tq "$WORK/previous.app.zip" >/dev/null
    mv -f "$WORK/previous.app.zip" "$BACKUP"
    mv /Applications/EasyCut.app "$PREVIOUS"
  fi
  if ! ditto "$APP" /Applications/EasyCut.app || ! codesign --verify --deep --strict /Applications/EasyCut.app; then
    rm -rf /Applications/EasyCut.app
    if [ -d "$PREVIOUS" ]; then mv "$PREVIOUS" /Applications/EasyCut.app; fi
    echo "설치 검증 실패 — 기존 앱을 복원했습니다." >&2
    exit 1
  fi
  echo "✅ 설치: /Applications/EasyCut.app"
fi
echo "✅ 완료: dist/EasyCut.app.zip"
