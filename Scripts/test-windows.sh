#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$project_root/Build/DerivedData-Local"
products="$derived_data/Build/Products"
module_cache="$project_root/Build/ModuleCache"

if pgrep -f "$products/Release/SayIt.app/Contents/MacOS/SayIt" >/dev/null 2>&1; then
    echo "Quit the local build before running window tests." >&2
    exit 2
fi

mkdir -p "$module_cache" "$project_root/Build/SwiftPMCache"

xcodegen generate --spec "$project_root/project.yml" --project "$project_root"
CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
XDG_CACHE_HOME="$project_root/Build/SwiftPMCache" \
xcodebuild \
    -quiet \
    -project "$project_root/SayIt.xcodeproj" \
    -scheme SayItWindowTests \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$project_root/Build/SourcePackages" \
    -skipPackagePluginValidation \
    -destination "platform=macOS,arch=arm64" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$project_root=." \
    OTHER_CPLUSPLUSFLAGS="\$(inherited) -ffile-prefix-map=$project_root=." \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $project_root=." \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    SAYIT_APP_BUNDLE_IDENTIFIER=sh.sayit.mac.local \
    SAYIT_APP_DISPLAY_NAME="Say It Local" \
    SAYIT_SELECTION_BUNDLE_IDENTIFIER=sh.sayit.mac.selection-helper.local \
    SAYIT_SELECTION_DISPLAY_NAME="Say It Local Selected-Text Helper" \
    SAYIT_LOCAL_SWIFT_FLAG=-DSAYIT_LOCAL_BUILD \
    SWIFT_COMPILATION_MODE=singlefile \
    build-for-testing

# Like build-app.sh, sign local bundles after building without a profile.
# The test runner also needs a valid resource seal before macOS can launch it.
for bundle in SayIt.app SayItUITests-Runner.app; do
    codesign --force --deep --sign - "$products/Release/$bundle"
    codesign --verify --deep --strict "$products/Release/$bundle"
done

xcodebuild \
    -quiet \
    -project "$project_root/SayIt.xcodeproj" \
    -scheme SayItWindowTests \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -destination "platform=macOS,arch=arm64" \
    "$@" \
    test-without-building
