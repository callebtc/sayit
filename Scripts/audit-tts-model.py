#!/usr/bin/env python3
"""Evaluate candidates outside the Swift backend; writes only synthetic audio.

Run with the isolated audit venv. Times exclude downloading and separate load
from generation. RTF means wall seconds / audio seconds (lower is better).
"""
import argparse
import json
import os
from pathlib import Path
import resource
import time

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "Build" / "ModelAudit"
os.environ.setdefault("HF_HOME", str(AUDIT / "hf-cache"))
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

SHORT = "Today is a calm day. This is a short test of clear, natural speech."
LONG = (
    "The train leaves at 4:45 p.m. on Wednesday, September 9, 2026. "
    "A return ticket costs $27.50, and children under twelve travel for half price. "
    "Please bring your ID, check platform three, and arrive fifteen minutes early. "
    "If the departure time changes, the station will announce the updated schedule. "
    "After the journey, we will walk through the old town, visit the small museum, "
    "and have lunch beside the river. There is no need to hurry. "
    "Take a deep breath, look around, and enjoy the afternoon."
)
TURKISH = "Bugün hava çok güzel. Tren saat dört kırk beşte kalkacak. Lütfen istasyona on beş dakika erken gelin."
CHINESE = "今天是平静的一天。这是一次清晰自然的语音测试。"


def download(key):
    from huggingface_hub import snapshot_download
    manifest = json.loads((ROOT / "Scripts" / "ModelAudit" / "models.json").read_text())[key]
    target = AUDIT / "models" / key
    snapshot_download(
        manifest["repository"], revision=manifest["revision"],
        local_dir=target, token=False, max_workers=4,
        ignore_patterns=["*.md", ".gitattributes", "*.py", "*.pyc"],
    )
    return target, manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model", choices=["supertonic", "voxcpm", "breeze", "index"])
    parser.add_argument("--download-only", action="store_true")
    args = parser.parse_args()
    target, manifest = download(args.model)
    if args.download_only:
        print(json.dumps({"model": args.model, "revision": manifest["revision"], "downloaded": True}))
        return

    import numpy as np
    import soundfile as sf
    load_start = time.perf_counter()
    if args.model == "supertonic":
        from supertonic import TTS
        model = TTS(model="supertonic-3", model_dir=target, auto_download=False,
                    intra_op_num_threads=4, inter_op_num_threads=1)
        rate = model.sample_rate
        def generate(text, lang, mode):
            style = model.get_voice_style("F1" if mode == "female" else "M1")
            wav, durations = model.synthesize(text, voice_style=style, lang=lang)
            yield np.asarray(wav).reshape(-1)[:int(float(np.asarray(durations).reshape(-1)[0]) * rate)]
    elif args.model == "voxcpm":
        import mlx.core as mx
        from mlx_audio.tts.utils import load
        model = load(str(target))
        mx.eval(model.parameters())
        rate = model.sample_rate
        def generate(text, lang, mode):
            mx.random.seed(42)
            options = {"inference_timesteps": 7, "max_tokens": 1500}
            if mode == "clone":
                options["ref_audio"] = str(AUDIT / "audio" / "reference.wav")
            else:
                options["instruct"] = "A calm, clear adult voice with natural pacing."
            for result in model.generate(text=text, **options):
                mx.eval(result.audio)
                yield np.asarray(result.audio).reshape(-1)
    elif args.model == "index":
        import mlx.core as mx
        from mlx_audio.tts.utils import load
        # Preserve the pinned snapshot. Only redirect the Python runtime's
        # tokenizer lookup to its already downloaded local tokenizer.
        local = AUDIT / "models" / "index-python"
        local.mkdir(exist_ok=True)
        for source in target.iterdir():
            if source.is_file() and source.name != "config.json":
                destination = local / source.name
                if not destination.exists():
                    os.link(source, destination)
        config = json.loads((target / "config.json").read_text())
        config["tokenizer_name"] = str(target)
        (local / "config.json").write_text(json.dumps(config))
        model = load(str(local))
        mx.eval(model.parameters())
        rate = model.sample_rate
        def generate(text, lang, mode):
            mx.random.seed(42)
            for result in model.generate(text=text, ref_audio=str(AUDIT / "audio" / "reference.wav")):
                mx.eval(result.audio)
                yield np.asarray(result.audio).reshape(-1)
    else:
        raise SystemExit("Use InstalledModelSmokeTests for Swift-native Breeze evaluation.")
    load_seconds = time.perf_counter() - load_start
    cases = [("short-cold", SHORT, "en", "default"),
             ("short-warm", SHORT, "en", "default"),
             ("long", LONG, "en", "default"),
             ("turkish", TURKISH, "tr", "default")]
    if args.model == "index":
        cases[-1] = ("chinese", CHINESE, "zh", "clone")
    else:
        cases.append(("female" if args.model == "supertonic" else "clone", SHORT, "en",
                      "female" if args.model == "supertonic" else "clone"))
    if args.model == "voxcpm":
        cases.append(("clone-warm", SHORT, "en", "clone"))
    (AUDIT / "audio").mkdir(exist_ok=True)
    (AUDIT / "results").mkdir(exist_ok=True)
    for name, text, lang, mode in cases:
        began = time.perf_counter()
        pieces, first_audio = [], None
        for piece in generate(text, lang, mode):
            if first_audio is None:
                first_audio = time.perf_counter() - began
            pieces.append(piece)
        seconds = time.perf_counter() - began
        audio = np.concatenate(pieces)
        duration = len(audio) / rate
        result = dict(model=args.model, revision=manifest["revision"], case=name,
                      text=text, language=lang, load_seconds=load_seconds,
                      generation_seconds=seconds, first_audio_seconds=first_audio,
                      audio_seconds=duration, rtf=seconds / duration,
                      audio_events=len(pieces), sample_rate=rate,
                      finite=bool(np.isfinite(audio).all()),
                      peak=float(np.max(np.abs(audio))),
                      rms=float(np.sqrt(np.mean(audio.astype(np.float64)**2))),
                      clipped_fraction=float(np.mean(np.abs(audio) >= 1)),
                      process_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        if args.model in ("voxcpm", "index"):
            result["mlx_peak_memory_bytes"] = mx.get_peak_memory()
        assert result["finite"] and result["rms"] > 0.0001 and duration > 0.1, result
        sf.write(AUDIT / "audio" / f"{args.model}-{name}.wav", audio, rate)
        if args.model == "supertonic" and name == "short-cold":
            reference = AUDIT / "audio" / "reference.wav"
            if not reference.exists():
                sf.write(reference, audio, rate)
        (AUDIT / "results" / f"{args.model}-{name}.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
