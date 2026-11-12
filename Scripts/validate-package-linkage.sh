#!/bin/sh
set -eu

app_root=${1:?Usage: validate-package-linkage.sh /path/to/SayIt.app}
nio_metadata_symbol='_$s7NIOCore10ByteBufferVMn'
tokenizer_metadata_symbol='_$s10Tokenizers13BertTokenizerCMn'

fail() {
    echo "Package linkage validation failed: $*" >&2
    exit 1
}

reject_duplicate_module() {
    framework_pattern=$1
    metadata_pattern=$2
    module_name=$3
    if printf '%s\n' "$linked_libraries" | /usr/bin/grep -E "$framework_pattern" >/dev/null \
        && /usr/bin/nm --defined-only "$binary_path" 2>/dev/null \
            | /usr/bin/grep -E "$metadata_pattern" >/dev/null; then
        fail "$binary_path defines $module_name metadata already supplied by a shared framework."
    fi
}

[ -d "$app_root" ] || fail "the app bundle is missing."

# ByteBuffer's nominal type descriptor is a stable NIOCore-owned marker. A
# binary that defines it while loading the package framework has two copies.
/usr/bin/find "$app_root" -type f -print \
    | while IFS= read -r binary_path; do
        linked_libraries=$(
            /usr/bin/otool -l "$binary_path" 2>/dev/null
        ) || continue
        # Inspect dependencies, excluding the library's own LC_ID_DYLIB name.
        linked_libraries=$(printf '%s\n' "$linked_libraries" | /usr/bin/awk '
            $1 == "cmd" && $2 ~ /^LC_(LOAD|REEXPORT)_/ {
                reading_load = 1
                next
            }
            reading_load && $1 == "name" {
                print $2
                reading_load = 0
            }
        ')
        if printf '%s\n' "$linked_libraries" \
            | /usr/bin/grep -E '^/Library/Frameworks/SayIt[^/]*\.framework/' >/dev/null; then
            fail "$binary_path references a system-installed SayIt framework instead of the embedded framework."
        fi
        if printf '%s\n' "$linked_libraries" \
            | /usr/bin/grep -E '^@rpath/Transformers_[^/]*_PackageProduct\.framework/' >/dev/null; then
            if /usr/bin/nm --defined-only "$binary_path" 2>/dev/null \
                | /usr/bin/grep -F "$tokenizer_metadata_symbol" >/dev/null; then
                fail "$binary_path both defines Tokenizers metadata and links the shared Transformers framework."
            fi
        fi
        reject_duplicate_module '^@rpath/Transformers_[^/]*_PackageProduct\.framework/' \
            '_\$s3Hub.*(CMn|VMn|OMn)$' Hub
        reject_duplicate_module '^@rpath/MLXNN_[^/]*_PackageProduct\.framework/' \
            '_\$s5MLXNN.*(CMn|VMn|OMn)$' MLXNN
        reject_duplicate_module '^@rpath/MLXAudioTTS_[^/]*_PackageProduct\.framework/' \
            '_\$s14MLXAudioCodecs.*(CMn|VMn|OMn)$' MLXAudioCodecs
        if ! printf '%s\n' "$linked_libraries" \
            | /usr/bin/grep -E \
                '/NIOCore_[^/]*_PackageProduct\.framework/' >/dev/null; then
            continue
        fi

        if /usr/bin/nm --defined-only "$binary_path" 2>/dev/null \
            | /usr/bin/grep -F "$nio_metadata_symbol" >/dev/null; then
            binary_name=$(/usr/bin/basename "$binary_path")
            fail "$binary_name both defines NIOCore metadata and links an embedded NIOCore package framework."
        fi
    done

echo "Package linkage validation passed."
