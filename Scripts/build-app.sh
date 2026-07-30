#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/Build"
derived_data="$build_root/DerivedData"
source_packages="$build_root/SourcePackages"
module_cache="$build_root/ModuleCache"
swiftpm_cache="$build_root/SwiftPMCache"
app_root="$derived_data/Build/Products/Release/SayIt.app"
sign_identity="${SAYIT_SIGN_IDENTITY:--}"

mkdir -p "$source_packages" "$module_cache" "$swiftpm_cache"

xcodegen generate --spec "$project_root/project.yml" \
    --project "$project_root"

build() {
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    XDG_CACHE_HOME="$swiftpm_cache" \
        xcodebuild \
        -project "$project_root/SayIt.xcodeproj" \
        -scheme SayIt \
        -configuration Release \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$source_packages" \
        -skipPackagePluginValidation \
        -destination "platform=macOS,arch=arm64" \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        "$@" \
        build
}

if [ "$sign_identity" = "-" ]; then
    # Xcode requires a provisioning profile for app-group entitlements, even
    # for an ad-hoc identity. Build unsigned, then sign the complete local app.
    build \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        ENABLE_HARDENED_RUNTIME=NO

    codesign --force --deep --sign - "$app_root"
    codesign --force --sign - \
        --entitlements "$project_root/Config/SayItAgent.entitlements" \
        "$app_root/Contents/Library/LaunchServices/SayItAgent"
    codesign --force --sign - \
        --entitlements "$project_root/Config/SayItCLI.entitlements" \
        "$app_root/Contents/Helpers/sayit"
    codesign --force --sign - \
        --entitlements "$project_root/Config/SayIt.entitlements" \
        "$app_root"
else
    build \
        CODE_SIGN_IDENTITY="$sign_identity" \
        CODE_SIGNING_REQUIRED=YES \
        ENABLE_HARDENED_RUNTIME=YES
fi

codesign --verify --deep --strict --verbose=2 "$app_root"
echo "$app_root"
