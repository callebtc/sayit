#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$#" = 3 ] || { echo 'Usage: prepare-update-feed.sh FINAL_DMG APP OUTPUT_DIRECTORY' >&2; exit 2; }
dmg=$1
app=$2
output=$3
tools_dir=${SAYIT_SPARKLE_TOOLS_DIR:-$project_root/Build/SourcePackages/artifacts/sparkle/Sparkle/bin}
key_file=${SAYIT_UPDATE_KEY_FILE:-$project_root/.env}
export SAYIT_UPDATE_KEY_FILE="$key_file"
fail() { echo "Update feed preparation failed: $*" >&2; exit 1; }
for tool in generate_appcast sign_update; do
    [ -x "$tools_dir/$tool" ] || fail 'Sparkle release tools are missing; set SAYIT_SPARKLE_TOOLS_DIR.'
done
[ -f "$dmg" ] || fail 'The final DMG is missing.'
[ ! -e "$output" ] || fail 'The output directory already exists; use a fresh directory.'
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
case "$version" in ''|*[!0-9.]*|.*|*..*) fail 'Only stable release versions may enter this feed.';; esac
feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")
case "$feed" in
    https://github.com/*/*/releases/latest/download/appcast.xml) ;;
    *) fail 'The feed must be a GitHub latest-release appcast asset.';;
esac
repository_url=${feed%/releases/latest/download/appcast.xml}
embedded_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")
# The helper prints only the public key; private bytes stay in the ignored file.
file_public_key=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift "$project_root/Scripts/update-key.swift" public "$key_file")
[ "$embedded_key" = "$file_public_key" ] || fail 'The signing key does not match the app public key.'
"$project_root/Scripts/validate-updater.sh" "$app"
mkdir -p "$output"
cp "$dmg" "$output/SayIt.dmg"
cmp "$dmg" "$output/SayIt.dmg"
"$project_root/Scripts/sparkle-tool.py" "$tools_dir/generate_appcast" \
    --maximum-deltas 0 \
    --download-url-prefix "$repository_url/releases/download/v$version/" \
    --link "$repository_url/releases/tag/v$version" \
    -o "$output/appcast.xml" "$output"
"$project_root/Scripts/sparkle-tool.py" "$tools_dir/sign_update" --verify "$output/appcast.xml"
# Check the exact metadata and archive bytes before these assets are uploaded.
/usr/bin/xmllint --noout "$output/appcast.xml"
[ "$(/usr/bin/xmllint --xpath 'count(/rss/channel/item)' "$output/appcast.xml")" = 1 ] \
    || fail 'Expected exactly one update entry.'
feed_version=$(/usr/bin/xmllint --xpath 'string(/rss/channel/item/*[local-name()="shortVersionString"])' "$output/appcast.xml")
[ "$feed_version" = "$version" ] || fail 'The DMG display version does not match the app.'
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
feed_build=$(/usr/bin/xmllint --xpath 'string(/rss/channel/item/*[local-name()="version"])' "$output/appcast.xml")
[ "$feed_build" = "$build_number" ] || fail 'The DMG build number does not match the app.'
enclosure='string(/rss/channel/item/enclosure/@url)'
url=$(/usr/bin/xmllint --xpath "$enclosure" "$output/appcast.xml")
[ "$url" = "$repository_url/releases/download/v$version/SayIt.dmg" ] || fail 'Unexpected archive URL.'
length=$(/usr/bin/xmllint --xpath 'string(/rss/channel/item/enclosure/@length)' "$output/appcast.xml")
[ "$length" = "$(stat -f %z "$dmg")" ] || fail 'Archive length mismatch.'
signature=$(/usr/bin/xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$output/appcast.xml")
"$project_root/Scripts/sparkle-tool.py" "$tools_dir/sign_update" --verify "$dmg" "$signature"
echo 'Signed update feed and byte-identical DMG are ready for review.'
