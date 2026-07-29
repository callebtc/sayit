# Say It — End-to-End macOS Implementation Plan

## 1. Product definition and locked decisions

Say It is a privacy-first, Apple-silicon text-to-speech utility that lives
primarily in the macOS menu bar. It converts selected or copied text into
locally generated speech without a Python runtime, cloud inference, analytics,
or clipboard monitoring.

### Technical baseline

- Swift 6.2 or later with strict concurrency, SwiftUI, and small AppKit bridges.
- macOS 15 minimum; availability-gate macOS 26 visual effects.
- Apple silicon only.
- Pin `Blaizzy/mlx-audio-swift` products `MLXAudioCore` and `MLXAudioTTS` to
  release `v0.1.3`.
- Do not embed Python, Conda, `uv`, a local HTTP server, Tauri, Electron, web
  views, or third-party UI/persistence/shortcut/logging/update frameworks.
- Initial distribution is a signed, notarized, sandboxed direct-download DMG.
- Speech generation is offline after the chosen model and its tokenizer/G2P
  dependencies are installed.

### Core interaction contract

1. Selected text is received from a native `NSServices` service named “Say It.”
2. Copied text is read once through an explicit action or configurable native
   global shortcut. The app never polls the clipboard.
3. Completed speech can be replayed, exported, searched, and deleted.
4. Playback exposes play/pause, scrub, 15-second rewind, 30-second forward,
   rate, stop, export, and system Now Playing controls.
5. A new request cancels current inference, keeps its cleaned text as an
   incomplete history item, removes partial audio, and starts the new request.

The default shortcut is Control–Option–S and uses the Carbon hot-key API, which
does not require Accessibility or Input Monitoring permission.

### Day-one boundaries

- Preset/default voices and text-described voice design are supported.
- Voice cloning and persistent voice profiles are deferred. Reference-only
  models remain visible but cannot be selected.
- UI uses “Export Audio” and “Export Text,” not “export transcription.”
- No microphone, STT, cloud sync, browser extension, iOS app, automation API,
  passive clipboard history, or source text in diagnostics.

### Success criteria

- Services works in participating applications such as browsers, text editors,
  Preview, Notes, and Mail.
- The global shortcut begins processing without opening a full window.
- HTML, Markdown, RTF, and rich clipboard content become natural plain text.
- Sentence-sized synthesis chunks play continuously for long-form text.
- Model downloads report progress, cancel/resume, verify integrity, and survive
  restarts.
- Installed models synthesize without network access.
- Model loading, inference, conversion, persistence, and downloads never block
  the main actor.
- No Accessibility, microphone, Contacts, Calendar, or Automation permission.

## 2. Experience and visual design

The visual thesis is “quiet instrument”: a continuous native surface,
disciplined typography, system accent and semantic colors, and one distinctive
element—the **voice ribbon**, an actual amplitude trace that is also the
playback scrubber. Avoid dashboard cards, gradients, decorative illustrations,
fake waveforms, oversized headings, and excessive glass.

### Menu-bar popover

Use `MenuBarExtra` with `.window` style and `LSUIElement = true`. Target a
roughly 360-point width and adapt height to idle, downloading, generating,
playing, and error states.

```text
┌──────────────────────────────────────┐
│ Say It                         • M1  │
│ “First sentence of current text…”    │
│ ──▂▅▇▃▂────▃▆▂──────  03:18 / 12:42 │
│                                      │
│      ↶ 15      ◀︎/❚❚      30 ↷       │
│          1.0×        Stop            │
├──────────────────────────────────────┤
│ Read Clipboard                 ⌃⌥S  │
├──────────────────────────────────────┤
│ Recent                               │
│ Article title                 12 min │
│ Release notes                  4 min │
│ View All History…                    │
├──────────────────────────────────────┤
│ Kokoro · af_heart   Settings…   Quit │
└──────────────────────────────────────┘
```

- Idle: “Ready to speak,” active voice/model, explicit clipboard action,
  shortcut, and recent history.
