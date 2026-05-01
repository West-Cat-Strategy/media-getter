#!/usr/bin/env bash
set -euo pipefail

YT_DLP_VERSION="${YT_DLP_VERSION:-2026.03.17}"
DENO_VERSION="${DENO_VERSION:-2.7.14}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1}"
X264_VERSION="${X264_VERSION:-r3222}"
X264_REVISION="${X264_REVISION:-b35605ace3ddf7c1a5d67a2eb553f034aef41d55}"
LAME_VERSION="${LAME_VERSION:-3.100}"
WHISPER_VERSION="${WHISPER_VERSION:-1.8.4}"
WHISPER_MODEL_NAME="${WHISPER_MODEL_NAME:-base.en}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/build/vendor-media"
SRC_DIR="$WORK_DIR/src"
PREFIX_DIR="$WORK_DIR/prefix"
ARTIFACTS_DIR="$WORK_DIR/artifacts"
DOWNLOADS_DIR="$WORK_DIR/downloads"
VENV_DIR="$WORK_DIR/coreml-venv"
VENDOR_TOOLS_DIR="$ROOT_DIR/Vendor/Tools"
VENDOR_MODELS_DIR="$ROOT_DIR/Vendor/Models"
PYTHON311=""

if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is required to provision Python 3.11 for Core ML model generation." >&2
  exit 1
fi

mkdir -p "$SRC_DIR" "$PREFIX_DIR" "$ARTIFACTS_DIR" "$DOWNLOADS_DIR" "$VENDOR_TOOLS_DIR" "$VENDOR_MODELS_DIR"

uv python install 3.11 >/dev/null
PYTHON311="$(uv python find 3.11 --managed-python)"

download_file() {
  local url="$1"
  local output_path="$2"
  curl -L --fail --retry 3 --retry-delay 2 "$url" -o "$output_path"
}

extract_archive() {
  local archive_path="$1"
  local destination_path="$2"
  rm -rf "$destination_path"
  mkdir -p "$destination_path"

  case "$archive_path" in
    *.tar.gz|*.tgz)
      tar -xzf "$archive_path" -C "$destination_path" --strip-components=1
      ;;
    *.tar.xz)
      tar -xJf "$archive_path" -C "$destination_path" --strip-components=1
      ;;
    *.tar.bz2)
      tar -xjf "$archive_path" -C "$destination_path" --strip-components=1
      ;;
    *.zip)
      unzip -oq "$archive_path" -d "$destination_path"
      ;;
    *)
      echo "error: unsupported archive format: $archive_path" >&2
      exit 1
      ;;
  esac
}

assert_arm64_binary() {
  local tool_path="$1"
  local description

  description="$(/usr/bin/file -b "$tool_path")"
  if [[ "$description" == *"universal binary"* ]] || [[ "$description" != *"arm64"* ]]; then
    echo "error: expected an arm64-only binary at $tool_path. Found: $description" >&2
    exit 1
  fi
}

assert_self_contained_binary() {
  local tool_path="$1"
  local dependency

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == *"(architecture "*"):" ]] && continue

    dependency="${line%% *}"

    case "$dependency" in
      /System/*|/usr/lib/*|@executable_path/*|@loader_path/*|@rpath/*)
        ;;
      *)
        echo "error: binary $tool_path links an external dependency: $dependency" >&2
        exit 1
        ;;
    esac
  done < <(/usr/bin/otool -L "$tool_path" | tail -n +2 | sed 's/^[[:space:]]*//')
}

vendor_yt_dlp() {
  local archive_path="$DOWNLOADS_DIR/yt-dlp_${YT_DLP_VERSION}_macos"
  local thin_path="$ARTIFACTS_DIR/yt-dlp"

  download_file \
    "https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/yt-dlp_macos" \
    "$archive_path"

  /usr/bin/lipo "$archive_path" -thin arm64 -output "$thin_path"
  chmod +x "$thin_path"
  assert_arm64_binary "$thin_path"
  assert_self_contained_binary "$thin_path"
  cp -f "$thin_path" "$VENDOR_TOOLS_DIR/yt-dlp"
}

vendor_gallery_dl() {
  local archive_path="$DOWNLOADS_DIR/gallery-dl_macos"
  local thin_path="$ARTIFACTS_DIR/gallery-dl"

  download_file \
    "https://github.com/gdl-org/builds/releases/latest/download/gallery-dl_macos" \
    "$archive_path"

  /usr/bin/lipo "$archive_path" -thin arm64 -output "$thin_path"
  chmod +x "$thin_path"
  assert_arm64_binary "$thin_path"
  assert_self_contained_binary "$thin_path"
  cp -f "$thin_path" "$VENDOR_TOOLS_DIR/gallery-dl"
}

vendor_deno() {
  local archive_path="$DOWNLOADS_DIR/deno-v${DENO_VERSION}-aarch64-apple-darwin.zip"
  local extract_path="$ARTIFACTS_DIR/deno"

  download_file \
    "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-aarch64-apple-darwin.zip" \
    "$archive_path"

  rm -rf "$extract_path"
  mkdir -p "$extract_path"
  unzip -oq "$archive_path" -d "$extract_path"
  chmod +x "$extract_path/deno"
  assert_arm64_binary "$extract_path/deno"
  assert_self_contained_binary "$extract_path/deno"
  cp -f "$extract_path/deno" "$VENDOR_TOOLS_DIR/deno"
}

build_x264() {
  local source_path="$SRC_DIR/x264"

  rm -rf "$source_path"
  git clone --branch stable --single-branch https://code.videolan.org/videolan/x264.git "$source_path"
  (
    cd "$source_path"
    git checkout "$X264_REVISION"
    ./configure \
      --prefix="$PREFIX_DIR" \
      --disable-lsmash \
      --disable-swscale \
      --disable-ffms \
      --enable-static \
      --disable-shared \
      --enable-strip
    make -j"$(sysctl -n hw.ncpu)"
    make install
  )
}

