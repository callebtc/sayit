# Signalsmith playback comparison

This experimental branch replaces Apple's playback time stretcher with Signalsmith
Stretch 1.3.2. Playback speed remains 0.5–2× and pitch remains unchanged. At 1× the
original PCM bypasses processing. A continuous processor spans scheduling chunks;
its latency is removed and its tail drained. Source audio and exports stay original.

Vendored sources (unmodified): Signalsmith-Audio/signalsmith-stretch at `57b93f4`
and Signalsmith-Audio/linear at `ec38d33`, both MIT licensed. License notices are
beside the sources. Apple Accelerate supplies FFTs; no runtime library install is needed.

Run `swift test --package-path Packages/PlaybackDSP -c release` for DSP tests, then
`./Scripts/build-app.sh` for the local app. Compare the same voice/text and keep
native Speaking Pace at Natural. Test 0.5, 0.75, 1, 1.25, 1.5 and 2×, including
mid-sentence rate changes, pause/resume, seek, progressive generation, and replay.
This is a listening experiment, not a claim of perceptual superiority.

To render a saved speech file at every comparison speed without changing the app,
run `swift run -c release --package-path Packages/PlaybackDSP PlaybackDSPRender input.wav output-directory`.
Use a fresh output directory for each engine. The CSV output reports sample counts
and DSP processing time, and the six WAV files can be compared directly. No audio
or measurements are uploaded by this command.

Only run one comparison app at a time; the variants share the local app identity and settings.
