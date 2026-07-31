#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/Build"
app_root="$build_root/DerivedData/Build/Products/Release/SayIt.app"
module_cache="$build_root/ModuleCache"
swiftpm_cache="$build_root/SwiftPMCache"
local_config="$project_root/.env.release"
expected_team_id="${SAYIT_EXPECTED_TEAM_ID:-D7AHD3GLH6}"
allow_notarization_upload="${SAYIT_ALLOW_NOTARIZATION_UPLOAD:-NO}"
allow_dirty_worktree="${SAYIT_ALLOW_DIRTY_WORKTREE:-NO}"
skip_tests="${SAYIT_SKIP_TESTS:-NO}"

usage() {
    cat <<'EOF'
Usage: SAYIT_ALLOW_NOTARIZATION_UPLOAD=YES ./Scripts/release.sh VERSION

Builds, signs, notarizes, staples, mounts, and audits a release DMG. This
uploads only to Apple's notarization service; it never publishes to GitHub.

One-time configuration may be stored in .env.release:
  SAYIT_SIGN_IDENTITY='Developer ID Application identity or SHA-1 fingerprint'
  SAYIT_NOTARY_PROFILE='notarytool Keychain profile name'
  SAYIT_UPDATE_API_URL='GitHub latest-release API URL'
EOF
}

fail() {
    echo "Release failed: $*" >&2
    exit 1
}

verify_timestamped_code() {
    code_path=$1
    code_label=$2

    [ -e "$code_path" ] || fail "$code_label is missing."
    codesign --verify --strict --verbose=2 "$code_path"

    code_signature=$(
        codesign --display --verbose=4 "$code_path" 2>&1
    )
    printf '%s\n' "$code_signature" \
        | grep -F "TeamIdentifier=$expected_team_id" >/dev/null \
        || fail "$code_label is not signed by the expected team."
    printf '%s\n' "$code_signature" | grep -F "Timestamp=" >/dev/null \
        || fail "$code_label is missing a secure signing timestamp."
}

verify_release_code() {
    verify_timestamped_code "$1" "$2"
    printf '%s\n' "$code_signature" | grep -F "flags=0x10000(runtime)" >/dev/null \
        || fail "$code_label does not have hardened runtime enabled."
}

case "$allow_dirty_worktree" in
    YES|NO) ;;
    *) fail "SAYIT_ALLOW_DIRTY_WORKTREE must be YES or NO." ;;
esac

case "$skip_tests" in
    YES|NO) ;;
    *) fail "SAYIT_SKIP_TESTS must be YES or NO." ;;
esac

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

expected_version=$1
case "$expected_version" in
    ''|*[!0-9A-Za-z.+-]*|.*|*..*)
        fail "VERSION must be a filename-safe release version."
        ;;
esac

if [ -f "$local_config" ]; then
    # This file is gitignored. Keep notarization credentials in Keychain;
    # only non-secret identity/profile names belong here.
    set -a
    # shellcheck disable=SC1090
    . "$local_config"
    set +a
fi

: "${SAYIT_SIGN_IDENTITY:?Set SAYIT_SIGN_IDENTITY in .env.release or the environment.}"
: "${SAYIT_NOTARY_PROFILE:?Set SAYIT_NOTARY_PROFILE in .env.release or the environment.}"
: "${SAYIT_UPDATE_API_URL:?Set SAYIT_UPDATE_API_URL in .env.release or the environment.}"

if [ "$allow_notarization_upload" != "YES" ]; then
    echo "Apple notarization upload was not explicitly approved." >&2
    exit 2
fi

for command_name in codesign git hdiutil security shasum swift xcodegen xcrun; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done

if [ "$allow_dirty_worktree" != "YES" ] \
    && [ -n "$(git -C "$project_root" status --porcelain --untracked-files=all)" ]; then
    fail "the Git worktree is not clean. Commit the release state first."
fi

security find-identity -v -p codesigning \
    | grep -F "$SAYIT_SIGN_IDENTITY" >/dev/null \
    || fail "the configured Developer ID Application identity is unavailable."

echo "Checking the notarization Keychain profile…"
xcrun notarytool history \
    --keychain-profile "$SAYIT_NOTARY_PROFILE" \
    --output-format json >/dev/null

if [ "$skip_tests" = "NO" ]; then
    echo "Running tests…"
    mkdir -p "$module_cache" "$swiftpm_cache"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    XDG_CACHE_HOME="$swiftpm_cache" \
        xcrun swift test --disable-sandbox
else
    echo "Skipping tests because SAYIT_SKIP_TESTS=YES."
fi

echo "Building the signed release app…"
SAYIT_DISABLE_SECURE_TIMESTAMP=NO \
SAYIT_SIGN_IDENTITY="$SAYIT_SIGN_IDENTITY" \
SAYIT_UPDATE_API_URL="$SAYIT_UPDATE_API_URL" \
    "$project_root/Scripts/build-app.sh"

version=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$app_root/Contents/Info.plist"
)
build_number=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleVersion" \
        "$app_root/Contents/Info.plist"
)

[ "$version" = "$expected_version" ] \
    || fail "built version $version does not match requested version $expected_version."

case "$build_number" in
    ''|*[!0-9]*) fail "CFBundleVersion must be a positive integer." ;;
    0) fail "CFBundleVersion must be greater than zero." ;;
