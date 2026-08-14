#!/bin/sh
set -eu

app_root=${1:?Usage: validate-package-linkage.sh /path/to/SayIt.app}
nio_metadata_symbol='_$s7NIOCore10ByteBufferVMn'

fail() {
    echo "Package linkage validation failed: $*" >&2
    exit 1
}

[ -d "$app_root" ] || fail "the app bundle is missing."

# ByteBuffer's nominal type descriptor is a stable NIOCore-owned marker. A
# binary that defines it while loading the package framework has two copies.
/usr/bin/find "$app_root" -type f -print \
    | while IFS= read -r binary_path; do
        linked_libraries=$(
            /usr/bin/otool -l "$binary_path" 2>/dev/null
        ) || continue
        if ! printf '%s\n' "$linked_libraries" \
            | /usr/bin/awk '
                $1 == "cmd" && $2 ~ /^LC_(LOAD|REEXPORT)_/ {
                    reading_load = 1
                    next
                }
                reading_load && $1 == "name" {
                    print $2
                    reading_load = 0
                }
            ' \
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
