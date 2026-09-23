#!/bin/bash
# 앱에 내장할 whisper-cli, ffmpeg, ffprobe를 소스에서 빌드 (Apple Silicon/M시리즈 전용)
# 결과: vendor/bin/{whisper-cli,ffmpeg,ffprobe}
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SRC="$HOME/Library/Caches/EasyCutBuild"
OUT="$ROOT/vendor/bin"
mkdir -p "$OUT"
JOBS=$(sysctl -n hw.ncpu)
MIN=14.0

build_whisper() {
  local arch=$1 dir="$SRC/build-whisper-$1"
  cmake -S "$SRC/whisper.cpp" -B "$dir" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$arch \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF >/dev/null
  cmake --build "$dir" --target whisper-cli -j "$JOBS" >/dev/null
  cp "$dir/bin/whisper-cli" "$SRC/whisper-cli-$arch"
}

build_ffmpeg() {
  local arch=$1 dir="$SRC/build-ffmpeg-$1"
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"
  local extra=()
  if [ "$arch" = "x86_64" ]; then extra=(--enable-cross-compile --disable-x86asm); fi
  "$SRC/ffmpeg/configure" --arch=$arch --target-os=darwin --cc="clang -arch $arch" ${extra[@]+"${extra[@]}"} \
    --extra-cflags="-mmacosx-version-min=$MIN" --extra-ldflags="-mmacosx-version-min=$MIN" --extra-libs="-liconv" \
    --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv \
    --disable-doc --disable-debug --disable-ffplay --disable-network --disable-shared --enable-static \
    --disable-indevs --disable-outdevs >/dev/null
  make -j "$JOBS" ffmpeg ffprobe >/dev/null 2>"$dir/make.err" || { tail -20 "$dir/make.err"; exit 1; }
  cp ffmpeg "$SRC/ffmpeg-$arch"; cp ffprobe "$SRC/ffprobe-$arch"
  cd "$ROOT"
}

for arch in arm64; do  # M시리즈 전용
  echo "▶ whisper-cli ($arch)"; build_whisper $arch
  echo "▶ ffmpeg ($arch)"; build_ffmpeg $arch
done
for b in whisper-cli ffmpeg ffprobe; do
  cp "$SRC/$b-arm64" "$OUT/$b"
  strip -x "$OUT/$b" 2>/dev/null || true
done
# 라이선스 고지
mkdir -p "$ROOT/vendor/licenses"
cp "$SRC/whisper.cpp/LICENSE" "$ROOT/vendor/licenses/whisper.cpp-MIT.txt"
cp "$SRC/ffmpeg/COPYING.LGPLv2.1" "$ROOT/vendor/licenses/FFmpeg-LGPL-2.1.txt"
echo "FFmpeg 8.0 (LGPL). 소스: https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz  구성: scripts/build_deps.sh" > "$ROOT/vendor/licenses/FFmpeg-SOURCE.txt"
ls -lh "$OUT"; for b in "$OUT"/*; do lipo -archs "$b"; done
