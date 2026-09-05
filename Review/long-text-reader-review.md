# Long-text playback and reader review

Reviewed local `main` at `2d4fe15` in branch `codex/review-long-text-reader`.
This is the initial review of that base commit, before implementation. See
[changes and validation](long-text-validation.md) for the resulting behavior and
measurements. The standalone probe now checks the fixed implementation; no model
download or speech generation is needed to run it.

The reported symptoms have multiple concrete causes. The dominant UI stall is
unbounded word layout. Streaming timestamps are unstable, while history replay
discards timing anchors completely. The implementation also estimates word
timing from character counts, so even stable timestamps are not speech alignment.

## 1. P1 — The lazy reader eagerly lays out the entire remaining document

**Locations:** `Sources/SayIt/Playback/SpeechLyricsView.swift:425–459`,
`:117–148`, and `:489–530`.

`blockRanges` returns one whole-document range when there are no audio chunks.
With one chunk starting at zero, it still returns one whole-document range:
only chunk **starts** become boundaries, and `text.endIndex` closes the last
block. Consequently, the last block includes every ungenerated word. History
replay has no chunks at all, so its block stays unbounded for the entire session.

`LazyVStack` virtualizes blocks, but each block contains an eager
`WordsFlowLayout` with one SwiftUI view per word. Its layout cache is `()`, and
both `sizeThatFits` and `placeSubviews` call `arrange`, which measures every
word again. Each word also installs hover, tap, visibility, animation, and
scroll identity modifiers. The 150-point viewport does not bound this work.

**Reproduction:** an optimized build of the actual reader, hosted in an
`NSHostingView` with highlighting disabled, produced:

| Document | Initial host/layout time | Word-view evaluations | Word measurements |
| --- | ---: | ---: | ---: |
| 500 words | 0.208 s | 2,000 | 4,500 |
| 2,000 words | 0.469 s | 8,000 | 18,000 |
| 10,000 words | 3.562 s | 40,000 | 90,000 |

Times include host setup and a requested 0.1-second run-loop interval. These
are isolated reader measurements, not end-to-end app launch times. The counters
confirm that offscreen words are evaluated and measured. A separate structural
probe found **100,000 words in one block**, both without chunks and with only
the first chunk present.

**Fix direction:** decouple bounded display blocks from synthesis chunks, keep
stable word identities, and cache word measurements and line arrangement by
text/font/width. Conceptually:

```swift
// Before: display partition depends on audio availability.
let ranges = blockRanges(in: text, chunks: chunks)
// After: bounded display partition built once, independent of audio metadata.
let ranges = displayBlocks(for: text, maximumWords: displayBlockLimit)
```

The proposed helper is illustrative, not an implemented API. Merely adding
another `LazyVStack` around the current layout does not address the eager block.

## 2. P1 — Every new speech chunk retokenizes the full document on the UI actor

**Locations:** `Sources/SayIt/Playback/SpeechLyricsView.swift:108–109` and
`:351–410`; producer in
`Sources/SayItBackend/Service/SayItBackendService.swift:1806–1812,2089–2102`.

Every appended `PlaybackTextChunk` calls `rebuildTokens` synchronously from
SwiftUI's `onChange`. That method enumerates all display ranges, regex-matches
every word, calculates offsets, copies each word string, and recreates both
the flat token array and all block arrays. This includes the ungenerated
remainder. The initial build also runs synchronously on appearance.

For document length N and C delivered logical chunks, token rebuilding costs
O(N × C), approaching quadratic total work with fixed-size synthesis chunks.
This is a repeated UI stall, not just a one-time cost. Splitting the old tail
into new blocks also changes the view hierarchy as chunks arrive.

**Evidence:** on 100,000 words, just `blockRanges` plus `wordRanges` took
0.127–0.142 seconds in an optimized build. That excludes token construction,
SwiftUI diffing, and layout. The source makes this scan recur on every observed
chunk-array change. Event coalescing can reduce the number of rebuilds but does
not bound the cost of an individual rebuild.

**Fix direction:** tokenize immutable text once outside the UI actor and update
only timing metadata for newly available ranges. Before:
`onChange(chunks) { rebuildTokens() }`; after, conceptually:
`onChange(chunks) { timingStore.appendNewAnchors(chunks) }`.

