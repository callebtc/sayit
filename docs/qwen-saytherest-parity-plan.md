# Qwen3-TTS voice cloning: SayTheRest → SayIt parity plan

Status: proposal · 2026-10-19 · compared against SayTheRest `eacae2b`

## TL;DR

SayIt for macOS **already runs Qwen3-TTS 0.6B Base with transcript-guided voice
cloning**, natively on MLX through `mlx-audio-swift` (catalog id
`qwen3-06b-base-8bit`, plus 1.7B VoiceDesign and 1.7B CustomVoice). SayTheRest is
a Linux/Windows port *of* SayIt, and its own parity tracker still lists
"Qwen3 TTS Base, VoiceDesign, and CustomVoice" as open.

SayTheRest needs PyTorch only because its inference engine, sherpa-onnx, cannot
run Qwen3-TTS. So it starts a Python worker (`runtime/qwen_worker.py`, using
`qwen-tts==0.1.1` and `torch==2.9.1`) and talks to it over JSON lines. On macOS
MLX already does that job in-process on Metal, so **we should not bring PyTorch
into SayIt.** What is worth porting are the features SayTheRest built around the
model, listed below.

## What SayTheRest does (Qwen-specific)

| Area | SayTheRest | SayIt today |
|---|---|---|
| Engine | Python subprocess, `Qwen3TTSModel` (PyTorch), resident, JSON-lines over stdio | In-process MLX `Qwen3TTS` in `SayItAgent` |
| Weights | Upstream `Qwen/Qwen3-TTS-12Hz-0.6B-Base` @ `5d83992…`, unquantized (fp32 CPU, bf16/fp16 CUDA) | `mlx-community/…-0.6B-Base-8bit` @ `50f45ef…` |
| Clone mode | ICL with `ref_text` (required since `073d654`); x-vector-only without a transcript in the worker | ICL with `refText`; transcript required (`transcriptRequired: true`) |
| Reference length | **3–45 s** for Qwen (`ddcefde`) | 3–30 s, 10–20 s recommended (Phase 1; was 3–15 s) |
| Studio passage | Longer, varied passage that includes a question | Two sentences, plus one more at ≥ 12 s target (`VoiceClonePassage`) |
| Reference source | **Record or import** a file | Record only (no audio-file import in the clone wizard) |
| Edit transcript later | **`POST /v1/voices/{id}/transcript`**, ≤ 2000 chars, also covers legacy profiles | Not possible; transcript is fixed at creation |
| Generation bounds | ≤ 160 chars per chunk, ≤ 512 codec frames per chunk, streamed to a temporary WAV | `TextChunker` + MLX cap `min(4096, max(75, tokens×6))` |
| Device policy | Auto/CPU, CUDA/XPU/MPS, thread caps, `nice(10)` | Metal via MLX (nothing to port) |
| Other Qwen models | Base 0.6B only | Base 0.6B, VoiceDesign 1.7B, CustomVoice 1.7B |

SayIt is ahead on model coverage. The real gaps are the five rows in bold, and
possibly precision (see Phase 3).

## Plan

### Phase 1: Longer references and a better passage (done, capped at 30 s)

Implemented:

- In `ModelCatalog.json`, `qwen3-06b-base-8bit` and
  `qwen3-17b-customvoice-8bit` now accept **3–30 s, with 10–20 s
  recommended** (previously 3–15 s, with 6–10 s recommended). Other
  cloning models are unchanged.
- `VoiceClonePassage` has a third tier (`longTargetDuration` = 20 s) that adds
  a closing question, in all 10 languages. It reads in about 20–25 s.
- Tests: catalog limits are checked to be ordered and ≤ 60 s, with Qwen's
  exact values pinned; `VoiceRecordingProcessor` accepts 29 s and rejects
  32 s; passage tiers extend each other and only the long tier asks a question.
- `InstalledModelSmokeTests` now reports `peakFootprintBytes` (the task's
  `ledger_phys_footprint_peak`, which includes Metal allocations).

**Benchmark** (2026-10-19, Apple M5 Max, Release test build, production
`SynthesisActor`, `qwen3-06b-base-8bit`, a fresh process per run, 2 runs
each). References were synthetic macOS `say` clips with exact transcripts.
"Short" text is 68 chars; "long" text is about 580 chars (≈ 30 s of audio).

| Reference | First audio (short / long) | RTF long | Peak footprint |
|---|---|---|---|
| none (generated voice) | 2.5–5.2 / 2.3 s | 0.25 | 7.9–8.5 GB |
| ~10 s | 1.2 / 1.1 s | 0.21–0.22 | 6.4–6.6 GB |
| ~21 s (new long passage) | 1.2 / 1.1–1.2 s | 0.21 | 8.0–8.1 GB |
| ~27 s | 1.3 / 1.2 s | 0.21 | 8.8–9.0 GB |
| ~42 s | 1.3–1.4 / 1.2 s | 0.23–0.24 | 10.7–10.9 GB |

Reference length has almost no effect on latency or throughput. Peak memory,
though, grows about 0.13 GB per reference second. That is far more than the
ICL prompt's KV cache (540 frames is only tens of MB), so the cost is most
likely in reference encoding. A 45 s reference costs about 4.3 GB more than a
10 s one, which is too much for 16 GB Macs. So the maximum is 30 s rather
than SayTheRest's 45 s. Speaker similarity at each length still needs a
listening evaluation. If the encoding peak can be reduced (for example by
chunked encoding or releasing the MLX cache), 45 s could be reconsidered.

