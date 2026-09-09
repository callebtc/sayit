#!/bin/sh
# One release entrypoint; all build and DMG checks live in the preparation helper.
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
allow_upload=${SAYIT_ALLOW_NOTARIZATION_UPLOAD:-NO}
mode=release
usage() {
    cat <<'USAGE'
Usage:
  SAYIT_ALLOW_NOTARIZATION_UPLOAD=YES ./Scripts/release.sh VERSION
  ./Scripts/release.sh --prepare VERSION
  ./Scripts/release.sh --audit VERSION
  SAYIT_ALLOW_NOTARIZATION_UPLOAD=YES ./Scripts/release.sh --notarize-existing VERSION SHA256

Default: build, test, sign, package, audit, notarize, staple, and prepare updates.
--prepare stops after generating and validating the signed DMG; no upload.
--audit checks an existing DMG without modifying it.
--notarize-existing resumes from an exact checksum without rebuilding.
No visual review is required. GitHub publication is separate.
USAGE
}
fail() { echo "Release failed: $*" >&2; exit 1; }
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --prepare) mode=prepare; shift ;;
    --audit) mode=audit; shift ;;
    --notarize-existing) mode=existing; shift ;;
esac
if [ "$mode" = existing ]; then
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    expected_checksum=$2
    printf '%s\n' "$expected_checksum" | grep -E '^[0-9a-f]{64}$' >/dev/null \
        || fail 'SHA256 must be a lowercase 64-character digest.'
else
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
fi
version=$1
printf '%s\n' "$version" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null \
    || fail 'VERSION must be MAJOR.MINOR.PATCH.'
case "$mode" in
    prepare) exec "$project_root/Scripts/prepare-release-dmg.sh" "$version" ;;
    audit) exec "$project_root/Scripts/prepare-release-dmg.sh" --audit "$version" ;;
esac
[ "$allow_upload" = YES ] || fail 'Apple notarization upload was not authorized. Use --prepare for a local DMG.'
build_root="$project_root/Build"
dmg_path="$build_root/SayIt-$version.dmg"
app_root="$build_root/DerivedData-Release/Build/Products/Release/SayIt.app"
update_output="$build_root/Update-$version"
notary_result="$build_root/notarization-$version.json"
[ ! -e "$update_output" ] || fail 'Update assets already exist; inspect them before retrying.'
[ ! -e "$notary_result" ] || fail 'A submission record already exists; inspect its status before retrying.'
if [ "$mode" = release ]; then
    [ -z "$(git status --porcelain --untracked-files=all)" ] \
        || fail 'Commit the prepared release source before running the full release.'
    [ ! -e "$dmg_path" ] || fail 'DMG already exists. Use --notarize-existing with its recorded checksum to resume.'
else
    [ -f "$dmg_path" ] || fail 'The requested DMG does not exist.'
    actual_checksum=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
    [ "$actual_checksum" = "$expected_checksum" ] || fail 'The DMG checksum differs from the expected artifact.'
fi

test -f .env.release && git check-ignore -q .env.release \
    || fail 'An ignored .env.release is required.'
set -a
. ./.env.release
set +a
: "${SAYIT_NOTARY_PROFILE:?Configure SAYIT_NOTARY_PROFILE in .env.release.}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo 'Checking notarization credentials…'
xcrun notarytool history --keychain-profile "$SAYIT_NOTARY_PROFILE" --output-format json >/dev/null
if [ "$mode" = release ]; then
    "$project_root/Scripts/prepare-release-dmg.sh" "$version"
    [ -z "$(git status --porcelain --untracked-files=all)" ] \
        || fail 'Source changed during preparation; inspect it before submission.'
else
    "$project_root/Scripts/prepare-release-dmg.sh" --audit "$version"
fi
checksum=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
if [ "$mode" = existing ]; then
    [ "$checksum" = "$expected_checksum" ] || fail 'The DMG changed during validation.'
fi
printf '%s  %s\n' "$checksum" "SayIt-$version.dmg" > "$build_root/release-$version-pre-notarization.sha256"

echo 'Submitting the validated DMG to Apple…'
if ! xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$SAYIT_NOTARY_PROFILE" --wait --output-format json > "$notary_result"; then
    fail 'Notarization submission failed. Inspect the saved result before retrying.'
fi
notary_status=$(/usr/bin/plutil -extract status raw -o - "$notary_result")
notary_id=$(/usr/bin/plutil -extract id raw -o - "$notary_result")
[ "$notary_status" = Accepted ] || fail "Apple notarization status was $notary_status (submission $notary_id)."

xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
codesign --verify --strict "$dmg_path"
spctl --assess --type open --context context:primary-signature "$dmg_path"
"$project_root/Scripts/prepare-release-dmg.sh" --audit "$version"
"$project_root/Scripts/prepare-update-feed.sh" "$dmg_path" "$app_root" "$update_output"
checksum=$(shasum -a 256 "$dmg_path" | awk '{print $1}')
printf '%s  %s\n' "$checksum" "SayIt-$version.dmg" > "$build_root/release-$version-notarized.sha256"
printf '\nRelease ready: Say It %s\nDMG: %s\nSHA-256: %s\nNotarization: %s\n' \
    "$version" "$dmg_path" "$checksum" "$notary_id"
echo "Update assets: $update_output/SayIt.dmg and appcast.xml"
echo 'No GitHub upload was performed.'
