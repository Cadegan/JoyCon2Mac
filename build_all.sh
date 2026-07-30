#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [ -z "${DEVELOPER_DIR:-}" ] &&
   [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Apple requires the dext filename to equal its CFBundleIdentifier. sysextd
# walks Contents/Library/SystemExtensions/ and pattern-matches the bundle id
# against the file name, not against the Info.plist. Mismatches fail
# activation with "Extension not found in App bundle" even if the bundle
# itself is fine.
DEXT_NAME="local.joycon2mac.driver.dext"
SYSTEM_EXTENSIONS_DIR="$ROOT_DIR/build/JoyCon2Mac.app/Contents/Library/SystemExtensions"
PREBUILT_DEXT="$ROOT_DIR/build/xcode/Release/$DEXT_NAME"
LEGACY_DEXT="$ROOT_DIR/build/xcode/Release/VirtualJoyConDriver.dext"
APP_DIR="$ROOT_DIR/build/JoyCon2Mac.app"
HELPER_APP="$APP_DIR/Contents/Resources/JoyCon2MacDaemon.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/JoyCon2Mac"
HELPER_EXECUTABLE="$HELPER_APP/Contents/MacOS/joycon2mac"
EMBEDDED_DEXT="$SYSTEM_EXTENSIONS_DIR/$DEXT_NAME"
APP_ENTITLEMENTS="$ROOT_DIR/JoyCon2MacApp/JoyCon2Mac.entitlements"

require_build_environment() {
    if ! command -v cmake >/dev/null 2>&1; then
        echo "CMake is required. Install it before running build_all.sh." >&2
        return 1
    fi
    if ! xcodebuild -license check >/dev/null 2>&1; then
        echo "The Xcode license is not accepted. Run:" >&2
        echo "  sudo xcodebuild -license accept" >&2
        return 1
    fi
    if ! xcrun --sdk driverkit --show-sdk-path >/dev/null 2>&1; then
        echo "The DriverKit SDK is unavailable from the selected Xcode." >&2
        return 1
    fi
}

require_build_environment

# Build the daemon + GUI first.
"$ROOT_DIR/build_gui.sh"

embed_dext() {
    local source="$1"
    if [ ! -d "$source" ]; then
        return 1
    fi
    if [ ! -d "$ROOT_DIR/build/JoyCon2Mac.app" ]; then
        return 1
    fi
    mkdir -p "$SYSTEM_EXTENSIONS_DIR"
    # Remove any previous naming variants so we never ship with two side-by-
    # side bundles that could confuse sysextd.
    /bin/rm -rf "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
    /bin/rm -rf "$SYSTEM_EXTENSIONS_DIR/$DEXT_NAME"
    cp -R "$source" "$SYSTEM_EXTENSIONS_DIR/$DEXT_NAME"
    # The dext is already signed by build_driver.sh. Re-sign only the outer
    # app so the nested DriverKit entitlements are not replaced by the app's
    # com.apple.developer.system-extension.install entitlement.
    codesign -s "$SIGN_IDENTITY" -f --generate-entitlement-der \
        --entitlements "$APP_ENTITLEMENTS" "$APP_DIR" >/dev/null
}

bundle_identifier() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null
}

bundle_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist" 2>/dev/null
}

has_entitlement() {
    local bundle="$1"
    local entitlement="$2"
    codesign -d --entitlements :- "$bundle" 2>/dev/null |
        /usr/bin/grep -Fq "<key>$entitlement</key>"
}