### Phase 2: Import a reference file and edit transcripts (protocol + UI)

**Import a reference**

1. Clone wizard: add "Import audio…" (`NSOpenPanel` / `fileImporter`, plus drop
   onto the recording card) next to Record. Accept wav/m4a/mp3/aiff/caf.
2. Transfer the file the same way `importLocalModel` does (`AppState.swift:743`): a
   security-scoped bookmark goes to the agent, which decodes and normalizes it
   with `VoiceRecordingProcessor` (trim, analysis, duration limits) and registers
   it under the same `recordingID` the recorder path produces. That keeps
   `VoiceCloneRequest` unchanged.
3. Imported clips have no known passage, so the transcript step opens as an
   empty, required text field instead of being prefilled with the passage.

**Edit a transcript**

4. Add `ServiceCommand.updateVoiceTranscript(UUID, transcript: String)` in
   `SayItProtocol`. Trim it, require it to be non-empty, cap it at 2000
   characters, persist it through `VoiceProfileStore`, and bump `voicesRevision`.
5. Expose it on the matching HTTP route in `openapi.yaml` (`voices:write`
   scope) and a CLI subcommand (`sayit voices transcript <id> "…"`).
6. Add an editable "Reference transcript" field to `VoiceCustomizeSheet`. Its
   footer should explain that the transcript must match the recording word for word.
7. Tests: protocol round-trip, store persistence across reopen (including
   profiles saved without a transcript), HTTP validation (empty, too long, 404),
   and a `SynthesisActor` test showing that the edited transcript reaches
   `refText` and doesn't leak between profiles. SayTheRest's
   `saved_voice_transcript_reaches_qwen_worker_and_does_not_leak_between_profiles`
   is a good template.

**Optional: auto-transcribe imports.** SayTheRest doesn't do this. The pinned
`mlx-audio-swift` already ships `MLXAudioSTT` (Qwen3-ASR, Whisper, Parakeet).
The agent could prefill the transcript of an imported clip for the user to
confirm. It costs an extra model download, so make it opt-in and keep it in its
own PR.

### Phase 3: Precision A/B (decide with data)

SayTheRest runs unquantized weights; SayIt runs 8-bit. Before changing anything:

1. Add `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16` (rev `1eccf1cb2519b5a4e8a95b5f0544f3303568164f`,
   ≈ 2.5 GB) to `Scripts/ModelAudit/models.json` and run the existing audit
   (`Scripts/audit-tts-model.py`, `audit-tts-transcripts.py`) on 8-bit vs bf16
   with the same cloned references. Measure ASR WER, speaker similarity, RTF and
   peak memory.
2. If bf16 is clearly better, add it as a second catalog entry
   (`qwen3-06b-base-bf16`, high tier, "Best cloning fidelity"). Keep 8-bit
   as the default. Existing profiles are keyed by `modelType` (`qwen3_tts`),
   so they should carry over. Verify that.
3. Also available as candidates if wanted: `…-0.6B-CustomVoice-8bit` (a lighter
   CustomVoice) and `…-1.7B-Base-8bit` (≈ 3.1 GB).

### Phase 4: Long-text robustness check (verify, change only if needed)

SayTheRest added per-chunk bounds after it saw memory grow (`9350125`). Run a
long-form job (≈ 10k chars) with a 30–45 s cloned reference and watch agent
memory. If it grows without bound, cap Qwen chunk length in the chunker and
pass an explicit `maxTokens` (≈ 512 frames). Otherwise leave it alone.

## Explicitly not porting

- **PyTorch worker / uv runtime manager / CUDA device policy.** MLX already
  covers this, and better: Metal-native, in-process, no extra runtime download.
- **Legacy `config.json` repair.** It exists to fix a SayTheRest-specific
  installer bug.
- **x-vector-only cloning (no transcript).** The pinned MLX `Qwen3TTS`
  silently drops `refAudio` when `refText` is nil (`Qwen3TTS.swift` ~line 347),
  and SayTheRest itself now requires transcripts. If we ever want it, it is an
  upstream `mlx-audio-swift` change, not a SayIt one.

## If PyTorch ever becomes necessary

The only trigger would be a quality gap the Phase 3 bf16 A/B can't close. It
would be expensive:

- `SayItAgent` is sandboxed (`com.apple.security.app-sandbox`). Files a
  sandboxed process writes are quarantined, so a downloaded Python/torch
  runtime most likely can't be executed. The realistic options are bundling a
  signed Python + torch (several hundred MB added to the DMG) or a separate
  non-sandboxed signed helper. Either one needs a signing/notarization spike.
- PyTorch MPS is generally slower than MLX for this kind of autoregressive
  decoding, and some ops fall back to CPU.
- The design would mirror SayTheRest: a resident subprocess speaking JSON
  lines, owned by the agent, killed on unload. SayTheRest's `qwen_worker.py` and
  `crates/core/src/qwen.rs` are directly reusable as the reference.

## Suggested PR order

1. Phase 1: limits, passage, and benchmark (done).
2. Phase 2 transcript editing (protocol/HTTP/CLI/UI).
3. Phase 2 reference import.
4. Phase 3 audit results, and a bf16 catalog entry if justified.
5. Optional auto-transcription; Phase 4 only if the check fails.
