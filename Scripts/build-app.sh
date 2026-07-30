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
disable_secure_timestamp="${SAYIT_DISABLE_SECURE_TIMESTAMP:-NO}"
build_jobs="${SAYIT_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
clang_path_map="-ffile-prefix-map=$project_root=."
swift_path_map="-file-prefix-map $project_root=."

case "$build_jobs" in
    ''|*[!0-9]*|0)
        echo "SAYIT_BUILD_JOBS must be a positive integer." >&2
        exit 2
        ;;
esac

case "$disable_secure_timestamp" in
    YES|NO) ;;
    *)
        echo "SAYIT_DISABLE_SECURE_TIMESTAMP must be YES or NO." >&2
        exit 2
        ;;
esac

mkdir -p "$source_packages" "$module_cache" "$swiftpm_cache"

xcodegen generate --spec "$project_root/project.yml" \
    --project "$project_root"

build() {
    echo "Building Say It (Release)…"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
    XDG_CACHE_HOME="$swiftpm_cache" \
        xcodebuild \
        -quiet \
        -project "$project_root/SayIt.xcodeproj" \
        -scheme SayIt \
        -configuration Release \
        -parallelizeTargets \
        -jobs "$build_jobs" \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$source_packages" \
        -skipPackagePluginValidation \
        -destination "platform=macOS,arch=arm64" \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        OTHER_CFLAGS="\$(inherited) $clang_path_map" \
        OTHER_CPLUSPLUSFLAGS="\$(inherited) $clang_path_map" \
        OTHER_SWIFT_FLAGS="\$(inherited) $swift_path_map" \
        "$@" \
        build
}

if [ "$sign_identity" = "-" ]; then
    # Xcode requires a provisioning profile for app-group entitlements, even
    # for an ad-hoc identity. Build unsigned, then sign the complete local app.
    build \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        ENABLE_HARDENED_RUNTIME=NO \
        SAYIT_LOCAL_SWIFT_FLAG=-DSAYIT_LOCAL_BUILD \
        SWIFT_COMPILATION_MODE="${SAYIT_SWIFT_COMPILATION_MODE:-singlefile}"

    codesign --force --deep --sign - "$app_root"
else
    code_sign_flags=
    if [ "$disable_secure_timestamp" = "YES" ]; then
        code_sign_flags=--timestamp=none
    fi

    build \
        CODE_SIGNING_REQUIRED=YES \
        ENABLE_HARDENED_RUNTIME=YES \
        OTHER_CODE_SIGN_FLAGS="$code_sign_flags" \
        SAYIT_DISABLE_SECURE_TIMESTAMP="$disable_secure_timestamp" \
        SAYIT_SIGN_IDENTITY="$sign_identity" \
        SAYIT_SELECTION_SIGN_IDENTITY="$sign_identity"

    codesign \
        --force \
        --sign "$sign_identity" \
        ${code_sign_flags} \
        --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
        "$app_root"
fi

codesign --verify --deep --strict "$app_root"
echo "$app_root"
