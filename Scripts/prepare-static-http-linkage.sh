#!/bin/sh
set -eu

http_archive=${1:?Usage: prepare-static-http-linkage.sh /path/to/SayItHTTP}
nio_archive_member=NIOCore.o
nio_metadata_symbol='_$s7NIOCore10ByteBufferVMn'

fail() {
    echo "Static HTTP linkage preparation failed: $*" >&2
    exit 1
}

[ -f "$http_archive" ] || fail "the SayItHTTP archive is missing."

# Hummingbird's static package aggregate includes NIOCore.o even though the
# agent links the shared NIOCore package framework required by EventSource.
# Remove that one archive member so the process loads exactly one NIOCore.
if /usr/bin/ar -t "$http_archive" \
    | /usr/bin/grep -Fx "$nio_archive_member" >/dev/null; then
    /usr/bin/ar -d "$http_archive" "$nio_archive_member"
    /usr/bin/ranlib "$http_archive"
fi

if /usr/bin/nm --defined-only "$http_archive" 2>/dev/null \
    | /usr/bin/grep -F "$nio_metadata_symbol" >/dev/null; then
    fail "NIOCore metadata remains in the SayItHTTP archive."
fi

echo "Static HTTP linkage prepared."
