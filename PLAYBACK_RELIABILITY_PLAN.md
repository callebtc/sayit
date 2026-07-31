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

Status: in progress

- [x] Create an isolated worktree and feature branch.
- [x] Document findings, scope, milestones, and validation.
- [ ] Commit the plan.

### M1 — Adaptive playback policy

Status: pending

- [ ] Pass `PlaybackMode` into playback preparation.
- [ ] Honor progressive, buffered, and complete-first start behavior.
- [ ] Track synthesis real-time factor with a bounded estimator.
- [ ] Use playback rate and observed generation latency to maintain adaptive
      start and resume watermarks.
- [ ] Detect unsustainable streaming and defer playback until completion rather
      than repeatedly underrunning.
- [ ] Add deterministic policy tests covering playback modes, rates, jitter,
      sustainable generation, and slow generation.

### M2 — Artifact-safe PCM and transitions

Status: pending

- [ ] Add a pure, testable PCM conditioner for finite-value validation, peak
      safety, DC correction, logical-boundary crossfades, and explicit-silence
      ramps.
- [ ] Preserve contiguous streaming fragments without crossfading them.
- [ ] Add short ramps for seek, buffering recovery, stop, and model switching.
- [ ] Remove the early 50 ms completion cutoff and use buffer completion plus a
      delayed watchdog.
- [ ] Ensure the archive receives the same conditioned stream as playback.
- [ ] Add discontinuity, duration, clipping, and transition tests.

### M3 — Bounded storage and scheduling

Status: pending

- [ ] Introduce an incrementally written temporary PCM store.
- [ ] Keep only a bounded scheduling horizon in `AVAudioPlayerNode`.
- [ ] Implement seek and replay scheduling from file segments without creating
      an array containing the entire remaining recording.
- [ ] Finalize history/export from the PCM store without retaining the complete
      document in memory.
- [ ] Add bounded-memory, long-stream, seek, cancellation, and cleanup tests.

### M4 — State transport and transcript performance

Status: pending

- [ ] Move wire decoding and encoding outside the agent main actor.
- [ ] Separate timeline revisions from static playback-content revisions so
      unchanged text, chunk metadata, and amplitudes are not repeatedly sent.
- [ ] Accept monotonically newer snapshot IDs without requiring an unnecessary
      full reload when intermediate revisions are coalesced.
- [ ] Precompute transcript word timing and use binary search for the active
      word.
- [ ] Avoid per-word full-transcript scans and unnecessary animations.
- [ ] Add protocol compatibility, coalesced-revision, and transcript scaling
      tests.

### M5 — Route, archive, and regression hardening

Status: pending

- [ ] Coalesce audio-configuration notifications.
- [ ] Resume from a stable render-frame anchor with bounded retry/backoff.
- [ ] Replace the failing direct AAC writer with a deterministic staged
      conversion path.
- [ ] Add route-change state-machine and archive format tests.
- [ ] Run all Swift tests and repository validation scripts.
- [ ] Build the release app with warnings treated as errors.
- [ ] Update this document with final results and commit IDs.

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
| M0 | pending | Baseline focused build and tests recorded | in progress |
| M1 | pending | pending | pending |
| M2 | pending | pending | pending |
| M3 | pending | pending | pending |
| M4 | pending | pending | pending |
| M5 | pending | pending | pending |