## 3. P1 — Streaming uses an unfinished audio duration as a completed chunk end

**Locations:** `Sources/SayIt/Playback/SpeechLyricsTimeline.swift:51–58`;
`Sources/SayItBackend/Service/SayItBackendService.swift:1806–1812,2089–2102`;
`Sources/SayItBackend/Synthesis/SynthesisActor.swift:379–384,416–437,458–474`.

The backend publishes the entire logical chunk's text range with its **first**
audio packet. The timeline has no audio end or completion marker for that
chunk. For the last known chunk, it substitutes `generatedDuration` for its
final end and distributes all its words across that interval. During streaming,
this interval contains only the audio received so far.

All words in an unfinished chunk are therefore assigned finite, seekable
timestamps prematurely. The highlight can race to the end of the chunk, then
move backward when the next packet increases its assumed duration. Clicking a
future word also seeks to the wrong, already-generated position.

**Deterministic reproduction:** with a 650-character chunk, the midpoint word's
timestamp changes from **1 → 5 → 20 seconds** as generated audio grows from
2 → 10 → 40 seconds. With playback held at 1.5 seconds, the selected word index
changes **97 → 19 → 4**. This demonstrates an unstable mapping independently
of audio hardware, scroll animation, or playback-clock accuracy.

**Fix direction:** distinguish incomplete and finalized timing and carry actual
aligned ranges as audio becomes available. Before: `end = generatedDuration`;
after, conceptually: use `chunk.finalAudioEnd` only when finalized, and leave
unmapped words pending. Simply replacing this with an estimated duration still
leaves approximate timestamps that can move. If live word highlighting is
required, progressive alignment is needed rather than treating all chunk text
as generated with the first packet.

## 4. P1 — History replay throws away every chunk timing anchor

**Locations:** `Sources/SayItBackend/Service/SayItBackendService.swift:2855–2868`;
`Sources/SayItBackend/Playback/PlaybackController.swift:184–187`;
`Sources/SayItBackend/History/SpeechItem.swift:6–32`;
`Sources/SayIt/Playback/SpeechLyricsTimeline.swift:16–17,59–60`.

History stores cleaned text and audio duration, but no chunk or word timing.
Replay calls `setSpokenText`, which resets `spokenChunks = []`, and never restores
anchors. Every word then receives:

`word character offset / whole text character count × whole audio duration`.

Changes in speaking speed, sentence pauses, paragraph pauses, and how the model
pronounces numbers are distributed over the whole recording. Errors can span
large portions of a long article because there are no intermediate anchors to
bring the estimate back into alignment. This also triggers the permanently
unbounded display block in finding 1.

**Deterministic reproduction:** for two equal-length text chunks whose audio
durations are 120 and 60 seconds, the live chunk metadata locates the second
chunk at 120 seconds. Replay's fallback locates it at **90 seconds**, 30 seconds
early. This is a synthetic timing fixture, not a measured model recording.

**Fix direction:** persist and restore timing alongside the archived audio.
Before: `setSpokenText(item.cleanedText)` alone; after, conceptually: restore
the text **and** its saved alignment. Existing history needs either an alignment
pass or an explicitly approximate reader; regenerating character-based chunks
cannot recover the original audio timestamps.

## 5. P2 — “Word following” is character interpolation, not word alignment

**Locations:** `Sources/SayIt/Playback/SpeechLyricsTimeline.swift:35–40,54–58`;
`Sources/SayItProtocol/PlaybackTextChunk.swift:3–6`;
`Sources/SayItBackend/Playback/PCMStreamConditioner.swift:129–147`.

Even completed chunks have only text bounds and one audio start. The highlighter
assumes constant audio duration per source character inside each chunk. It has
no information about word onset, pronunciation, or silence. The source range can
also include whitespace that chunking normalized away. Accurate chunk starts
therefore do not imply accurate word starts.

Paragraph boundaries additionally prepend outgoing audio tail and silence to
the incoming audio packet, but the service records the new chunk's `audioStart`
before that packet. Its first word can highlight during the paragraph pause.
This is a boundary-local error, not evidence of accumulated playback-clock drift.

**Fix direction:** carry word/token timestamps from the synthesizer when
available, or derive them from an alignment stage and account for inserted
silence. Before: `audioStart + characterFraction * duration`; after:
`alignedWord.audioStart`. Retaining chunk anchors alone limits drift but does
not make the word-level UI accurate.

