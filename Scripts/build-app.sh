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
hardened_runtime=YES

# Hardened Runtime library validation rejects separately ad-hoc-signed embedded
# frameworks because ad-hoc signatures do not carry a shared Team ID. Release
# builds use the Developer ID identity supplied by release.sh and keep Hardened
# Runtime enabled.
if [ "$sign_identity" = "-" ]; then
    hardened_runtime=NO
fi

mkdir -p "$source_packages" "$module_cache" "$swiftpm_cache"

xcodegen generate --spec "$project_root/project.yml" \
    --project "$project_root"

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
    CODE_SIGN_IDENTITY="$sign_identity" \
    CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME="$hardened_runtime" \
    build

codesign --verify --deep --strict --verbose=2 "$app_root"
echo "$app_root"
