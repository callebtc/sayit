# Phonon integration research

Researched 2026-10-21 against official Gradium sources, checkpoint metadata, and upstream MLX Audio Swift. The original feasibility assessment is preserved below; the implementation and validation update is at the end.

## Recommendation

Phonon is a viable local model for SayIt. Start with **`gradium/phonon-31m-en`**, using the Phonon support recently merged into MLX Audio Swift. This reuses SayIt's existing MLX/Pocket TTS integration direction. Gradium also ships an independent Swift/Core ML runtime that is a useful alternative for a later performance comparison. The MLX route and native runtime are different implementations; Gradium's CPU/Neural Engine performance figures do not establish MLX performance in SayIt.

MLX Audio Swift merged [Phonon support in PR #288](https://github.com/Blaizzy/mlx-audio-swift/pull/288) on 2026-10-20, merge commit `219eeb287687a87691d9d092172dd51d0a10e6d8`. Its [Pocket TTS/Phonon documentation](https://github.com/Blaizzy/mlx-audio-swift/blob/624fd5410b2fc8ea06f955500c9ac078e405261f/Sources/MLXAudioTTS/Models/PocketTTS/README.md) explicitly lists all official 31m and 40m checkpoints, `PocketTTSModel` and `TTS.loadModel`, 24 kHz output, incremental streaming, the default voice, and local or Hugging Face embedding files.

## Checkpoints, files, and licenses

| Model | Languages | Weight license | Access |
|---|---|---|---|
| Phonon 31m | English | Apache 2.0 | Public |
| Phonon 40m | One model each for English, French, German, Spanish, Portuguese | CC BY-NC 4.0 | Hugging Face gated terms |
| Phonon 40m multilingual | All five languages | CC BY-NC 4.0 | Hugging Face gated terms |

The [official runtime README](https://github.com/gradium-ai/xn-ptts/blob/main/README.md#model-setup) distinguishes these licenses and says gated approval is automatic after accepting terms. The [31m model card](https://huggingface.co/gradium/phonon-31m-en/blob/541f5752bc3c79583068bb205bfda5eb39aaa08a/README.md) explicitly licenses its weights, tokenizer, and included voices under Apache 2.0. Runtime code is MIT OR Apache-2.0. A commercial-use agreement is offered for 40m on the [product page](https://gradium.ai/phonon). Begin with 31m to avoid imposing 40m's noncommercial restriction and authentication flow on the default experience.

**The advertised 64.5 MB is the q8 GGUF file, not the MLX or Core ML download.** The [31m file metadata](https://huggingface.co/api/models/gradium/phonon-31m-en/tree/541f5752bc3c79583068bb205bfda5eb39aaa08a?recursive=true&expand=false) reports:

| File | Bytes |
|---|---:|
| `model.q8.gguf` | 64,512,352 |
| `model.safetensors` | 102,823,920 |
| `default-voice.safetensors` | 256,136 |
| `tokenizer.model` | 65,045 |
| `tokenizer.json` | 277,967 |

MLX uses the safetensors route, with small configuration/tokenizer/voice files in addition. The [v0.4.0 release](https://github.com/gradium-ai/xn-ptts/releases/tag/v0.4.0) Core ML ZIP is 137,096,081 bytes; its framework ZIP is 39,007,317 bytes. Gradium's [Swift guide](https://github.com/gradium-ai/xn-ptts/blob/main/ios/PhononTTS/README.md) estimates installed Core ML storage at roughly twice the unzipped model folder because compiled copies are stored alongside source models, plus any copy bundled in the app. It reports about 95 MB memory while speaking for its runtime; this has not been measured in SayIt.

## MLX route and checkpoint drift

The [official 31m config at the inspected revision](https://huggingface.co/gradium/phonon-31m-en/blob/541f5752bc3c79583068bb205bfda5eb39aaa08a/config.json) has a six-layer, 512-dimension flow LM, 24,000 Hz output, 12.5 audio frames per second, `num_speakers` and `duration_delta` conditioners, and **`model_type: "gradium_phonon_tts"`**. The original Pocket family relationship is confirmed by the model card.

The current checkpoint's model type differs from the `phonon` alias used by the new upstream MLX dispatch. An integration should explicitly select `modelType: "phonon"` when loading this model and teach SayIt's validation that `gradium_phonon_tts` belongs to that family. Do not assume that merely adding the Hugging Face ID to the catalog will work. Older checkpoint configs without `model_type` also need structural recognition if exposed through community model loading. Pin a checkpoint revision and test the actual downloaded files, since the launch-day format is changing.

The [upstream Pocket documentation](https://github.com/Blaizzy/mlx-audio-swift/blob/624fd5410b2fc8ea06f955500c9ac078e405261f/Sources/MLXAudioTTS/Models/PocketTTS/README.md) documents `voice: nil` or `"default"` for `default-voice.safetensors`; alternate voice paths can be local `.safetensors` or `hf://` URLs. It cautions that checkpoints omitting a speaker encoder require embeddings rather than reference audio. Model loading support alone does not establish that SayIt's reference-audio clone workflow, language selector, or tuning controls work with Phonon. In particular, inspect and test the upstream Pocket implementation's handling of language before promising multilingual switching.

## Native Swift/Core ML alternative

The [released Swift package manifest](https://github.com/gradium-ai/xn-ptts/blob/v0.4.0/Package.swift) uses Swift tools 6.0 and exposes library product **`ptts`**, module **`PhononTTS`**. It depends on a precompiled `PhononCore` XCFramework with a pinned checksum and links CoreML, CoreVideo, Accelerate, and AVFoundation. No Rust build is required for the released package. The [Swift guide](https://github.com/gradium-ai/xn-ptts/blob/main/ios/PhononTTS/README.md) requires macOS 15+ or iOS 18+, Apple silicon, Xcode 16+, and exclusion of x86_64 because the compiled framework is arm64-only.

```swift
import PhononTTS

let tts = try await Phonon.load(models: installedModelDirectory, language: .english)
try await tts.setVoice(selectedVoice)
for try await samples in tts.stream(text) {
    // Feed samples into SayIt's playback path at Phonon.sampleRate (24,000 Hz).
}
```

The [Swift implementation](https://github.com/gradium-ai/xn-ptts/blob/main/ios/PhononTTS/Sources/PhononTTS/Phonon.swift) provides:

- `load(models:language:computeUnit:)`, with Neural Engine default and CPU fallback.
- `speak(_:onAudio:)`, `stream(_:)`, and `synthesize(_:)`, returning mono Float32 PCM. Callback chunks represent 80 ms of audio.
- Serialized generation on a private dispatch queue; the model may be retained and reused from Swift concurrent callers.
- Task cancellation that stops generation at the next chunk. Breaking out of the async stream alone is explicitly insufficient; cancel its consuming task. SayIt must also clear queued playback on Stop.
- `voices`, `setVoice(_:)`, `languages`, and `setLanguage(_:)`. Normalization language is required; `.none` passes text unchanged. Numbers and symbols are normalized before generation, and long text is split into sentences.

The Swift guide reports roughly ten seconds for first Core ML compilation and 0.6 seconds for subsequent loading on an iPhone 16 Pro. These are vendor measurements, not Mac or SayIt measurements. Voice switching can incur roughly 0.6 seconds. Its conservative table reports 12–14.5x realtime and 16–37 ms to first audio on that iPhone; the product page uses different headline measurements. Benchmark cold load, warm load, first audible audio, interruption latency, and memory on SayIt's supported Macs.

**Delivery:** [PhononModels](https://github.com/gradium-ai/xn-ptts/blob/main/ios/PhononTTS/Sources/PhononTTS/PhononModels.swift) can copy a bundled model to a writable directory or download a statically hosted `bundle.json` and its listed files. Downloaded files are checked against size and SHA-256, interrupted downloads retain verified files, and a new bundle is staged before replacement. Models must be writable because Core ML creates compiled models beside them. An integration should place these under SayIt's model storage rather than accepting the package's independent default directory.

The released Core ML 31m bundle contains catalog English voices. Other models must be exported with the runtime's `export_coreml` example. Export-time conditions such as `duration_delta` are fixed in the exported folder; the public Swift API does not expose a per-utterance speed or duration control. The [Core ML engine](https://github.com/gradium-ai/xn-ptts/blob/main/ptts-ffi/src/coreml.rs) loads voice safetensors from a `voices/` directory; the Swift API has no `addVoice` entry point. Adding imported voice files should be treated as an integration task, including refresh/reload and bundle manifest handling.

**Version caveat:** At inspection, GitHub's latest published release was v0.4.0 (2026-10-20), while `main`'s root manifest referenced v0.4.1. Pin a published tag and its matching model bundle for a native experiment; do not rely on the mutable `main` manifest.

## Voice catalog and cloning

The [official voice catalog](https://huggingface.co/gradium/phonon-voices/blob/main/README.md) is Apache-2.0 and lists 102 embeddings across five languages, including 37 English voices. It supplies `voices.jsonl` metadata and `.safetensors` files with a `speaker_wavs` tensor. A voice's language/accent should match the selected model and text; the existence of a Spanish voice does not make the English-only checkpoint multilingual.

[Gradium's voice instructions](https://github.com/gradium-ai/xn-ptts/blob/main/README.md#voices) create/design/clone voices using Gradium Studio or a Gradium API key, then download a voice file for local inference. The cloning script uses ten seconds of recording. This is a cloud creation step, even though subsequent speech generation is offline. Do not label that workflow local voice cloning without separately proving that the MLX implementation supports the official checkpoint's speaker encoder and reference format end to end.

## Mapping to SayIt's current implementation

This section is based on the local repository sources inspected on the research date; it describes proposed changes, not completed implementation.

1. **Upgrade the inference dependency.** Both `Package.swift` and `project.yml` pin MLX Audio Swift to `bf14ae0c26e4e85553dd989571cae29d70fa6735`, which predates Phonon support. Select a tested immutable revision containing PR #288 and regenerate the Xcode project. This is a dependency migration, not just a catalog addition: upstream also [removed MLXLMCommon/MLXLLM dependencies](https://github.com/Blaizzy/mlx-audio-swift/commit/92ca66cf36dbd9c4c2206308cd181191619010e4), while `Sources/SayItBackend/Synthesis/SynthesisActor.swift` currently imports MLXLMCommon. Resolve changed imports and generation APIs before assessing runtime behavior.
2. **Register and validate the family.** Add `phonon` and the official checkpoint's `gradium_phonon_tts` as compatible identifiers in `Sources/SayItBackend/Models/SupportedModelTypes.swift`. A curated descriptor should use `modelType: "phonon"` so `SynthesisActor.ensureModelLoaded` passes that explicit alias to the upstream loader, while `ModelManager.validateSnapshot` accepts the checkpoint's declared type. `CommunityModelResolver` also needs family recognition and preset/streaming defaults; older configs lacking a declared type need separate structural recognition if supported.
3. **Create a reproducible catalog entry.** Add 31m to `Sources/SayItCore/Resources/ModelCatalog.json` with a pinned Hugging Face revision, exact file sizes/hashes, English language, `default` voice, progressive playback, and Apache-2.0 terms. The existing managed downloader already handles JSON and safetensors. Include `default-voice.safetensors` at the checkpoint root, not an invented `voices/default.safetensors` location. Use measured download and memory estimates for the selected format. Additional catalog voices need explicit files or a managed dependency; do not rely on implicit network downloads during speech.
4. **Reuse the current playback path.** `SynthesisActor` already consumes MLX `SpeechGenerationModel` sample streams and produces `SynthesisEvent.audio(AudioChunk)`. `AudioChunk` carries `[Float]` samples and a sample rate, so 24 kHz Phonon output fits this interface. Preserve SayIt's text chunking, paragraph handling, cancellation, model unloading, and event accounting. The new upstream loader [dispatches `phonon` through PocketTTSModel](https://github.com/Blaizzy/mlx-audio-swift/blob/624fd5410b2fc8ea06f955500c9ac078e405261f/Sources/MLXAudioTTS/TTSModel.swift); a new IPC protocol or player is unnecessary for the MLX route.
5. **Expose only verified capabilities.** Enable preset voices and progressive reading first. Leave cloning, voice design, multilingual selection, and native speaking-rate controls disabled until separately verified. The inspected upstream [PocketTTSModel implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/624fd5410b2fc8ea06f955500c9ac078e405261f/Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift) ignores the generation method's `language` argument. Loading a multilingual checkpoint therefore does not by itself prove language selection works. SayIt's existing playback-rate control can still be evaluated independently of model conditioning.

If the dependency migration is too disruptive, selectively porting the upstream support is possible but creates maintenance work. The native Core ML alternative can instead implement `BackendSpeechSynthesizing` behind a routing synthesizer in `SayItBackendService`, preserving the same events and playback. It additionally needs a model installation path that understands Core ML bundles rather than the current safetensors/config validation rules. This makes it a larger architectural change than the MLX route.

## Remaining validation

1. Upgrade or selectively port upstream MLX Phonon support and verify all existing SayIt models still build and load.
2. Test the pinned official 31m config, tokenizer, weights, and default voice through SayIt's local-directory loader, explicitly selecting the Phonon family.
3. Compare synthesized speech with Gradium's reference on plain prose, long text, numbers, dates, URLs, and punctuation; text normalization is part of claimed quality.
4. Test stop/restart, bounded streaming, voice selection, speed handling, first-run download, checksum failure, and offline reloading.
5. Treat 40m language models, multilingual behavior, authentication, licensing, and cloud voice creation as later, separately validated features.

## Implementation update — 2026-10-22

SayIt now includes **Phonon 31M English** in its experimental catalog, using MLX Audio Swift revision `624fd5410b2fc8ea06f955500c9ac078e405261f` and MLX Swift 0.32.3. The checkpoint is pinned to `541f5752bc3c79583068bb205bfda5eb39aaa08a`. All five managed files have SHA-256 checksums and total **103,427,702 bytes**. No GGUF or Core ML runtime is involved.

The integration recognizes `gradium_phonon_tts` and dispatches it as `phonon`, including community imports. The default preset maps to the checkpoint's root `default-voice.safetensors`. It uses the existing synthesis, text chunking, progressive playback, cancellation, and unloading path at 24 kHz mono. English and the default preset are enabled; voice cloning, voice design, language selection, and native speaking pace remain disabled.

The dependency upgrade exposed a Kokoro regression: the upstream stream proxy evaluated a lazy audio graph on another task, producing `There is no Stream(gpu, 3) in current thread`. Kokoro already generates a complete text chunk, so SayIt now materializes that chunk in the generation task before emitting PCM. The isolated real-model synthesis test reproduced the crash before this change and passed afterward.

Validation uses disposable model directories and the existing opt-in `InstalledModelSmokeTests` harness. The checkpoint's actual files were downloaded and checked against the pinned sizes and hashes, then promoted from resumable staging by the production installer. Synthetic installation tests also reject a wrong voice checksum and hide a truncated installed preset. Real Phonon generation produced finite, non-silent 24 kHz samples; stopping after the first audio event, immediately restarting, and unloading/reloading also passed. All 363 unit tests passed with the native runner, catalog/plist validation passed, and the complete macOS app built successfully in Release with signing disabled.

The Kokoro regression check also passed in the Release Xcode runner after the fix. In a separate warm-cache Phonon check, a 120-character sample generated 7.36 seconds of audio across 24 events in 1.18 seconds, with the first event at about 95 ms. This is one local observation, not a cross-device or cold-start benchmark.

The native SwiftPM build compiles the app and all test targets, but does not package MLX's Metal library. For native test execution, copy the matching Xcode-built `default.metallib` beside the SwiftPM test executable as `mlx.metallib`, then run:

```sh
cp Build/Phonon/DerivedData/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
  .build/arm64-apple-macosx/debug/SayItPackageTests.xctest/Contents/MacOS/mlx.metallib
swift test --disable-sandbox --build-system native --skip-build
```

The default SwiftPM build backend also encountered Metal compilation failures in this toolchain. Xcode's Release build packages the library correctly. These are build-tool differences; they do not require a model runtime change.

Speech naturalness, English number/URL normalization, memory use, and latency across supported Macs still need broader evaluation. Only Phonon and Kokoro received real-model synthesis checks for this dependency upgrade; other model families retain their previous catalog validation dates. Older Phonon configs without a declared architecture, additional voices, and all 40m models remain outside this integration.

## Voice options follow-up — 2026-10-22

The single `default` entry is a limit of SayIt's initial integration. Phonon supports multiple voices with the same model weights. The [official voice catalog](https://huggingface.co/gradium/phonon-voices) currently provides **37 English voices: 25 standard voices across US/UK accents and 12 character voices**, within 102 voices overall. The catalog is Apache-2.0; its embeddings contain a `speaker_wavs` tensor of shape `[1, 512, 125]`. The character voices were created with Gradium Voice Design and have Phonon 31M samples. For the English-only integration, curate the English entries; adding other-language embeddings does not add another language to the model.

The [pinned MLX implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/624fd5410b2fc8ea06f955500c9ac078e405261f/Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift) accepts named embeddings under `voices/` or `embeddings/`, local `.safetensors` paths, and `hf://` voice URLs, and projects `speaker_wavs` into model conditioning. This makes more presets and imported custom voice files feasible without changing inference engines. SayIt still needs managed voice downloads/import validation and picker entries; the additional voices have not yet been exercised through SayIt.

**Cloning and creating a voice from a text description use Gradium Studio or the Gradium API**, followed by exporting a voice file for offline speech. The [official voice instructions](https://github.com/gradium-ai/xn-ptts/blob/main/README.md#voices) describe Studio's “Download for Phonon,” downloading custom voices by ID, and a clone script that uses ten seconds of clear recording plus an API key. Exported voice files work with every Phonon checkpoint. The [product FAQ](https://gradium.ai/phonon) confirms this creation/export/local-inference workflow.

The installed, pinned 31M safetensors header has 185 entries and no `mimi.encoder.*` tensors. In the pinned MLX implementation, `fromModelDirectory` enables reference-audio encoding only when encoder weights exist; `resolveAudioPrompt` rejects reference audio otherwise. Therefore this checkpoint does **not** supply a working local recording-to-voice cloning path. It also exposes no local text-prompt voice-design implementation. SayIt's cloning/design switches should remain disabled for Phonon unless a separate creation service or a separately verified local encoder/design pipeline is added.

The practical next increment is English presets, then importing Studio-exported `.safetensors` voice files. Both can keep subsequent speech offline. Creating or cloning those custom voices inside SayIt would be a separate Gradium cloud integration.

For the preset implementation, the [English voice manifest](phonon-english-voices.json) pins `gradium/phonon-voices` to revision `0ee17205f254b5abc43b266c8a0f215565c352f7`. Its 37 English entries comprise 12 US, 13 UK, and 12 character voices, with names and descriptions from the pinned `voices.jsonl`. Each embedding is 256,136 bytes (9,477,032 bytes total); the manifest records each file's SHA-256 from its Hugging Face LFS metadata. Sources: [pinned metadata](https://huggingface.co/gradium/phonon-voices/blob/0ee17205f254b5abc43b266c8a0f215565c352f7/voices.jsonl), [pinned file metadata](https://huggingface.co/api/models/gradium/phonon-voices/tree/0ee17205f254b5abc43b266c8a0f215565c352f7/voices?expand=false).

All 37 embedding files were downloaded and checked against those sizes and SHA-256 values. Their safetensors headers each contain one `speaker_wavs` tensor with dtype `F32` and shape `[1, 512, 125]`. No audio samples were downloaded.

## Presets and file import implementation — 2026-10-22

SayIt now declares all 37 English catalog presets in addition to the original default voice. Each voice has a pinned source revision, exact size, and SHA-256 from the companion English voice manifest. Existing installations can update just the voice files without downloading the model weights again.

Settings → Voices imports Gradium-exported Phonon `.safetensors` files into the saved voice library. The backend validates the `speaker_wavs` tensor, dimensions, floating-point format, complete payload, finite nonzero values, and an 8 MiB size limit before saving an owned copy. Imported profiles retain rename, ordering, selection, preview, and deletion; speech and preview route the embedding directly to MLX rather than decoding it as a recording. Voice cloning and voice design remain disabled.

Validation: all 370 package tests passed. A separate real-model check synthesized finite, non-silent 24 kHz audio for the original default and all 37 presets, then exercised an imported file through both streaming speech and sample preview. All voice files were verified against their pinned hashes.

The updated local Release app built and passed signing, package linkage, and updater validation. It was launched successfully; its live voice picker showed all 37 presets and the original default, and the custom import sheet was checked in Settings → Voices.

## Download and UI review — 2026-10-22

A clean production-installer download fetched and verified all 42 managed files (112,904,734 bytes), including the 37 companion voice files. A separate default-only installation fetched the 9,477,032-byte voice pack through the incremental installer, exposed all 38 voice choices afterward, and left the model weights' size and modification time unchanged. Neither check used prefilled voice-download staging.

The review added an Update Voices action to installed models in Settings → Models. Both Models and Voices now share progress, cancel, retry, and dismiss controls; this also covers a fresh model download started from Voices. The voice picker follows settings and installed-voice updates, and saved voice rows use native buttons for keyboard and accessibility activation. The fresh-install and incremental-update pathways retain checksum verification and keep unavailable presets out of an existing installation's picker until the update completes.

All 373 package tests passed, including new presentation regressions for available presets and supported Phonon controls. The reviewed local Release build passed signing, package linkage, and updater validation.

The running app's native file chooser accepted a verified Phonon `.safetensors` file. Returning to the import sheet displayed the filename, populated the voice name, and enabled Import; cancel returned cleanly without creating a profile. The installed voice picker exposed all 37 English presets plus the default voice and Automatic selection.
