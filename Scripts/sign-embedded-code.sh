#!/bin/sh
set -eu
app_root=${1:?Usage: sign-embedded-code.sh APP IDENTITY}
identity=${2:?Missing signing identity}
timestamp_option=
if [ "${SAYIT_DISABLE_SECURE_TIMESTAMP:-NO}" = YES ]; then
    timestamp_option=--timestamp=none
fi

# Sign children before their enclosing bundles. Sparkle contains executables,
# XPC services and Updater.app inside a versioned framework.
find "$app_root/Contents" -depth \
    \( -type f \( -name '*.dylib' -o -name Autoupdate \) \
    -o -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' \) \) \
    -exec /usr/bin/codesign --force --sign "$identity" \
        ${timestamp_option} --options runtime \
        --preserve-metadata=identifier,entitlements,requirements {} \;
