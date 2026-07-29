#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/Build"
app_root="$build_root/DerivedData/Build/Products/Release/SayIt.app"
version=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$project_root/Config/Info.plist"
)
dmg_path="$build_root/SayIt-$version.dmg"

: "${SAYIT_SIGN_IDENTITY:?Set SAYIT_SIGN_IDENTITY to a Developer ID Application identity.}"
: "${SAYIT_NOTARY_PROFILE:?Set SAYIT_NOTARY_PROFILE to a notarytool Keychain profile.}"

"$project_root/Scripts/build-app.sh"

staging=$(mktemp -d "${TMPDIR:-/tmp}/sayit-release.XXXXXX")
cleanup() {
    rm -rf "$staging"
}
trap cleanup EXIT

ditto "$app_root" "$staging/Say It.app"
hdiutil create \
    -volname "Say It" \
    -srcfolder "$staging" \
    -format UDZO \
    -ov \
    "$dmg_path"
codesign --force --sign "$SAYIT_SIGN_IDENTITY" --timestamp "$dmg_path"
xcrun notarytool submit \
    "$dmg_path" \
    --keychain-profile "$SAYIT_NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

echo "$dmg_path"
