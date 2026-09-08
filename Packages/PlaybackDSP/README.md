# Rubber Band R3 playback comparison

This experimental branch replaces Apple's playback time stretcher with Rubber
Band 4.0.0's R3 Finer engine, using real-time mode, standard windows, and unchanged
pitch. Playback speed remains 0.5–2×. At 1× the original PCM bypasses processing.
One continuous processor spans scheduling chunks. Startup padding and delay use
the library's own reported values, variable output counts are buffered, and the
final tail is drained and trimmed to the cumulative target duration. Source audio
and exports stay original.

Vendored unmodified sources: breakfastquay/rubberband at `1d95888` (v4.0.0).
The upstream single-file build uses Apple Accelerate and the bundled resampler;
no runtime library installation is needed. See `COMPARISON-LICENSE.md` for the
GPL terms of this experimental combined build and the vendor's commercial option.

Run `swift test --package-path Packages/PlaybackDSP -c release` for DSP tests, then
`./Scripts/build-app.sh` for the local app. Compare the same voice/text and keep
native Speaking Pace at Natural. Test 0.5, 0.75, 1, 1.25, 1.5 and 2×, including
mid-sentence rate changes, pause/resume, seek, progressive generation, and replay.
This is a listening experiment, not a claim of perceptual superiority.

To render a saved speech file at every comparison speed, run
`swift run -c release --package-path Packages/PlaybackDSP PlaybackDSPRender input.wav output-directory`.
Use a fresh output directory for each engine. CSV output reports sample counts
and DSP processing time; the six WAV files can be compared directly. No audio or
measurements are uploaded. Only run one comparison app at a time; the variants
share the local app identity and settings.
