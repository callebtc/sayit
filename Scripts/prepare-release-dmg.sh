#!/bin/sh
# Prepare a signed release DMG without notarization or GitHub operations.
set -eu

usage() {
    echo 'Usage: ./Scripts/prepare-release-dmg.sh [--audit] VERSION'
    echo 'Default: build, test, sign, package, and audit. --audit: inspect an existing DMG only.'
}
fail() { echo "DMG preparation failed: $*" >&2; exit 1; }
mode=prepare
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --audit) mode=audit; shift ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
version=$1
printf '%s\n' "$version" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null \
    || fail 'VERSION must be MAJOR.MINOR.PATCH.'
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
build_root="$project_root/Build"
app_root="$build_root/DerivedData-Release/Build/Products/Release/SayIt.app"
dmg_path="$build_root/SayIt-$version.dmg"
expected_team_id=${SAYIT_EXPECTED_TEAM_ID:-D7AHD3GLH6}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$build_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export XDG_CACHE_HOME="$build_root/SwiftPMCache"
release_temp=
mounted=NO
test_metallib=
cleanup() {
    if [ "$mounted" = YES ]; then
        hdiutil detach "$release_temp/mount" >/dev/null 2>&1 || true
    fi
    [ -z "$test_metallib" ] || rm -f "$test_metallib"
    [ -z "$release_temp" ] || rm -rf "$release_temp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_code() {
    code_path=$1
    codesign --verify --strict "$code_path"
    signature=$(codesign --display --verbose=4 "$code_path" 2>&1)
    printf '%s\n' "$signature" | grep -F "TeamIdentifier=$expected_team_id" >/dev/null \
        || fail 'Unexpected signing team.'
    printf '%s\n' "$signature" | grep -F 'Timestamp=' >/dev/null \
        || fail 'Missing secure signing timestamp.'
    if [ "${2:-}" = runtime ]; then
        printf '%s\n' "$signature" | grep -F 'flags=0x10000(runtime)' >/dev/null \
            || fail 'Missing hardened runtime.'
    fi
}

audit_app() {
    audit_root=$1
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$audit_root/Contents/Info.plist")" = "$version" ] \
        || fail 'App version does not match the requested version.'
    build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$audit_root/Contents/Info.plist")
    printf '%s\n' "$build_number" | grep -E '^[1-9][0-9]*$' >/dev/null \
        || fail 'Build number must be a positive integer.'
    codesign --verify --deep --strict "$audit_root"
    for component in '' '/Contents/Library/LaunchServices/SayItAgent.app' \
        '/Contents/Helpers/SayItCLI.app' '/Contents/Helpers/SayItSelectionAgent'; do
        verify_code "$audit_root$component" runtime
    done
    ./Scripts/validate-selection-bundle.sh "$audit_root"
    ./Scripts/validate-package-linkage.sh "$audit_root"
    ./Scripts/validate-updater.sh "$audit_root" "$expected_team_id"
    find "$audit_root" -type f -name '*.dylib' -print | while IFS= read -r library; do
        verify_code "$library"
    done
}

