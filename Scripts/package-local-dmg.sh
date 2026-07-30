#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/Build"
app_root="${SAYIT_APP_PATH:-$build_root/DerivedData/Build/Products/Release/SayIt.app}"
dmg_sign_identity="${SAYIT_DMG_SIGN_IDENTITY:-}"
disable_secure_timestamp="${SAYIT_DISABLE_SECURE_TIMESTAMP:-NO}"

case "$disable_secure_timestamp" in
    YES|NO) ;;
    *)
        echo "SAYIT_DISABLE_SECURE_TIMESTAMP must be YES or NO." >&2
        exit 2
        ;;
esac

if [ ! -x "$app_root/Contents/MacOS/SayIt" ]; then
    "$project_root/Scripts/build-app.sh"
fi

version=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$app_root/Contents/Info.plist"
)
dmg_path="${SAYIT_LOCAL_DMG_PATH:-$build_root/SayIt-$version-local.dmg}"

staging=$(mktemp -d "${TMPDIR:-/tmp}/sayit-local-dmg.XXXXXX")
cleanup() {
    rm -rf "$staging"
}
trap cleanup EXIT

ditto \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$app_root" \
    "$staging/Say It.app"
ln -s /Applications "$staging/Applications"
xattr -cr "$staging"

COPYFILE_DISABLE=1 hdiutil create \
    -volname "Say It" \
    -srcfolder "$staging" \
    -format UDZO \
    -ov \
    "$dmg_path"

if [ -n "$dmg_sign_identity" ]; then
    code_sign_flags=
    if [ "$disable_secure_timestamp" = "YES" ]; then
        code_sign_flags=--timestamp=none
    fi

    codesign \
        --force \
        --sign "$dmg_sign_identity" \
        ${code_sign_flags} \
        "$dmg_path"
    codesign --verify --verbose=2 "$dmg_path"
fi

hdiutil verify "$dmg_path"

echo "$dmg_path"
