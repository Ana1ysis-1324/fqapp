#!/usr/bin/env bash
# Builds the Rust native core (rust/ -> libfqapi_core.a) for iOS and stages
# it + the flutter_rust_bridge C header next to the Flutter Runner so Xcode
# can statically link it. Designed to run on the GitHub macOS runner.
#
# Order of operations on CI (see .github/workflows/ios-build.yml):
#   1. flutter create --platforms=ios .        (produces ios/Runner)
#   2. flutter_rust_bridge_codegen generate    (writes ios/Runner/frb_generated.h)
#   3. ./scripts/build_rust_backend_ios.sh     (this script: compiles Rust)
#   4. ./scripts/patch_ios.sh                  (links .a + header into Runner)
#
# Usage:
#   ./scripts/build_rust_backend_ios.sh
#   ./scripts/build_rust_backend_ios.sh --skip-codegen
#   ./scripts/build_rust_backend_ios.sh --profile=debug
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$APP_DIR/rust"
RUNNER_DIR="$APP_DIR/ios/Runner"
MANIFEST="$RUST_DIR/Cargo.toml"

PROFILE=release
SKIP_CODEGEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-codegen) SKIP_CODEGEN=1 ;;
    --profile=*)    PROFILE="${1#--profile=}" ;;
    --profile)
      shift
      case "${1:-}" in release|debug) PROFILE="$1" ;; *) echo "bad --profile" >&2; exit 2 ;; esac
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f "$MANIFEST" ]; then
  echo "错误：找不到 Rust 核心清单 $MANIFEST" >&2
  exit 1
fi

# 1) (Re)generate FRB bindings if requested. The CI workflow runs codegen in a
#    dedicated step before this script, so it usually passes --skip-codegen.
if [ "$SKIP_CODEGEN" -eq 0 ]; then
  if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    ( cd "$APP_DIR" && flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml )
  else
    echo "警告：未找到 flutter_rust_bridge_codegen，跳过 codegen（依赖 CI 步骤已完成）。" >&2
  fi
fi

# 2) Ensure the iOS targets are installed.
rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

PROFILE_ARGS=()
[ "$PROFILE" = "release" ] && PROFILE_ARGS=(--release)

# 3) Cross-compile the static library for device (and simulator).
echo "==> cargo build --target aarch64-apple-ios ($PROFILE)"
( cd "$APP_DIR" && cargo build --locked --manifest-path "$MANIFEST" --target aarch64-apple-ios "${PROFILE_ARGS[@]}" )
echo "==> cargo build --target aarch64-apple-ios-sim ($PROFILE)"
( cd "$APP_DIR" && cargo build --locked --manifest-path "$MANIFEST" --target aarch64-apple-ios-sim "${PROFILE_ARGS[@]}" ) || \
  echo "警告：模拟器静态库编译失败，仅使用设备库（不影响真机 IPA）。" >&2

DEV_LIB="$RUST_DIR/target/aarch64-apple-ios/$PROFILE/libfqapi_core.a"
SIM_LIB="$RUST_DIR/target/aarch64-apple-ios-sim/$PROFILE/libfqapi_core.a"
if [ ! -s "$DEV_LIB" ]; then
  echo "错误：Rust 交叉编译未产出 $DEV_LIB" >&2
  exit 1
fi

mkdir -p "$RUNNER_DIR"

# 4) Stage the static lib for Xcode (kept as fallback artifact only).
cp -f "$DEV_LIB" "$RUNNER_DIR/libfqapi_core.a"
echo "==> staged $RUNNER_DIR/libfqapi_core.a"

# 4b) Bundle the cdylib as a dynamic framework. This is what actually ships:
#     the FRB Dart loader on iOS dlopens '<stem>.framework/<stem>' first
#     (fqapi_core.framework/fqapi_core), resolving via Runner's
#     LC_RPATH=@executable_path/Frameworks once embedded.
DEV_DYLIB="$RUST_DIR/target/aarch64-apple-ios/$PROFILE/libfqapi_core.dylib"
FW_DIR="$RUNNER_DIR/fqapi_core.framework"
if [ ! -s "$DEV_DYLIB" ]; then
  echo "错误：未找到 cdylib $DEV_DYLIB，Dart FFI 将无法加载 Rust 核心。" >&2
  exit 1
fi
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR"
cp -f "$DEV_DYLIB" "$FW_DIR/fqapi_core"
install_name_tool -id "@rpath/fqapi_core.framework/fqapi_core" "$FW_DIR/fqapi_core"
codesign --force --sign - "$FW_DIR/fqapi_core" 2>/dev/null || true
cat > "$FW_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>fqapi_core</string>
  <key>CFBundleIdentifier</key><string>com.fqapp.fqapiCore</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>fqapi_core</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>12.0</string>
</dict>
</plist>
PLIST
echo "==> bundled $FW_DIR"

# 5) Copy the FRB-generated C header next to the Runner (codegen wrote it here).
for cand in "$APP_DIR/ios/Runner/frb_generated.h" "$APP_DIR/ios/frb_generated.h" "$APP_DIR/rust/frb_generated.h"; do
  if [ -f "$cand" ] && [ "$cand" != "$RUNNER_DIR/frb_generated.h" ]; then
    cp -f "$cand" "$RUNNER_DIR/frb_generated.h"
    echo "==> staged $RUNNER_DIR/frb_generated.h (from $cand)"
    break
  fi
done
if [ ! -f "$RUNNER_DIR/frb_generated.h" ]; then
  echo "错误：未找到 frb_generated.h，请确认 flutter_rust_bridge_codegen 已运行且 yaml 配置了 c_output。" >&2
  exit 1
fi

echo "iOS Rust 核心编译完成。"
