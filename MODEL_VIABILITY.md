# TTS model viability — September 5, 2026

Three candidates merit further work: **Supertonic 3 for lightweight reading,
VoxCPM2 for multilingual voice features, and Breeze TTS 2 as a native Swift
experiment. IndexTTS 1.5 should not be recommended on these results.** Vireo
could not be tested because the available Hugging Face access was unauthorized.

This experiment uses the `codex/tts-model-viability` branch and an isolated
**Say It Model Audit** app. The existing development app and production
background service remained running. No remote branch or release was published.

## Measured results

Hardware: Apple M5 Max, 128 GiB RAM, macOS 26.6.2. Swift inference uses
`mlx-audio-swift` revision `bf14ae0c26e4e85553dd989571cae29d70fa6735`.
Python inference uses `mlx-audio 0.5.1` and `supertonic 1.3.1`.

| Candidate | Tested execution path | Short generation / audio | Long generation / audio | Assessment |
|---|---|---:|---:|---|
| Supertonic 3 | Python, ONNX CPU | 0.98 s / 5.19 s, warm | 6.42 s / 36.22 s | Best lightweight backend candidate; about 0.75 GB peak process RSS |
| VoxCPM2 8-bit | Python, MLX | 3.15 s / 5.12 s, warm | 15.93 s / 35.68 s | Promising multilingual option; about 3.53 GB peak process RSS and 9.04 GB peak MLX allocation |
| Breeze TTS 2 4-bit | Say It production Swift synthesis | 14.41 s / 5.28 s | 54.88 s / 42.16 s | Functional, but substantial time to first audio |
| IndexTTS 1.5 | Say It production Swift synthesis | 5.00 s / 4.78 s | 13.25 s / 22.70 s | Reject for recommendation: apparent omissions invalidate the attractive timing |

Python times exclude model loading; the final runs loaded Supertonic in 0.33 s
and VoxCPM2 in 1.10 s. Swift cases each start a fresh process and include model
loading. These columns are not a controlled runtime speed comparison. First-audio
time was effectively the full generation time in these tested paths. The two
Swift audio events were delivery subdivisions, not progressive model inference.

## Candidate findings

**[Supertonic 3](https://huggingface.co/Supertone/supertonic-3)** passed finite,
non-silent audio checks for short and longer English, Turkish, and male/female
presets. Short English transcribed exactly after punctuation normalization.
Turkish retained the sentence content, with the recognizer rendering spoken
numbers as digits. The ticket price in the longer passage produced an ambiguous
ASR result and needs targeted listening/number tests. The model download is about
415 MB. It would require an ONNX backend or a port; it has not been integrated
into the app. The public package provides presets, not a tested offline workflow
for building arbitrary custom voice embeddings. The model uses OpenRAIL-M.

**[VoxCPM2](https://huggingface.co/mlx-community/VoxCPM2-8bit)** passed short and
long English, Turkish, and synthetic-reference cloning checks. Short English
and cloned speech transcribed exactly. The long transcript retained the text
and the intended ticket price. Seven inference timesteps were used. A first-use
clone in the initial run took 40.27 s; the final run took 4.10 s for its first
clone and 2.33 s for a repeated clone, both producing 4.80 s of audio. Startup
behavior therefore needs explicit attention. There is no VoxCPM2 implementation
in the pinned Swift runtime, so this is a port/backend project, not a catalog
entry. The snapshot is about 3.23 GB and uses Apache 2.0.

**[Breeze TTS 2](https://huggingface.co/mlx-community/Breeze-TTS-2-mlx-4bit)**
passed native short English, long English, Chinese, and reference-cloning tests.
Short English, Chinese, and cloned speech transcribed exactly after punctuation
normalization. The long sample's price was recognized as $27.70 rather than
$27.50; listening is needed to distinguish synthesis from recognition error.
Cloning produced 4.48 s of audio in 5.92 s. The audit app imported and selected
Breeze, exposed its voice-description control, played a preview, and reached the
end of the playback timeline. Native generation buffers the whole text chunk;
the longer test waited almost 55 s for its first audio. Keep it experimental.
Its roughly 3.04 GB snapshot and research/non-commercial license also matter.
Cloning passed at the backend level; the catalog still needs complete recording
requirements before exposing Breeze in the voice-cloning wizard.

**[IndexTTS 1.5](https://huggingface.co/mlx-community/IndexTTS-1.5)** produced
finite, audible samples, but local recognition found substantive omissions:

- Expected “Today is a calm day. This is a short test of clear, natural speech.”
  The Swift sample transcribed as “Today is a short test of clear natural speech.”
- The Chinese sample appeared to omit its first sentence.
- The long sample appeared to skip much of its opening schedule/price content.

Say It's chunk diagnostics confirm that the complete text reached synthesis.
A comparison using the same weights and reference in Python reproduced reading
problems. This does not establish whether the root cause is the checkpoint,
shared MLX implementation assumptions, reference conditioning, or another issue;
it does rule out treating this as merely a missing catalog entry. It also needs
reference audio, and Say It's cloning wizard currently excludes models that
cannot be selected for ordinary reading. Do not promote it until both reading
accuracy and the reference-only UI workflow are addressed.

**[Vireo](https://huggingface.co/mchen04/Vireo-TTS-3B-MLX-mixed4bit)** returned
HTTP 401 / `GatedRepoError` when checking access to its pinned configuration.
No new agreement was accepted. No inference or compatibility claim is made.

## Evidence and limits

- Eight catalog tests and fourteen model resolver/manager tests passed.
- Breeze: four native synthesis cases passed waveform checks. IndexTTS: three
  native and four Python cases produced audio, but reading accuracy was poor.
- Supertonic: five final Python cases. VoxCPM2: six final Python cases.
- All evaluated waveforms were finite and non-silent. Local ASR used pinned
  `Systran/faster-whisper-small` on CPU. Chinese raw CER does not normalize
  simplified/traditional character variants. Raw WER does not normalize numbers.
- These are a small synthetic prompt suite and one synthetic reference voice.
  They do not establish subjective naturalness, general language coverage,
  microphone-recording clone quality, cancellation behavior, or hours-long
  narration reliability. No generated audio was uploaded to a cloud service.

[Machine-readable results](Scripts/ModelAudit/results.json),
[reproduction instructions](Scripts/ModelAudit/README.md), and
[local listening page](Build/ModelAudit/listen.html) are included in the worktree.
Downloaded weights, audio, build products, and raw logs remain in ignored local
directories; the branch records only code, synthetic-text metrics, and findings.
