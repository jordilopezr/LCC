#!/bin/bash
#
# Xcode "Run Script" build phase: compiles the Rust crate in ../native for every
# architecture Xcode is building (ARCHS), merges them with lipo, and installs the
# result into the app as Contents/Frameworks/native.framework.
#
# flutter_rust_bridge looks for `native.framework/native` on macOS when the app
# is packaged (see kDefaultExternalLibraryLoaderConfig, stem 'native'), so this
# needs no change on the Dart side. The macOS counterpart of the Rust section of
# linux/CMakeLists.txt.

set -euo pipefail

# Xcode runs build phases with a minimal PATH that does not include rustup.
if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
fi
command -v cargo >/dev/null || { echo "error: cargo not found. Install Rust: https://rustup.rs" >&2; exit 1; }

RUST_DIR="${PROJECT_DIR}/../native"
FRAMEWORK_NAME="native"

if [ "${CONFIGURATION}" = "Debug" ]; then
    PROFILE="debug"; CARGO_PROFILE_ARGS=()
else
    PROFILE="release"; CARGO_PROFILE_ARGS=(--release)
fi

# Match the app's minimum macOS, otherwise the linker warns that the dylib was
# built for a newer macOS than the app and dyld may refuse it on older systems.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"

# The C parts (ring, OpenSSL, libssh2) are compiled with Xcode's clang, which
# needs SDKROOT to find the system headers. Pin it to the macOS SDK explicitly.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

LIBS=()
for ARCH in ${ARCHS}; do
    case "$ARCH" in
        arm64)  TRIPLE="aarch64-apple-darwin" ;;
        x86_64) TRIPLE="x86_64-apple-darwin" ;;
        *) echo "error: unsupported arch $ARCH" >&2; exit 1 ;;
    esac
    rustup target list --installed | grep -qx "$TRIPLE" || rustup target add "$TRIPLE"

    echo "Building Rust ($PROFILE) for $TRIPLE..."
    (cd "$RUST_DIR" && cargo build --lib --target "$TRIPLE" ${CARGO_PROFILE_ARGS[@]+"${CARGO_PROFILE_ARGS[@]}"})
    LIBS+=("$RUST_DIR/target/$TRIPLE/$PROFILE/libnative.dylib")
done

FW_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/${FRAMEWORK_NAME}.framework"
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR/Versions/A/Resources"

BIN="$FW_DIR/Versions/A/$FRAMEWORK_NAME"
lipo -create "${LIBS[@]}" -output "$BIN"
install_name_tool -id "@rpath/${FRAMEWORK_NAME}.framework/Versions/A/${FRAMEWORK_NAME}" "$BIN"

cat > "$FW_DIR/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>${PRODUCT_BUNDLE_IDENTIFIER}.${FRAMEWORK_NAME}</string>
    <key>CFBundleName</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>${MACOSX_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
PLIST

ln -sfh A "$FW_DIR/Versions/Current"
ln -sfh "Versions/Current/$FRAMEWORK_NAME" "$FW_DIR/$FRAMEWORK_NAME"
ln -sfh "Versions/Current/Resources" "$FW_DIR/Resources"

# The app's own CodeSign step does not re-sign nested frameworks that were not
# copied by an Embed phase, so sign it here (ad-hoc when signing is disabled).
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -z "$SIGN_ID" ] && SIGN_ID="-"
codesign --force --sign "$SIGN_ID" --timestamp=none "$FW_DIR/Versions/A"

echo "Installed $(lipo -archs "$BIN") into $FW_DIR"
