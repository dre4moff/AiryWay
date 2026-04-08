#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/AiryWayApp/AiryWayApp/Vendor/llama"
OUT_DIR="$VENDOR_DIR/build-apple"
WORK_DIR="${TMPDIR:-/tmp}/airyway-llama-multimodal"
SRC_DIR="$WORK_DIR/llama.cpp"

IOS_MIN="16.4"

ensure_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

ensure_tool git
ensure_tool cmake
ensure_tool xcrun

mkdir -p "$WORK_DIR"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  echo "Cloning llama.cpp into $SRC_DIR"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC_DIR"
else
  echo "Updating llama.cpp in $SRC_DIR"
  git -C "$SRC_DIR" fetch --depth 1 origin master
  git -C "$SRC_DIR" reset --hard FETCH_HEAD
fi

common_cmake_args=(
  -DBUILD_SHARED_LIBS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_TOOLS=ON
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_SERVER=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS_DEFAULT=ON
  -DGGML_METAL_USE_BF16=ON
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
  -DLLAMA_OPENSSL=OFF
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
)

echo "Configuring iOS simulator build..."
cmake -S "$SRC_DIR" -B "$SRC_DIR/build-ios-sim" -G Xcode \
  "${common_cmake_args[@]}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DIOS=ON \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator

echo "Building iOS simulator static libraries..."
cmake --build "$SRC_DIR/build-ios-sim" --config Release \
  --target llama mtmd ggml ggml-base ggml-cpu ggml-metal ggml-blas \
  -- -quiet

echo "Configuring iOS device build..."
cmake -S "$SRC_DIR" -B "$SRC_DIR/build-ios-device" -G Xcode \
  "${common_cmake_args[@]}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES="arm64" \
  -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos

echo "Building iOS device static libraries..."
cmake --build "$SRC_DIR/build-ios-device" --config Release \
  --target llama mtmd ggml ggml-base ggml-cpu ggml-metal ggml-blas \
  -- -quiet

setup_framework_structure() {
  local build_dir="$1"
  local header_dir="$build_dir/framework/llama.framework/Headers"
  local module_dir="$build_dir/framework/llama.framework/Modules"

  rm -rf "$build_dir/framework"
  mkdir -p "$header_dir" "$module_dir"

  cp "$SRC_DIR/include/llama.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/ggml.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/ggml-opt.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/ggml-alloc.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/ggml-backend.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/ggml-metal.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/ggml-cpu.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/ggml-blas.h" "$header_dir/"
  cp "$SRC_DIR/ggml/include/gguf.h" "$header_dir/"
  cp "$SRC_DIR/tools/mtmd/mtmd.h" "$header_dir/"
  cp "$SRC_DIR/tools/mtmd/mtmd-helper.h" "$header_dir/"

  cat > "$module_dir/module.modulemap" <<'MAP'
framework module llama {
  header "llama.h"
  header "ggml.h"
  header "ggml-opt.h"
  header "ggml-alloc.h"
  header "ggml-backend.h"
  header "ggml-metal.h"
  header "ggml-cpu.h"
  header "ggml-blas.h"
  header "gguf.h"
  header "mtmd.h"
  header "mtmd-helper.h"

  link "c++"
  link framework "Accelerate"
  link framework "Metal"
  link framework "Foundation"

  export *
}
MAP

  cat > "$build_dir/framework/llama.framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>llama</string>
  <key>CFBundleIdentifier</key>
  <string>org.ggml.llama</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>llama</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>MinimumOSVersion</key>
  <string>${IOS_MIN}</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>iPhoneOS</string>
  </array>
  <key>UIDeviceFamily</key>
  <array>
    <integer>1</integer>
    <integer>2</integer>
  </array>
</dict>
</plist>
EOF
}

combine_static_libraries() {
  local build_dir="$1"
  local release_dir="$2"
  local sdk="$3"
  local archs="$4"
  local min_flag="$5"

  local out_lib="$build_dir/framework/llama.framework/llama"
  local temp_dir="$build_dir/temp"
  mkdir -p "$temp_dir"

  local libs=(
    "$build_dir/src/$release_dir/libllama.a"
    "$build_dir/tools/mtmd/$release_dir/libmtmd.a"
    "$build_dir/ggml/src/$release_dir/libggml.a"
    "$build_dir/ggml/src/$release_dir/libggml-base.a"
    "$build_dir/ggml/src/$release_dir/libggml-cpu.a"
    "$build_dir/ggml/src/ggml-metal/$release_dir/libggml-metal.a"
    "$build_dir/ggml/src/ggml-blas/$release_dir/libggml-blas.a"
  )

  xcrun libtool -static -o "$temp_dir/combined.a" "${libs[@]}"

  local arch_flags=()
  for arch in $archs; do
    arch_flags+=("-arch" "$arch")
  done

  xcrun -sdk "$sdk" clang++ -dynamiclib \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    "${arch_flags[@]}" \
    "$min_flag" \
    -Wl,-force_load,"$temp_dir/combined.a" \
    -framework Foundation -framework Metal -framework Accelerate \
    -install_name "@rpath/llama.framework/llama" \
    -o "$out_lib"

  mkdir -p "$build_dir/dSYMs"
  xcrun dsymutil "$out_lib" -o "$build_dir/dSYMs/llama.dSYM"
  xcrun strip -S "$out_lib"

  rm -rf "$temp_dir"
}

setup_framework_structure "$SRC_DIR/build-ios-sim"
setup_framework_structure "$SRC_DIR/build-ios-device"

combine_static_libraries \
  "$SRC_DIR/build-ios-sim" \
  "Release-iphonesimulator" \
  "iphonesimulator" \
  "arm64 x86_64" \
  "-mios-simulator-version-min=${IOS_MIN}"

combine_static_libraries \
  "$SRC_DIR/build-ios-device" \
  "Release-iphoneos" \
  "iphoneos" \
  "arm64" \
  "-mios-version-min=${IOS_MIN}"

echo "Creating iOS-only llama.xcframework with multimodal symbols..."
rm -rf "$OUT_DIR/llama.xcframework"
mkdir -p "$OUT_DIR"

xcrun xcodebuild -create-xcframework \
  -framework "$SRC_DIR/build-ios-sim/framework/llama.framework" \
  -debug-symbols "$SRC_DIR/build-ios-sim/dSYMs/llama.dSYM" \
  -framework "$SRC_DIR/build-ios-device/framework/llama.framework" \
  -debug-symbols "$SRC_DIR/build-ios-device/dSYMs/llama.dSYM" \
  -output "$OUT_DIR/llama.xcframework"

echo "Done. Generated:"
echo "  $OUT_DIR/llama.xcframework"