- Generating: initial-buffer progress, Cancel, and factual status.
- Playing: voice ribbon and transport controls become primary.
- Downloading: model-level progress, bytes, rate, pause/resume, cancel.
- Errors always include a direct recovery action.
- `speaker.wave.2` gets restrained variable-color activity while active and an
  exclamation badge after an unattended error.
- Clipboard contents are never read or previewed before an explicit action.

Typography is SF Pro Text, SF Pro Rounded only for the current item title, and
monospaced digits for time/size/rate. Use system backgrounds, materials,
semantic label colors, the user’s accent, system shapes, and separators rather
than nested cards. Motion lasts 120–180 ms; Reduce Motion replaces geometry or
symbol motion with opacity.

### Settings and onboarding

Use a SwiftUI `Settings` scene with a persistent, noncustomizable toolbar and
restore the last selected pane:

- General
- Speech
- Models
- History
- Diagnostics
- About

Onboarding:

1. Explain local privacy and the two network exceptions.
2. Recommend and install Kokoro, verify it, and offer (but never autoplay) a
   locally generated sample.
3. Teach Services and the shortcut, offer Launch at Login, then finish into the
   menu bar.

Onboarding completes only after a compatible model is installed. Hold one
early Services request in memory and start it after installation.

### Accessibility

Provide full keyboard navigation, visible focus, VoiceOver labels/values/actions,
semantic headings, standard buttons, 28-point default controls (never below 20
points), Increased Contrast, Differentiate Without Color, Reduce Transparency,
Reduce Motion, Dynamic Type, and spoken state. Playback remains available
through Now Playing and hardware controls.

## 3. Architecture and data flow

Create one app plus core-library and unit-test targets. The main app provides
the native Service; there is no helper or extension. Organize source by feature:

- `AppShell`
- `TextIngestion`
- `Models`
- `Synthesis`
- `Playback`
- `History`
- `Settings`
- `Diagnostics`
- `DesignSystem`

Use one type per file, `@Observable` state owned by `@State`, actors for mutable
background state, and no Combine except unavoidable bridges.

Frameworks: SwiftUI, AppKit, MLXAudioCore, MLXAudioTTS, AVFoundation/AVFAudio,
MediaPlayer, SwiftData, NaturalLanguage, UniformTypeIdentifiers,
ServiceManagement, CryptoKit, OSLog, Foundation, Network, Security, and Carbon.

Stable internal boundaries:

```swift
protocol TextIngesting: Sendable {
    func ingest(_ payload: TextSourcePayload) async throws -> CleanedText
}

protocol ModelManaging: Sendable {
    func models() async -> [ModelDescriptor]
    func install(_ id: ModelID) async throws
    func cancelInstall(_ id: ModelID) async
    func remove(_ id: ModelID) async throws
    func select(_ id: ModelID) async throws
}

protocol SpeechSynthesizing: Sendable {
    func synthesize(_ request: SpeechRequest)
        -> AsyncThrowingStream<SynthesisEvent, Error>
    func cancelCurrentRequest() async
    func unloadModel() async
}

@MainActor
protocol PlaybackControlling: AnyObject {
    func enqueue(_ chunk: AudioChunk) throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
    func skip(by seconds: TimeInterval)
}
```

Core types include `TextSourcePayload`, `CleanedText`, `SpeechRequest`,
`ModelDescriptor`, `ModelCapabilities`, `ModelInstallation`, `SpeechItem`,
`PlaybackState`, `SynthesisEvent`, and `DiagnosticEvent`.

### Text ingestion

Representation precedence is native service data, HTML, RTF/RTFD, and plain
UTF-8 text.

- HTML conversion removes scripts, styles, comments, metadata, and invisible
  elements, runs off the main actor, and preserves semantic boundaries.
- Markdown uses native attributed-string parsing, keeps visible labels and alt
  text, removes URLs and syntax, drops front matter/fenced code by default, and
  preserves inline code text.
- Rich text extracts the visible attributed string.
- Normalize Unicode, line endings, repeated whitespace, lists, and control
  characters while preserving prosody-relevant punctuation/paragraph breaks.
- Persist only cleaned text.
- Reject empty output and more than 200,000 characters; confirm above 50,000.
- Derive an 80-character local title from the first meaningful sentence.
- Natural Language detection is a hint; explicit model/voice language wins.

