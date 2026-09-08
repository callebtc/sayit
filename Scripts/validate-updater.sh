#!/bin/sh
set -eu
app_root=${1:?Usage: validate-updater.sh APP}
plist="$app_root/Contents/Info.plist"
expected_team=${2:-}
fail() { echo "Updater validation failed: $*" >&2; exit 1; }
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
framework="$app_root/Contents/Frameworks/Sparkle.framework"
[ -d "$framework" ] || fail 'Sparkle.framework is missing.'
for component in Sparkle Autoupdate Updater.app XPCServices/Installer.xpc XPCServices/Downloader.xpc; do
    code_path="$framework/Versions/B/$component"
    [ -e "$code_path" ] || fail 'An updater component is missing.'
    if [ -n "$expected_team" ]; then
        signature=$(codesign --display --verbose=4 "$code_path" 2>&1)
        printf '%s\n' "$signature" | grep -F "TeamIdentifier=$expected_team" >/dev/null \
            || fail 'An updater component has an unexpected signing team.'
        printf '%s\n' "$signature" | grep -F 'Timestamp=' >/dev/null \
            || fail 'An updater component has no secure timestamp.'
        printf '%s\n' "$signature" | grep -F 'runtime' >/dev/null \
            || fail 'An updater component has no hardened runtime.'
    fi
done
case "$(read_key SUFeedURL)" in
    https://*/*) ;;
    *) fail 'An HTTPS update feed is required.' ;;
esac
[ "$(read_key SUVerifyUpdateBeforeExtraction)" = true ] || fail 'Archive verification is required.'
[ "$(read_key SURequireSignedFeed)" = true ] || fail 'Feed verification is required.'
[ "$(read_key SUEnableSystemProfiling)" = false ] || fail 'System profiling must be disabled.'
[ "$(read_key SUAllowsAutomaticUpdates)" = false ] || fail 'Installation must require user consent.'
public_key=$(read_key SUPublicEDKey)
[ "$(printf '%s' "$public_key" | /usr/bin/base64 -D | wc -c | tr -d ' ')" = 32 ] \
    || fail 'A valid Ed25519 public key is required.'
codesign --verify --deep --strict "$framework"
echo 'Updater validation passed.'
