#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/Build"
app_root="${SAYIT_APP_PATH:-$build_root/DerivedData-Local/Build/Products/Release/SayIt.app}"
dmg_background="$project_root/Scripts/Assets/dmg-background.png"
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

[ -f "$dmg_background" ] || {
    echo "The DMG background image is missing." >&2
    exit 1
}
background_width=$(sips -g pixelWidth "$dmg_background" | awk '/pixelWidth:/ {print $2}')
background_height=$(sips -g pixelHeight "$dmg_background" | awk '/pixelHeight:/ {print $2}')
[ "$background_width" = "720" ] && [ "$background_height" = "480" ] || {
    echo "The DMG background image must be 720 by 480 pixels." >&2
    exit 1
}

version=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$app_root/Contents/Info.plist"
)
dmg_path="${SAYIT_LOCAL_DMG_PATH:-$build_root/SayIt-$version-local.dmg}"

staging=$(mktemp -d "${TMPDIR:-/tmp}/sayit-local-dmg.XXXXXX")
mountpoint="$staging/mount"
content="$staging/content"
read_write_dmg="$staging/SayIt-rw.dmg"
mounted=NO
cleanup() {
    if [ "$mounted" = "YES" ]; then
        hdiutil detach "$mountpoint" >/dev/null 2>&1 || true
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

mkdir -p "$content/.background" "$mountpoint"
ditto \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$app_root" \
    "$content/Say It.app"
ditto \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$dmg_background" \
    "$content/.background/dmg-background.png"
ln -s /Applications "$content/Applications"
xattr -cr "$content"

COPYFILE_DISABLE=1 hdiutil create \
    -volname "Say It" \
    -srcfolder "$content" \
    -format UDRW \
    -ov \
    "$read_write_dmg"

hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$mountpoint" \
    "$read_write_dmg" >/dev/null
mounted=YES

osascript "$project_root/Scripts/style-dmg.applescript" "$mountpoint"
sync

# Writable APFS images may pick up host filesystem metadata while Finder saves
# the window layout. Keep only the intentional installer contents.
case "$mountpoint" in
    "$staging"/mount) ;;
    *)
        echo "Refusing to clean an unexpected DMG mount point." >&2
        exit 1
        ;;
esac
rm -rf \
    "$mountpoint/.fseventsd" \
    "$mountpoint/.Spotlight-V100" \
    "$mountpoint/.Trashes"

hdiutil detach "$mountpoint" >/dev/null
mounted=NO

hdiutil convert \
    "$read_write_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$dmg_path" >/dev/null

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