[ -x Build/DMGTools/bin/python3 ] || ./Scripts/setup-dmg-tools.sh
if [ "$mode" = prepare ]; then
    [ ! -e "$dmg_path" ] || fail 'DMG already exists. Inspect it; do not overwrite an existing artifact.'
    [ ! -e "$build_root/Update-$version" ] || fail 'Update assets already exist for this version.'
    test -f .env.release && git check-ignore -q .env.release \
        || fail 'An ignored .env.release is required.'
    # Load configured names for the signing tools; never print the configuration.
    set -a
    . ./.env.release
    set +a
    : "${SAYIT_SIGN_IDENTITY:?Configure SAYIT_SIGN_IDENTITY in .env.release.}"
    [ "$SAYIT_SIGN_IDENTITY" != - ] || fail 'A Developer ID identity is required.'
    security find-identity -v -p codesigning | grep -F "$SAYIT_SIGN_IDENTITY" >/dev/null \
        || fail 'The configured signing identity is unavailable.'
    git diff --check
    ./Scripts/validate-catalog.sh
    SAYIT_DERIVED_DATA_PATH="$build_root/DerivedData-Release" \
    SAYIT_DISABLE_SECURE_TIMESTAMP=NO ./Scripts/build-app.sh
    audit_app "$app_root"

    update_key_file=${SAYIT_UPDATE_KEY_FILE:-$project_root/.env}
    embedded_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_root/Contents/Info.plist")
    derived_key=$(xcrun swift Scripts/update-key.swift public "$update_key_file")
    [ "$embedded_key" = "$derived_key" ] || fail 'The update signing key does not match the app.'

    echo 'Running package, DSP, and muted playback integration tests…'
    mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"
    app_metallib="$app_root/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    [ -f "$app_metallib" ] || fail 'The app Metal library is missing.'
    xcrun swift build --build-tests
    swiftpm_bin_path=$(xcrun swift build --show-bin-path)
    test_executable="$swiftpm_bin_path/SayItPackageTests.xctest/Contents/MacOS/SayItPackageTests"
    [ -x "$test_executable" ] || fail 'The package test executable is missing.'
    test_metallib="$(dirname "$test_executable")/mlx.metallib"
    cp "$app_metallib" "$test_metallib"
    xcrun swift test --disable-sandbox --skip-build
    xcrun swift test --disable-sandbox --package-path Packages/PlaybackDSP -c release
    SAYIT_PLAYBACK_INTEGRATION=1 xcrun swift test --disable-sandbox --skip-build --filter TimeStretchPlaybackTests
    rm -f "$test_metallib"
    test_metallib=
    SAYIT_APP_PATH="$app_root" ./Scripts/smoke-test-selection-xpc.sh

    SAYIT_APP_PATH="$app_root" \
    SAYIT_DISABLE_SECURE_TIMESTAMP=NO \
    SAYIT_DMG_SIGN_IDENTITY="$SAYIT_SIGN_IDENTITY" \
    SAYIT_LOCAL_DMG_PATH="$dmg_path" ./Scripts/package-local-dmg.sh
fi

[ -f "$dmg_path" ] || fail 'The requested DMG does not exist.'
verify_code "$dmg_path"
hdiutil verify "$dmg_path"
release_temp=$(mktemp -d "${TMPDIR:-/tmp}/sayit-dmg-audit.XXXXXX")
# Reuse a read-only mount of this exact image without closing the user's window.
hdiutil info -plist > "$release_temp/mounts.plist"
audit_mount=$(Build/DMGTools/bin/python3 - "$dmg_path" "$release_temp/mounts.plist" <<'PYTHON'
from pathlib import Path
import plistlib
import sys
image_path = Path(sys.argv[1]).resolve()
with open(sys.argv[2], "rb") as stream:
    images = plistlib.load(stream)["images"]
for image in images:
    if Path(image.get("image-path", "")).resolve() != image_path:
        continue
    if image.get("writeable") is not False or image.get("shadow-path"):
        raise SystemExit("The existing image mount must be read-only without a shadow file.")
    mounts = [item["mount-point"] for item in image.get("system-entities", [])
              if "mount-point" in item]
    if len(mounts) > 1:
        raise SystemExit("The release image has unexpected multiple mounted volumes.")
    if mounts:
        print(mounts[0])
        break
PYTHON
)
if [ -z "$audit_mount" ]; then
    audit_mount="$release_temp/mount"
    mkdir "$audit_mount"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$audit_mount" "$dmg_path" >/dev/null
    mounted=YES
fi
./Scripts/dmg-layout.sh validate "$audit_mount"
Build/DMGTools/bin/python3 Scripts/test-dmg-layout.py "$audit_mount"
item_count=$(find "$audit_mount" -mindepth 1 -maxdepth 1 \
    ! -name .DS_Store ! -name .background | wc -l | tr -d ' ')
[ "$item_count" = 2 ] || fail 'Unexpected top-level DMG contents.'
audit_app "$audit_mount/Say It.app"
# Do not traverse the Applications symlink or include local paths in diagnostics.
if find "$audit_mount/Say It.app" -type f -exec grep -a -E -l \
    '/Users/|file:///Users/|/home/|file:///home/' {} + | grep -q .; then
    fail 'The mounted app contains a local user path.'
fi
if [ "$mounted" = YES ]; then
    hdiutil detach "$audit_mount" >/dev/null
    mounted=NO
fi
checksum=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
if [ "$mode" = prepare ]; then
    printf '%s  %s\n' "$checksum" "SayIt-$version.dmg" > "$build_root/release-$version.sha256"
fi
printf '\nPrepared: Say It %s (build %s)\nDMG: %s\nSHA-256: %s\n' "$version" "$build_number" "$dmg_path" "$checksum"
echo 'Automated DMG signature, contents, and installer layout checks passed.'
echo 'No notarization, stapling, or GitHub upload was performed.'