### Speech generation

`SynthesisActor` owns one loaded model and serializes inference. It validates
the voice/language, uses `NLTokenizer` for sentence boundaries, assembles
500–800 character chunks without splitting sentences when possible, and then
fits them to the active model's processed-token budget. It reuses the active
model and generates ahead of playback. Chunk boundaries stay internal;
paragraph joins add 120–220 ms without duplicating punctuation pauses.

Models declare progressive, buffered, or complete-first playback. Qwen3 starts
in buffered mode. A model unloads after ten idle minutes, on switching, or
under memory pressure.

### Playback, history, export, and diagnostics

Playback uses `AVAudioEngine`, `AVAudioPlayerNode`, and
`AVAudioUnitTimePitch`. It schedules PCM without blocking inference, supports
0.75×–2× pitch-preserving rate, seeks in generated frames, distinguishes
generated duration from estimated duration, computes real amplitude buckets,
and handles device changes, engine restarts, and sleep/wake.

Now Playing supports play, pause, stop, seek, skip, and rate. Privacy defaults
to the title “Say It”; spoken titles appear only with an off-by-default setting.

SwiftData stores history metadata while audio files use relative managed paths.
Incomplete text can be retried but partial audio is removed. Defaults are 30
days and 2 GB, oldest-first cleanup, optional pinning, and no cloud sync.
Exports use `NSSavePanel`: `.m4a`, `.wav`, or cleaned `.txt`.

System logging uses `Logger`; the in-app recorder uses redacted JSONL. It accepts
only allowlisted metadata (identifiers, timings, byte counts, memory and stable
error codes), never text, tokens, paths, hostnames, usernames, or filenames.
Rotate at 10 MB or seven days.

## 4. Model catalog and downloads

Pure-Swift compatibility is defined by pinned MLX Audio Swift loader behavior,
not the larger Python `mlx-audio` compatibility list.

The built-in catalog includes:

- Kokoro (default, progressive, multilingual preset voices)
- KittenTTS (progressive, English preset voices)
- Pocket TTS
- Soprano
- Qwen3-TTS
- Chatterbox
- OmniVoice
- Fish Audio S2 Pro
- Irodori TTS
- VyvoTTS
- Orpheus
- MOSS-TTS
- Marvis TTS
- IndexTTS, Echo TTS, and MOSS Nano as future-voice-profile-gated

Python-only Dia, OuteTTS, Spark, Higgs Audio, Ming Omni, KugelAudio, Voxtral
TTS, LongCat, and MeloTTS remain unavailable until a pinned Swift loader passes
compatibility and license review.

`ModelCatalog.json` is versioned and stores stable app ID/display name, model
type aliases, repository, immutable revision, required file manifests and
hashes, dependencies, parameters/quantization, languages/voices/defaults,
capabilities, disk/memory estimates, hardware tier, license, stability, tested
MLX release, and test date. Compatibility is release metadata, not runtime
scraping.

`ModelDownloadActor`:

1. Requires network and free space of download size plus 20%.
2. Creates a model/revision staging directory.
3. Downloads with URLSession, persists partial/resume state, and aggregates
   progress.
4. Runs one installation and queues one.
5. Retries transient failures with bounded exponential backoff.
6. Incrementally verifies SHA-256.
7. Validates config, model type, dependencies, and weights.
8. Atomically promotes the verified snapshot.
9. Writes `installation.json` and smoke-loads it.
10. Keeps valid partials on pause/network loss and deletes tainted files.
11. Confirms active-model deletion and selects a compatible replacement.

Models live in sandbox Application Support; transient generation/download data
lives in Caches.

Custom Hugging Face repositories resolve config first, reject unsupported
model types, pin `main` to an immutable commit, use LFS hashes, display a
community-model warning and license, and store gated tokens in Keychain. Local
imports are validated and copied into managed storage.

Only one MLX model is resident. Hardware labels are advisory, with confirmation
above 70% of physical memory. Switching cancels generation, unloads, clears MLX
caches, and then loads the replacement.

## 5. Platform integration, security, and packaging

