# TTS model viability experiment

This branch evaluates Breeze TTS 2, IndexTTS 1.5, Supertonic 3, and VoxCPM2.
Vireo is tracked separately because its weights require Hugging Face access.
Only Breeze is added to the app catalog, with experimental status. The other
candidates remain evaluation evidence and are not integrated.

## Isolation

Build the app with `SAYIT_MODEL_AUDIT_BUILD=1`. It uses a separate bundle ID,
background service, selection service, preferences domain, model/history data,
and API/Hugging Face Keychain namespaces. It skips legacy data migration,
legacy service removal, and initial global shortcut registration.
The normal development and production apps retain their identities.

Use distinct derived-data directories for the app and the test build. Switching
`ENABLE_TESTABILITY` in the same Xcode build cache can leave incompatible MLX
objects behind. Keep downloaded weights, logs, audio, and test products under
the ignored `Build/ModelAudit` directory.

## Python evaluations

From the repository root:

```sh
uv venv Build/ModelAudit/venv --python 3.12
uv pip install --python Build/ModelAudit/venv/bin/python -r Scripts/ModelAudit/requirements.txt
Build/ModelAudit/venv/bin/python Scripts/audit-tts-model.py supertonic
Build/ModelAudit/venv/bin/python Scripts/audit-tts-model.py voxcpm
```

`models.json` pins exact model revisions. Downloads are anonymous and telemetry
is disabled by the scripts. No user documents, voice recordings, or other
personal content are used. The Supertonic short sample provides the synthetic
voice reference for the cloning cases.

Supertonic runs with four ONNX intra-op threads, one inter-op thread, and SDK
defaults for synthesis. VoxCPM2 uses seven inference timesteps, seed 42, and a
1,500-token limit. Both run in their upstream Python implementations, not in
Say It's Swift backend. This distinction is essential when assessing support.

## Swift evaluations

Build the `SayItBackendTests` scheme for testing in Release with
`ENABLE_TESTABILITY=YES`, `SWIFT_COMPILATION_MODE=singlefile`, and
`SAYIT_LOCAL_SWIFT_FLAG='-DSAYIT_LOCAL_BUILD -DSAYIT_MODEL_AUDIT_BUILD'`.
The normal project requirement to disable code signing for local test builds
also applies. Preserve the complete products directory, including its
`.xctestrun`, at `Build/ModelAudit/TestProducts` before building the app.

```sh
Build/ModelAudit/venv/bin/python Scripts/audit-tts-model.py breeze --download-only
Build/ModelAudit/venv/bin/python Scripts/audit-swift-model.py breeze
```

The Swift runner imports the pinned local snapshots through `ModelManager` into
the isolated profile, then exercises production `SynthesisActor` with short
English, a longer passage, Chinese, and reference audio where supported.
Each case is a fresh test process, so Swift measurements include model loading.
Failed short synthesis stops that model's remaining cases for diagnosis.

The historical native IndexTTS results were recorded at commit `ba1618a`,
which contains the temporary catalog entry and Swift runner used for that test.
The final catalog excludes IndexTTS 1.5. To investigate its reading failures
independently of the Swift path,
run `audit-tts-model.py index`. It uses the same snapshot and synthetic reference
through Python, with only a local tokenizer-path override in an ignored copy of
the configuration. The original snapshot is preserved.

The `SayItModelCatalogTests` scheme runs the focused catalog suite without
building the audio runtime. The final evaluation passed all eight catalog tests
and fourteen model resolver/manager regression tests.

## Interpretation

RTF is generation wall time divided by audio duration; below 1 is faster than
playback. Python reports model load time separately. Swift reports end-to-end
time including model load. First-audio time measures an emitted waveform, not
speaker-device latency. Multiple Swift audio events may be subdivisions of an
already completed waveform; event count alone does not establish streaming.

Process peak RSS and MLX peak memory are different measurements. Neither is the
download size. Repeat timing without compilation or another inference job before
making performance recommendations. A handful of prompts cannot establish
language coverage, voice similarity, or long-form reliability generally.

```sh
Build/ModelAudit/venv/bin/python Scripts/audit-tts-transcripts.py
```

The recognizer runs locally on CPU. Its transcripts help find missing/repeated
words, but raw WER does not normalize numbers or abbreviations. ASR agreement is
not a subjective naturalness score, and synthetic-reference cloning is not a
test of performance on real microphone recordings.
