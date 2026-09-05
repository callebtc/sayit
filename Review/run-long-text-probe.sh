#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_build=$(mktemp -d)
trap 'rm -rf "$probe_build"' EXIT
probe_cache="$PWD/.build/ReaderProbeCache"
mkdir -p "$probe_cache"
python3 - "$probe_build/SpeechLyricsView.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('Sources/SayIt/Playback/SpeechLyricsView.swift').read_text()
source = source.replace('let isCurrent = token.id', 'LongTextProbe.wordViews += 1\n        let isCurrent = token.id')
source = source.replace('tokenization = document', 'tokenization = document\n                        LongTextProbe.tokenRebuilds += 1')
source = source.replace('let maxWidth = proposal.width ?? .infinity', 'LongTextProbe.measuredWords += subviews.count\n        let maxWidth = proposal.width ?? .infinity')
source = source.replace('guard tokens.indices.contains(wordIndex) else { return }', 'guard tokens.indices.contains(wordIndex) else { return }\n        LongTextProbe.followRequests += 1')
source = source.replace('guard currentWordIndex == wordID else { return }', 'guard currentWordIndex == wordID else { return }\n        LongTextProbe.activeWordID = wordID\n        LongTextProbe.activeWordFrame = frame')
source = source.replace('scrollMetrics = metrics', 'scrollMetrics = metrics\n                        LongTextProbe.scrollOffset = metrics.offset')
source = source.replace('visibleWordIDs.insert(id)', 'visibleWordIDs.insert(id)\n            LongTextProbe.visibleWords.insert(id)')
source = source.replace('visibleWordIDs.remove(id)', 'visibleWordIDs.remove(id)\n            LongTextProbe.visibleWords.remove(id)')
pathlib.Path(sys.argv[1]).write_text(source)
PY
swiftc -O -parse-as-library -emit-module -emit-library -module-name SayItProtocol \
    Sources/SayItProtocol/PlaybackTextChunk.swift \
    -module-cache-path "$probe_cache" \
    -emit-module-path "$probe_build/SayItProtocol.swiftmodule" \
    -o "$probe_build/libSayItProtocol.dylib"
swiftc -O -parse-as-library -I "$probe_build" -L "$probe_build" \
    -lSayItProtocol -Xlinker -rpath -Xlinker "$probe_build" \
    -module-cache-path "$probe_cache" \
    "$probe_build/SpeechLyricsView.swift" \
    Sources/SayIt/Playback/SpeechLyricsTimeline.swift \
    Sources/SayIt/Playback/SpeechReaderScroll.swift \
    Sources/SayIt/Playback/SpeechReaderDocument.swift \
    Sources/SayItCore/Synthesis/SpeechChunk.swift \
    Sources/SayItCore/Synthesis/TextChunker.swift \
    Review/LongTextProbe.swift -o "$probe_build/probe"
if [[ ${1:-} == render-series ]]; then
    python3 - "$probe_build/probe" <<'PY'
import subprocess, sys
for count in (500, 2000, 10000, 100000):
    try:
        result = subprocess.run([sys.argv[1], 'render', str(count)], capture_output=True, text=True, timeout=40)
        print(result.stdout, end='', flush=True)
        if result.returncode:
            print(f'render words={count} exit={result.returncode}', flush=True)
    except subprocess.TimeoutExpired:
        print(f'render words={count} exceeded 40-second limit', flush=True)
PY
elif [[ $# -gt 0 ]]; then
    "$probe_build/probe" "$@"
else
    "$probe_build/probe" structure 100000
    "$probe_build/probe" timing
    for count in 1000 2000 4000 8000; do
        "$probe_build/probe" chunker "$count"
    done
    for count in 10000 20000 40000; do
        "$probe_build/probe" chunker "$count" sentence
    done
fi