Declare the Service with message `saySelectedText`, menu title `Say It`, public
plain/UTF-8/HTML/RTF types, no return types/context, category `public.text`, and
`NSRestricted = false`. An Objective-C-compatible provider copies the
pasteboard payload and enqueues it immediately without waiting for inference.

`MenuBarExtra` is primary, `Settings` manages the app, and
`WindowGroup(id: "history")` opens history without changing `LSUIElement`.
Launch at Login uses `SMAppService.mainApp`. The app stays resident when the
popover closes and quits only explicitly or at system termination.

Enable App Sandbox, outgoing network, user-selected read/write, and Hardened
Runtime. Do not enable Accessibility, microphone/audio input, Apple Events,
broad filesystem, or temporary exceptions.

Daily native update checks query GitHub Releases and open a signed download
page; v1 does not self-replace. Release validation covers tests, catalog,
archive signing, entitlements/licenses, notarization/stapling, signed DMG,
clean-account Gatekeeper/Services/login-item checks, and release metadata.
Never include personal or machine identifiers in Git activity, releases, or
diagnostics.

## 6. Implementation sequence

1. **Runtime feasibility:** scaffold and pin; measure Kokoro, Kitten, Qwen3, and
   long-form generation; validate cancellation, memory release, progressive and
   buffered paths, managed cache/dependencies, and offline operation.
2. **Foundation:** feature structure, tokens, errors, state, settings,
   SwiftData, redacted diagnostics, storage/migrations, scenes, preview data,
   String Catalog.
3. **Models/onboarding:** catalog validation, suitability, download lifecycle,
   custom models, Keychain, model UI, onboarding, offline-load verification.
4. **Text ingestion:** Services, shortcut, clipboard precedence, cleanup,
   language/title/limits, fixtures, compatibility matrix.
5. **Synthesis/playback:** chunking, lifecycle/events, strategies, cancellation,
   pressure handling, engine/rate/seek/ribbon/writer/conversion/Now Playing,
   long-form/device/sleep tests.
6. **History/export/diagnostics:** atomic lifecycle, recent/full history,
   replay/regenerate/pin/retention/quota/delete/export, redacted UI/export.
7. **Polish/release:** assets/motion, accessibility/localization audits,
   profiling, signing/sandbox/notarization/DMG/update/privacy/acknowledgements.

## 7. Test and acceptance plan

Unit tests cover markup and Unicode cleanup, chunking, catalog and capability
logic, download state and integrity, retention/quota, playback calculations,
and diagnostic redaction.

Integration tests cover mock streams through playback/files, interrupted local
HTTP snapshots, compact-model audio validity and offline reload, cancellation
at each phase, repeated model switching, and Services pasteboards.

UI/accessibility tests cover onboarding, downloads, triggers, playback,
history/export/delete/settings restore, VoiceOver, Full Keyboard Access,
shortcut conflicts, appearance/accessibility modes, long strings, and
multi-display popovers.

Manual coverage includes three Apple-silicon memory tiers, macOS 15 and current,
major browsers/editors/document apps, unsupported Services hosts, built-in and
external output devices, sleep/wake, install/upgrade/offline/low-disk/network
failure/model removal.

Performance gates:

- Popover opens without synchronous model/history work.
- No inference, hashing, markup/audio conversion, or large fetch on main.
- Idle RSS target below 120 MB.
- Default peak target below 1.5 GB and safe on 8 GB M1.
- Default warm/cold first audio targets: 2.5/8 seconds.
- Default generates faster than playback after initial buffering on M1.
- A 30-minute article plays without stalls, gaps, or unbounded growth.
- Cancel silences and stops inference within one second.
- Model deletion removes only its managed snapshot.

## 8. Assumptions and deferred work

- Direct notarized distribution, macOS 15, and read-aloud-first scope.
- Native Services submenu placement is accepted.
- Kokoro BF16 is the onboarding default; no weights ship in the app.
- History is 30 days/2 GB; diagnostics are seven days/10 MB.
- Voice cloning, reference recording/import, and persistent profiles are a
  later milestone with explicit consent, local-only storage, transcript
  validation, deletion guarantees, and model-specific tests.
- Python-only families become eligible only after a pinned native loader passes
  compatibility and license review.