preflight_bundle() {
    local failed=0

    echo
    echo "Hardware-test preflight..."

    if [ -d "$APP_DIR" ] && [ -x "$APP_EXECUTABLE" ]; then
        echo "App             OK"
    else
        echo "App             FAILED: bundle or executable missing" >&2
        failed=1
    fi

    if [ -d "$HELPER_APP" ] && [ -x "$HELPER_EXECUTABLE" ] &&
       [ "$(bundle_identifier "$HELPER_APP")" = "local.joycon2mac.daemon" ]; then
        echo "Daemon helper   OK"
    else
        echo "Daemon helper   FAILED: helper missing or bundle identifier mismatch" >&2
        failed=1
    fi

    if [ -d "$EMBEDDED_DEXT" ] &&
       [ "$(bundle_identifier "$EMBEDDED_DEXT")" = "local.joycon2mac.driver" ] &&
       [ ! -e "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext" ]; then
        echo "DriverKit dext  OK"
    else
        echo "DriverKit dext  FAILED: missing, misnamed, or stale legacy copy present" >&2
        failed=1
    fi

    if [ -n "$(bundle_version "$APP_DIR")" ] &&
       [ -n "$(bundle_version "$HELPER_APP")" ] &&
       [ -n "$(bundle_version "$EMBEDDED_DEXT")" ]; then
        echo "Bundle versions OK"
    else
        echo "Bundle versions FAILED: a CFBundleVersion is missing" >&2
        failed=1
    fi

    if codesign --verify --strict --verbose=2 "$EMBEDDED_DEXT" >/dev/null 2>&1 &&
       codesign --verify --strict --verbose=2 "$HELPER_APP" >/dev/null 2>&1 &&
       codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1; then
        echo "Signatures      OK"
    else
        echo "Signatures      FAILED: codesign verification failed" >&2
        failed=1
    fi

    if has_entitlement "$EMBEDDED_DEXT" "com.apple.developer.driverkit" &&
       has_entitlement "$EMBEDDED_DEXT" "com.apple.developer.driverkit.family.hid.device" &&
       has_entitlement "$EMBEDDED_DEXT" "com.apple.developer.driverkit.transport.hid" &&
       has_entitlement "$EMBEDDED_DEXT" "com.apple.developer.driverkit.allow-any-userclient-access" &&
       has_entitlement "$APP_DIR" "com.apple.developer.system-extension.install" &&
       ! has_entitlement "$APP_DIR" "com.apple.developer.driverkit"; then
        echo "Entitlements    OK"
    else
        echo "Entitlements    FAILED: app/DriverKit entitlements are missing or mixed" >&2
        failed=1
    fi

    if /usr/bin/otool -L "$APP_EXECUTABLE" |
       /usr/bin/grep -Fq "ServiceManagement.framework"; then
        echo "Login framework OK"
    else
        echo "Login framework FAILED: ServiceManagement is not linked" >&2
        failed=1
    fi

    if [ "$SIGN_IDENTITY" = "-" ]; then
        local sip_status
        sip_status="$(/usr/bin/csrutil status 2>/dev/null || true)"
        if printf '%s\n' "$sip_status" |
           /usr/bin/grep -Eq 'System Integrity Protection status: disabled[.]?'; then
            echo "Ad hoc/SIP mode  OK"
        else
            echo "Ad hoc/SIP mode  FAILED: an ad hoc DriverKit build requires SIP disabled on this isolated development Mac." >&2
            echo "Use a valid Apple development identity/provisioning setup, or disable SIP only for local testing." >&2
            failed=1
        fi
    else
        echo "Signing identity OK ($SIGN_IDENTITY)"
    fi

    if [ "$failed" -ne 0 ]; then
        echo "Not ready for hardware test." >&2
        return 1
    fi

    echo "Ready for hardware test"
}

# If we already have a pre-built dext around, embed it immediately so
# build_all.sh never leaves the .app without its dext.
if embed_dext "$PREBUILT_DEXT"; then
    echo "Embedded pre-built DriverKit extension in JoyCon2Mac.app/Contents/Library/SystemExtensions."
elif embed_dext "$LEGACY_DEXT"; then
    echo "Embedded legacy-named pre-built DriverKit extension (will be rebuilt under the correct name)."
fi

echo
echo "Attempting DriverKit build..."
if "$ROOT_DIR/build_driver.sh"; then
    echo "DriverKit extension built."
    # Clean out any stale copies in Resources/ from older builds.
    /bin/rm -rf "$ROOT_DIR/build/JoyCon2Mac.app/Contents/Resources/VirtualJoyConDriver.dext" 2>/dev/null || true
    if embed_dext "$PREBUILT_DEXT"; then
        echo "Embedded freshly-built DriverKit extension in JoyCon2Mac.app/Contents/Library/SystemExtensions."
    fi
else
    echo "DriverKit build failed. The daemon and GUI app are still built."
    echo "Check build/xcode logs for DriverKit/iig diagnostics."
    if [ -d "$SYSTEM_EXTENSIONS_DIR/$DEXT_NAME" ]; then
        echo "(The pre-built dext embedded above is still in the bundle.)"
    else
        echo "No usable DriverKit extension is embedded; aborting hardware-test build." >&2
        exit 1
    fi
fi

preflight_bundle
