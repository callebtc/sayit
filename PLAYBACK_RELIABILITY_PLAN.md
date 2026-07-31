# Playback Reliability Implementation Plan

## Objective

Make generated and archived speech play continuously without avoidable gaps,
clicks, clipped endings, transport artifacts, excessive memory growth, or
long-transcript UI stalls. Preserve the existing service, HTTP, CLI, history,
voice, model-switching, and Now Playing behavior.

## Working rules

- Keep each milestone independently buildable and covered by focused tests.
- Commit after every completed milestone.
- Keep live playback and archived playback based on the same conditioned PCM.
- Treat model output fragments with the same logical chunk index as contiguous;
  only condition boundaries between logical chunks.
- Keep audio scheduling and storage bounded for the 200,000-character input
  limit.
- Record only numeric playback diagnostics and stable codes. Never record source
  text, generated samples, filenames, or other user data.

## Baseline

- The audio graph validates sample rates, starts the engine before the player,
  schedules buffers in order, monitors engine configuration changes, and uses
  high-overlap pitch-preserving rate conversion.
- Playback starts from a fixed 1.2-second wall-clock preroll and restarts from a
  full underrun using the same threshold.
- Model playback mode currently changes only the requested synthesis emission
  interval; it does not control playback start policy.
- All generated PCM is retained in memory and seeks allocate the entire
  remaining tail.
- Logical synthesis chunks are joined without boundary conditioning.
- Timeline snapshots carry static transcript data repeatedly.
- Active-word calculation repeatedly scans transcript data during view updates.
- The focused baseline build succeeds. The AAC archive test reproducibly fails
  with Core Audio format error `fmt?`; the other 25 selected playback-related
  tests pass.

## Milestones

### M0 — Plan and baseline

Status: complete

- [x] Create an isolated worktree and feature branch.
- [x] Document findings, scope, milestones, and validation.
- [x] Commit the plan.

### M1 — Adaptive playback policy

Status: complete

- [x] Pass `PlaybackMode` into playback preparation.
- [x] Honor progressive, buffered, and complete-first start behavior.
- [x] Track synthesis real-time factor with a bounded estimator.
- [x] Use playback rate and observed generation latency to maintain adaptive
      start and resume watermarks.
- [x] Detect unsustainable streaming and defer playback until completion rather
      than repeatedly underrunning.
- [x] Add deterministic policy tests covering playback modes, rates, jitter,
      sustainable generation, and slow generation.

### M2 — Artifact-safe PCM and transitions

Status: complete

- [x] Add a pure, testable PCM conditioner for finite-value validation, peak
      safety, DC correction, logical-boundary crossfades, and explicit-silence
      ramps.
- [x] Preserve contiguous streaming fragments without crossfading them.
- [x] Add short ramps for seek, buffering recovery, stop, and model switching.
- [x] Remove the early 50 ms completion cutoff and use buffer completion plus a
      delayed watchdog.
- [x] Ensure the archive receives the same conditioned stream as playback.
- [x] Add discontinuity, duration, clipping, and transition tests.

### M3 — Bounded storage and scheduling

Status: complete

- [x] Introduce an incrementally written temporary PCM store.
- [x] Keep only a bounded scheduling horizon in `AVAudioPlayerNode`.
- [x] Implement seek and replay scheduling from file segments without creating
      an array containing the entire remaining recording.
- [x] Finalize history/export from the PCM store without retaining the complete
      document in memory.
- [x] Add bounded-memory, long-stream, seek, cancellation, and cleanup tests.

### M4 — State transport and transcript performance

Status: complete

- [x] Move wire decoding and encoding outside the agent main actor.
- [x] Separate timeline revisions from static playback-content revisions so
      unchanged text, chunk metadata, and amplitudes are not repeatedly sent.
- [x] Accept monotonically newer snapshot IDs without requiring an unnecessary
      full reload when intermediate revisions are coalesced.
- [x] Precompute transcript word timing and use binary search for the active
      word.
- [x] Avoid per-word full-transcript scans and unnecessary animations.
- [x] Add protocol compatibility, coalesced-revision, and transcript scaling
      tests.

### M5 — Route, archive, and regression hardening

Status: complete with one packaging-environment limitation

- [x] Coalesce audio-configuration notifications.
- [x] Resume from a stable render-frame anchor with bounded retry/backoff.
- [x] Replace the failing direct AAC writer with a deterministic staged
      16-bit PCM MPEG-4 path that does not depend on an optional system encoder.
- [x] Add route-change policy and archive format/cleanup tests.
- [x] Run all Swift tests and repository validation scripts.
- [x] Compile the complete Swift package in Release configuration.
- [x] Regenerate the Xcode project successfully.
- [ ] Package the Release app. The build script could not download its separate
      Xcode package cache because network escalation was unavailable. This is an
      environment limitation; compilation and tests use the same pinned package
      graph and passed offline.
- [x] Update this document with final results and commit IDs.

## Final validation

- Full Swift test suite: 190 tests in 43 suites passed.
- Focused final route/archive/storage suite: 32 tests passed, followed by 15
  archive and recovery tests after final naming and container assertions.
- Model catalog, property list, and entitlements: valid.
- Xcode project regeneration: succeeded and the generated project includes the
  new source and test files.
- Offline Release compilation: succeeded for all package products, including
  the app and agent executables.
- Release app packaging: not run to completion because Xcode attempted to
  create a separate package cache from the network and the approval service was
  unavailable. No code, test, catalog, or Release compiler failure remains.

The M4A archive is now an audio-only MPEG-4 container with 16-bit PCM. This is
larger than AAC but is deterministic, reopens successfully through
`AVAudioFile`, preserves the conditioned samples without codec artifacts, and
works on systems where the optional AAC encoder is unavailable.

## Validation matrix

| Area | Required checks |
| --- | --- |
| Buffering | 0.75×–2×, progressive/buffered/complete-first, bursty and slow producers |
| Audio joins | Same logical chunk, new logical chunk, paragraph silence, clipped and DC-offset input |
| Transport | Pause/resume, seek, skip, clear, finish, model switch |
| Devices | Sample-rate change, temporary no-output state, repeated notifications |
| Long form | 50,000 and simulated 200,000-character duration without linear resident-memory growth |
| Archives | Live/archive PCM equivalence, M4A audibility, WAV export, cleanup after failure |
| Clients | App polling, CLI, HTTP, snapshots, protocol round trips |
| UI | Unicode transcripts, long transcripts, active-word lookup, manual scrolling |
| Regression | Full Swift test suite, catalog validation, generated Xcode project, release build |

## Progress log

| Milestone | Commit | Validation | Status |
| --- | --- | --- | --- |
| M0 | `4cd22de` | Baseline focused build and tests recorded | complete |
| M1 | `8ddf504` | 33 focused policy, service, and queue tests passed | complete |
| M2 | `9432358` | 34 DSP, synthesis, transition, service, and queue tests passed | complete |
| M3 | `fa39a20` | 48 storage, scheduler, DSP, service, and queue tests passed | complete |
| M4 | `ea02de4` | 47 transport, protocol, HTTP, service, and transcript tests passed | complete |
| M5 | `f72ee5a` | 190 full-suite tests; catalog, project generation, and offline Release compilation passed | complete with packaging limitation |
