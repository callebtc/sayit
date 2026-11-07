# Underdog Woof — November 7, 2026

**Decision: add Underdog Woof as an experimental English model.** It is a
40.6 MB download with two preset voices, Juno and Mira, and runs natively in
Say It through MLX Swift. No Python, ONNX, or converted weights are involved.

## Model

[Underdog Woof](https://huggingface.co/ConwayResearch/Underdog-Woof) is pinned
to revision `be702960539777fc3f698e54335276a8391b00f9`. Say It downloads three
files with SHA-256 checksums: `woof_int8.npz` (40,595,426 bytes), `LICENSE`, and
`NOTICE`, totaling 40,603,957 bytes. The release ships a NumPy runtime rather
than MLX weights, so it has no `config.json` or `.safetensors` file; snapshot
validation accepts the NumPy weights for this model type only.

The 38.24M-parameter model has two parts:

- **Speech model.** An eight-layer causal transformer (448 wide, seven heads,
  rotary positions) reads a 16-vector voice prompt and the characters to speak.
  A four-block flow head turns each transformer state and a normal draw into one
  32-dimensional latent per 40 ms frame. An end-of-speech logit stops the frame
  loop. Weights are int8 with a scale per row.
- **Audio decoder.** Underdog adapted it from Kyutai's Mimi: a two-layer
  transformer with a 250-frame causal window, followed by a causal SEANet stack
  that upsamples 960 times to 24 kHz mono. Weights are int8 with one scale per
  group of 32 values.

## Integration

`WoofModel` conforms to MLX Audio's `SpeechGenerationModel`, so Woof uses the
existing synthesis, progressive playback, cancellation, unloading, and audit
paths. `NumPyArchive` reads the uncompressed `.npz` directly; NumPy writes ZIP64
placeholder sizes in local headers, so members are located through the central
directory. Weights are dequantized to `float32` once, as they load.

`SynthesisActor` gives Woof one sentence per chunk and, as for Kokoro, generates
each chunk inside the serialized synthesis operation, so a cancelled request
never leaves Woof work running. Woof normalizes the chunk, and a sentence over
120 characters is split near its middle at the clearest boundary with the
existing `TextChunker`, preferring clause punctuation. An early version split at the
last space before 120 characters; ending an utterance mid-clause made the model
repeat its final word until the frame limit. Woof's documented runtime also
redraws a take that stalls or runs far too long; Say It keeps the best of up to
four takes. A take fails on a pause of one second or more inside the speech, or
when it runs longer than 0.095 seconds per character plus 1.5 seconds for the
silence Woof leaves at both ends. Without that allowance every line under about
15 characters, such as "Thank you.", was drawn four times. A take that reaches
twice that length is stopped as a runaway, and utterances with no English
letters, such as an emoji line or a `* * *` break, are skipped: Woof cannot end
them and would otherwise run to its 30-second frame limit.

Woof reads the characters it receives literally, so numbers need expanding
first. The Underdog license treats the model's code as part of the model, and
its derivatives must be shared under the same non-commercial terms. To keep Say
It's code under MIT, `WoofTextNormalizer` is Say It's own, smaller rule set:
phone numbers, money, clock times, percentages, ordinals, years and decades,
ranges, decimals, signs, and remaining digits. Woof's optional pronunciation
lexicon for unusual names is not used.

## Validation

Hardware: Apple M5 Max, macOS 26. Measurements are local observations, not
cross-device benchmarks.

- **Numerical parity with the NumPy reference.** With the same latents, the
  decoder's mean absolute difference was 8.7e-5 against a mean signal level of
  0.025. Replaying the reference's 90 noise draws, the speech model stopped on
  the same frame; latents differed by 5e-4 at the first frame and stayed
  bounded through the utterance.
- **Speed.** A warm 3.64-second sentence took 0.43 seconds on the GPU, matching
  the NumPy reference on one CPU thread. The MLX CPU device was about six times
  slower. Through `SynthesisActor` in a fresh process, a 48.3-second
  three-paragraph passage took 5.9 seconds, with first audio after 0.65 seconds.
  The first use in a process also compiles Metal kernels.
- **Memory.** Each weight is dequantized and evaluated as it loads, so MLX
  peaked at 166 MB during load and held 152 MB afterward. Speaking a
  1,100-character paragraph peaked at about 960 MB.
- **Speech.** Both voices passed the existing `InstalledModelSmokeTests` audio
  checks after a production download. Local `whisper.cpp` (`base.en`)
  transcribed a sentence with a phone number, a time, an ordinal, a price, and
  a long clause verbatim for both voices. The three-paragraph passage, covering
  decades, percentages, three currencies, ranges, times, a version number, and a
  phone number, also transcribed correctly.

## Licensing and credit

Woof uses the
[Underdog Non-Commercial License 1.0](https://huggingface.co/ConwayResearch/Underdog-Woof/blob/be702960539777fc3f698e54335276a8391b00f9/LICENSE).
Personal, research, teaching, and non-profit use is free; commercial use needs
a license from Underdog. The catalog marks commercial use as not allowed and
license acceptance as required. The model note in Settings → Models and the
README credit "Voice by Underdog Woof (underdog.ai)". The note is plain text:
the license also asks for a link to underdog.ai wherever Woof audio plays, so a
linked credit in the player remains to be added.

## Limits

- English only, with two preset voices. Voice cloning, voice design, and native
  speaking pace are not available.
- The text normalizer does not expand units, URLs, email addresses,
  abbreviations, or numeric dates such as 2024-11-07. It reads standalone
  four-digit numbers from 1000 to 2099 as years, and `ddd-dddd` or
  `ddd ddd dddd` as a phone number. A minus between a number and a space and a
  whole number reads as a range, so `+5 -3` becomes "plus five to three".
- Speech naturalness and long-session reliability have not been evaluated
  beyond these checks.