## 6. P2 — Text preprocessing repeatedly scans growing prefixes and remainders

**Locations:** `Sources/SayItCore/Synthesis/TextChunker.swift:134–143,245–275`;
`Sources/SayItCore/Synthesis/SpeechChunk.swift:58–65`;
`Sources/SayItBackend/Synthesis/SynthesisActor.swift:366,729–790`.

For every paragraph, `paragraphs` calculates a character distance from the
beginning of the original string. For oversized sentences, `splitOversized`
recounts the entire remaining suffix on each iteration, and `SpeechChunk.slice`
recalculates both offsets from the beginning of the sentence. Swift character
indices require traversal for these distances; Unicode-rich input exposes the
quadratic behavior clearly.

All chunks are prepared before the first `.chunkStarted` event. Kokoro/Kitten
also run their fitting processor over all chunks up front. These synchronous
loops contain no cancellation checks, delaying first audio and cancellation.
They run on the synthesis actor, so this is distinct from the reader's direct
UI-actor stall.

**Optimized probe results:**

| Input shape | Characters | Time |
| --- | ---: | ---: |
| 1,000 short Unicode paragraphs | 31,000 | 0.137 s |
| 2,000 short Unicode paragraphs | 62,000 | 0.345 s |
| 4,000 short Unicode paragraphs | 124,000 | 0.852 s |
| 8,000 short Unicode paragraphs | 248,000 | 2.553 s |
| One oversized Unicode sentence | 70,000 | 0.047 s |
| One oversized Unicode sentence | 140,000 | 0.166 s |
| One oversized Unicode sentence | 280,000 | 0.694 s |

**Fix direction:** maintain character-offset cursors and bounded lookahead,
pass known offsets into slices, and support incremental, cancellable chunk
production. Before: `distance(from: text.startIndex, to: paragraphStart)` on
each paragraph; after: reuse a character offset incremented during the scan.

## 7. P2 — Waveform updates invalidate the full transcript transport payload

**Locations:** `Sources/SayItBackend/Service/PlaybackContentState.swift:3–8`;
`Sources/SayItBackend/Service/SayItBackendService.swift:61–69,2233–2244,2270–2283`;
`Sources/SayItBackend/Playback/PlaybackController.swift:995–1013`.

`PlaybackContentState` puts changing amplitude buckets in the same equality and
revision group as the immutable full transcript and growing chunk array.
Whenever an audio packet changes the waveform, `playbackContentRevision`
advances. The event projection consequently includes the **entire text and all
anchors** again. The XPC codec JSON-encodes that payload. This repeats document-
sized serialization, transfer, decoding, and equality checks while synthesis
continues, amplifying the reader work on long inputs.

This is established by the invalidation/serialization path; its share of total
runtime was not separately benchmarked. Timeline-only updates can omit content,
so the issue is specifically content changes during generation, not every tick.

**Fix direction:** split revisions and payload fields for immutable text,
append-only alignment, and waveform updates. Before: one combined
`PlaybackContentState`; after: independently versioned transcript, timing,
and waveform payloads.

## Validation and recommended order

Run `bash Review/run-long-text-probe.sh` for structural, timestamp, and chunker
probes. Run `bash Review/run-long-text-probe.sh render-series` for the UI probe;
each render process has a 40-second limit. The script builds with `swiftc -O`
against the checked-out production source. For layout counters only, it creates
a temporary reader copy with three instrumentation increments. It does not edit
the production reader. Only synthetic text and synthetic timing metadata are used.

The existing `SpeechLyricsViewTests` verify monotonic interpolation for a fixed
duration, Unicode offsets, and binary-search lookup complexity. They explicitly
expect one block without chunks. They do not cover real speech alignment,
unfinished chunk duration changes, history timing restoration, or bounded layout.
No full package test run, live TTS session, or Instruments trace was performed.

Fix bounded display layout and one-time tokenization first (1–2); establish and
persist stable alignment next (3–5); then remove quadratic preprocessing and
repeated transcript transfer (6–7). The active-word binary search is already
logarithmic. Playback elapsed time is derived from the audio node rather than
accumulating timer ticks; 250 ms updates can add visual latency but do not explain
the large timing errors reproduced above.