esac

dmg_path="$build_root/SayIt-$version.dmg"

release_temp=$(mktemp -d "${TMPDIR:-/tmp}/sayit-release.XXXXXX")
mountpoint="$release_temp/mount"
notary_result="$release_temp/notary-result.json"
mounted=NO

cleanup() {
    if [ "$mounted" = "YES" ]; then
        hdiutil detach "$mountpoint" >/dev/null 2>&1 || true
    fi
    rm -rf "$release_temp"
}
trap cleanup EXIT

echo "Packaging and signing the DMG…"
SAYIT_APP_PATH="$app_root" \
SAYIT_DISABLE_SECURE_TIMESTAMP=NO \
SAYIT_DMG_SIGN_IDENTITY="$SAYIT_SIGN_IDENTITY" \
SAYIT_LOCAL_DMG_PATH="$dmg_path" \
    "$project_root/Scripts/package-local-dmg.sh"

codesign --verify --deep --strict --verbose=2 "$app_root"
verify_release_code "$app_root" "the app"
verify_release_code \
    "$app_root/Contents/Library/LaunchServices/SayItAgent.app" \
    "the background service"
verify_release_code \
    "$app_root/Contents/Helpers/SayItCLI.app" \
    "the CLI"
verify_release_code \
    "$app_root/Contents/Library/LaunchServices/SayItSelectionAgent" \
    "the selection helper"

find "$app_root" -type f -name '*.dylib' -print \
    | while IFS= read -r dylib_path; do
        verify_timestamped_code "$dylib_path" "an embedded dynamic library"
    done

dmg_signature=$(
    codesign --display --verbose=4 "$dmg_path" 2>&1
)
printf '%s\n' "$dmg_signature" | grep -F "TeamIdentifier=$expected_team_id" >/dev/null \
    || fail "the DMG is not signed by the expected team."
printf '%s\n' "$dmg_signature" | grep -F "Timestamp=" >/dev/null \
    || fail "the DMG is missing a secure signing timestamp."

echo "Submitting the DMG to Apple for notarization…"
if ! xcrun notarytool submit \
        "$dmg_path" \
        --keychain-profile "$SAYIT_NOTARY_PROFILE" \
        --wait \
        --output-format json >"$notary_result"; then
    if [ -s "$notary_result" ]; then
        failed_notary_id=$(
            /usr/bin/plutil -extract id raw -o - "$notary_result" \
                2>/dev/null \
                || printf 'unknown'
        )
        fail "Apple notarization failed (submission $failed_notary_id)."
    fi
    fail "Apple notarization failed before returning a submission ID."
fi

notary_status=$(
    /usr/bin/plutil -extract status raw -o - "$notary_result"
)
notary_id=$(
    /usr/bin/plutil -extract id raw -o - "$notary_result"
)
[ "$notary_status" = "Accepted" ] \
    || fail "Apple notarization status was $notary_status (submission $notary_id)."

echo "Stapling and validating Apple's notarization ticket…"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

echo "Mounting and auditing the final DMG…"
mkdir "$mountpoint"
hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$mountpoint" \
    "$dmg_path" >/dev/null
mounted=YES

mounted_app="$mountpoint/Say It.app"
[ -d "$mounted_app" ] || fail "Say It.app is missing from the DMG."
[ -L "$mountpoint/Applications" ] || fail "the Applications symlink is missing."
[ "$(readlink "$mountpoint/Applications")" = "/Applications" ] \
    || fail "the Applications symlink has an unexpected target."

top_level_count=$(
    find "$mountpoint" -mindepth 1 -maxdepth 1 \
        ! -name '.DS_Store' \
        | wc -l \
        | tr -d ' '
)
[ "$top_level_count" = "2" ] \
    || fail "the DMG contains unexpected top-level items."

codesign --verify --deep --strict --verbose=2 "$mounted_app"
verify_release_code "$mounted_app" "the mounted app"
verify_release_code \
    "$mounted_app/Contents/Library/LaunchServices/SayItAgent.app" \
    "the mounted background service"
verify_release_code \
    "$mounted_app/Contents/Helpers/SayItCLI.app" \
    "the mounted CLI"
verify_release_code \
    "$mounted_app/Contents/Library/LaunchServices/SayItSelectionAgent" \
    "the mounted selection helper"

find "$mounted_app" -type f -name '*.dylib' -print \
    | while IFS= read -r dylib_path; do
        verify_timestamped_code "$dylib_path" \
            "a mounted embedded dynamic library"
    done

# Check regular files only so the /Applications symlink is never traversed.
if find "$mounted_app" -type f -exec grep -a -E -l \
    '/Users/|file:///Users/|/home/|file:///home/' {} + \
    | grep -q .; then
    fail "the mounted app contains a local user path."
fi

hdiutil detach "$mountpoint" >/dev/null
mounted=NO
hdiutil verify "$dmg_path"

checksum=$(
    shasum -a 256 "$dmg_path" | awk '{print $1}'
)

cat <<EOF

Release artifact ready:
  Version: $version ($build_number)
  DMG: $dmg_path
  SHA-256: $checksum
  Notarization submission: $notary_id

No GitHub upload was performed.
EOF