build_lame() {
  local archive_path="$DOWNLOADS_DIR/lame-${LAME_VERSION}.tar.gz"
  local source_path="$SRC_DIR/lame"

  download_file \
    "https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz" \
    "$archive_path"

  extract_archive "$archive_path" "$source_path"
  (
    cd "$source_path"
    perl -0pi -e 's/lame_init_old\n//' include/libmp3lame.sym
    ./configure \
      --prefix="$PREFIX_DIR" \
      --disable-dependency-tracking \
      --disable-debug \
      --disable-shared \
      --enable-static \
      --disable-decoder
    make -j"$(sysctl -n hw.ncpu)"
    make install
  )
}

build_ffmpeg() {
  local archive_path="$DOWNLOADS_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
  local source_path="$SRC_DIR/ffmpeg"

  download_file \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    "$archive_path"

  extract_archive "$archive_path" "$source_path"
  (
    cd "$source_path"
    PKG_CONFIG_LIBDIR="$PREFIX_DIR/lib/pkgconfig" \
    PKG_CONFIG_PATH="" \
    ./configure \
      --prefix="$PREFIX_DIR/ffmpeg" \
      --arch=arm64 \
      --cc=clang \
      --enable-static \
      --disable-shared \
      --disable-debug \
      --disable-doc \
      --disable-ffplay \
      --disable-programs \
      --enable-ffmpeg \
      --enable-ffprobe \
      --enable-gpl \
      --enable-libx264 \
      --enable-libmp3lame \
      --enable-videotoolbox \
      --enable-audiotoolbox \
      --disable-libxcb \
      --disable-sdl2 \
      --disable-vulkan \
      --pkg-config-flags="--static" \
      --extra-cflags="-I$PREFIX_DIR/include -arch arm64" \
      --extra-ldflags="-L$PREFIX_DIR/lib -arch arm64"
    make -j"$(sysctl -n hw.ncpu)"
    make install
  )

  for tool in ffmpeg ffprobe; do
    chmod +x "$PREFIX_DIR/ffmpeg/bin/$tool"
    assert_arm64_binary "$PREFIX_DIR/ffmpeg/bin/$tool"
    assert_self_contained_binary "$PREFIX_DIR/ffmpeg/bin/$tool"
    cp -f "$PREFIX_DIR/ffmpeg/bin/$tool" "$VENDOR_TOOLS_DIR/$tool"
  done
}

build_whisper() {
  local archive_path="$DOWNLOADS_DIR/whisper.cpp-v${WHISPER_VERSION}.tar.gz"
  local source_path="$SRC_DIR/whisper.cpp"
  local build_path="$source_path/build-coreml"

  download_file \
    "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${WHISPER_VERSION}.tar.gz" \
    "$archive_path"

  extract_archive "$archive_path" "$source_path"
  cmake \
    -S "$source_path" \
    -B "$build_path" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_COREML=1 \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON
  cmake --build "$build_path" -j"$(sysctl -n hw.ncpu)" --target whisper-cli

  cp -f "$build_path/bin/whisper-cli" "$VENDOR_TOOLS_DIR/whisper-cli"
  chmod +x "$VENDOR_TOOLS_DIR/whisper-cli"
  assert_arm64_binary "$VENDOR_TOOLS_DIR/whisper-cli"
  assert_self_contained_binary "$VENDOR_TOOLS_DIR/whisper-cli"

  rm -rf "$VENV_DIR"
  "$PYTHON311" -m venv "$VENV_DIR"
  . "$VENV_DIR/bin/activate"

  python -m pip install --upgrade pip setuptools wheel
  python -m pip install -r "$source_path/models/requirements-coreml.txt"
  "$source_path/models/download-ggml-model.sh" "$WHISPER_MODEL_NAME" "$VENDOR_MODELS_DIR"

  (
    cd "$source_path"
    ./models/generate-coreml-model.sh "$WHISPER_MODEL_NAME"
  )

  rm -rf "$VENDOR_MODELS_DIR/ggml-${WHISPER_MODEL_NAME}-encoder.mlmodelc"
  cp -R \
    "$source_path/models/ggml-${WHISPER_MODEL_NAME}-encoder.mlmodelc" \
    "$VENDOR_MODELS_DIR/ggml-${WHISPER_MODEL_NAME}-encoder.mlmodelc"
}

main() {
  vendor_yt_dlp
  vendor_gallery_dl
  vendor_deno
  build_x264
  build_lame
  build_ffmpeg
  build_whisper

  echo "Vendored Apple Silicon media tools:"
  for tool in yt-dlp gallery-dl deno ffmpeg ffprobe whisper-cli; do
    if [[ -f "$VENDOR_TOOLS_DIR/$tool" ]]; then
      /usr/bin/file "$VENDOR_TOOLS_DIR/$tool"
    else
      echo "Warning: $tool is missing from $VENDOR_TOOLS_DIR"
    fi
  done

  echo
  for tool in yt-dlp gallery-dl deno ffmpeg ffprobe whisper-cli; do
    if [[ -f "$VENDOR_TOOLS_DIR/$tool" ]]; then
       du -sh "$VENDOR_TOOLS_DIR/$tool"
    fi
  done

  du -sh \
    "$VENDOR_MODELS_DIR/ggml-${WHISPER_MODEL_NAME}.bin" \
    "$VENDOR_MODELS_DIR/ggml-${WHISPER_MODEL_NAME}-encoder.mlmodelc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
