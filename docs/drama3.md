# Standard Drama 3 on your Mac

Say It links the unmodified [ArrayPress swift-tts](https://github.com/arraypress/swift-tts)
package at v3.2.1 (`338c0bc8794ada080ffbf7f492a8b4044f31f709`). No library source
is copied into Say It, and inference needs no Python runtime or companion server.

## Model

Select **Fish Audio Drama 3 Q4 (Standard)** in Settings → Models. It uses
`mlx-community/fish-audio-drama-3-4bit` at revision
`2b0c8028998533972e77359cce56b8bf1c5d6d4a`, with 4-bit experts and 8-bit dense
projections. Download size is approximately 23.8 GB; 48 GB or more of unified
memory is suggested. Model weights retain the Fish Audio Community License.

## Integration

The app's small `DramaLibraryModel` bridge connects upstream generation to the
existing PCM conditioning and adaptive playback pipeline. Temperature 1.0,
top-p 0.9, top-k 30, paragraph handling, and the 1024-frame cap remain in use.
Reference recordings require a transcript and may be at most 30 seconds long.
The library caches voice preparation and emits approximately 0.74-second pieces.
Say It starts playback once delivered-audio measurements provide sufficient lead.
A capped or unrecoverably silenced response is an error rather than a successful
truncated reading. Cancellation stops the producer and permits a later request.

## Dependencies and packaging

The project retains upstream Say It's MLX (`ac4ae9a3`) and MLX Audio
(`624fd54`) revision pins. MLX Swift LM is pinned to unmodified revision
`ee673d6a`, compatible with that MLX version. Its gated-delta and expert-layer
implementations match release 3.32.3.

An Xcode-only static archive holds the upstream products. Its preparation step
omits the Tokenizers, Hub, MLXNN and MLXAudioCodecs objects supplied by the
shared dependency frameworks. The backend remains a dynamic framework.
This changes generated build artifacts, not upstream sources. Packaging validation rejects duplicate tokenizer and NIO metadata.

## Validation

Unit tests cover catalog selection, checkpoint-format rejection and the playback
buffer policy. Opt-in tests use an already-installed standard Q4 snapshot:

```sh
MLX_ENABLE_TF32=0 \
SAYIT_DRAMATTS_MODEL='/path/to/standard/q4/snapshot' \
SAYIT_DRAMATTS_REFERENCE='/path/to/reference.wav' \
swift test --disable-sandbox -c release --filter DramaLibraryTests
```

The reference is a local recording. Matching MLX Metal shaders are required. `InstalledModelSmokeTests` exercises the production
pipeline, including muted live playback when `SAYIT_MODEL_AUDIT_PLAYBACK=1`.
Settings → Diagnostics records loading, voice preparation, first audio,
first playback and rebuffer events.
