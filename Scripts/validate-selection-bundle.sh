#!/bin/sh
set -eu

app_root=${1:?Usage: validate-selection-bundle.sh /path/to/SayIt.app}
selection_helper="$app_root/Contents/Helpers/SayItSelectionAgent"

fail() {
    echo "Selected-text helper validation failed: $*" >&2
    exit 1
}

[ -x "$selection_helper" ] || fail "the helper executable is missing."

helper_info=$(
    /usr/bin/plutil -p "$selection_helper" 2>/dev/null
) || fail "the helper has no embedded Info.plist."
printf '%s\n' "$helper_info" \
    | grep -F '"CFBundleIdentifier" => "sh.sayit.mac.selection-helper"' \
        >/dev/null \
    || fail "the helper has an unexpected bundle identifier."

codesign --verify --strict --verbose=2 "$selection_helper"

app_signature=$(codesign --display --verbose=4 "$app_root" 2>&1)
if ! printf '%s\n' "$app_signature" \
    | grep -F "Info.plist entries=" >/dev/null; then
    fail "the host app's Info.plist is not sealed by its code signature."
fi

app_entitlements=$(codesign --display --entitlements - "$app_root" 2>&1 || true)
if printf '%s\n' "$app_entitlements" \
    | grep -F "com.apple.security.app-sandbox" >/dev/null; then
    fail "the host app is sandboxed and cannot register the Accessibility helper."
fi

helper_entitlements=$(
    codesign --display --entitlements - "$selection_helper" 2>&1 || true
)
if printf '%s\n' "$helper_entitlements" \
    | grep -F "com.apple.security.app-sandbox" >/dev/null; then
    fail "the Accessibility helper must not use App Sandbox."
fi
