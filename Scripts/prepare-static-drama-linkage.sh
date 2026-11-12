#!/bin/sh
set -eu

archive=${1:?Usage: prepare-static-drama-linkage.sh /path/to/DramaTTSLinkage}
[ -f "$archive" ] || { echo "Missing Drama archive: $archive" >&2; exit 1; }
# Omit objects supplied by the shared Transformers, MLXNN and MLXAudioTTS
# frameworks linked by SayItBackend. Upstream package sources stay unchanged.
for member in Tokenizers.o Hub.o MLXNN.o MLXAudioCodecs.o; do
    if /usr/bin/ar -t "$archive" | /usr/bin/grep -Fx "$member" >/dev/null; then
        /usr/bin/ar -d "$archive" "$member"
    fi
done
/usr/bin/ranlib "$archive"
if /usr/bin/nm --defined-only "$archive" 2>/dev/null \
    | /usr/bin/grep -F '_$s10Tokenizers13BertTokenizerCMn' >/dev/null; then
    echo "Duplicate Tokenizers metadata remains in the Drama archive." >&2
    exit 1
fi
