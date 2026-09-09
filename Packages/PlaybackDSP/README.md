# Sonic playback comparison

This experimental branch replaces Apple's playback time stretcher with Sonic,
using its quality setting of 1. Playback speed remains 0.5–2× with unchanged pitch.
At 1× the original PCM bypasses processing. A continuous processor spans scheduling
chunks; final lookahead is drained and output is trimmed to the expected duration.
Source audio and exports stay original.

Vendored unmodified sources: waywardgeek/sonic at `b93885d`, under Apache 2.0; the
license is beside the sources. Sonic's Float API internally uses 16-bit samples.
The wrapper clamps non-unity inputs to [-1, 1] before conversion to prevent integer
overflow. This precision tradeoff is part of the experiment, not hidden behind
an assertion that every engine uses identical internal arithmetic.

Run `swift test --package-path Packages/PlaybackDSP -c release` for DSP tests, then
`./Scripts/build-app.sh` for the local app. Compare the same voice/text and keep
native Speaking Pace at Natural. Test 0.5, 0.75, 1, 1.25, 1.5 and 2×, including
mid-sentence rate changes, pause/resume, seek, progressive generation, and replay.
This is a listening experiment, not a claim of perceptual superiority.

To render a saved speech file at every comparison speed, run
`swift run -c release --package-path Packages/PlaybackDSP PlaybackDSPRender input.wav output-directory`.
Use a fresh output directory for each engine. The CSV reports sample counts and
DSP processing time; the six WAV files can be compared directly. No audio or
measurements are uploaded. Only run one comparison app at a time; the variants
share the local app identity and settings.
