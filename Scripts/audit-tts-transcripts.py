#!/usr/bin/env python3
"""Transcribe synthetic audit samples locally; ASR is a diagnostic, not a MOS score."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "Build" / "ModelAudit"
os.environ.setdefault("HF_HOME", str(AUDIT / "hf-cache"))
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
spec = importlib.util.spec_from_file_location("audit_text", ROOT / "Scripts" / "audit-tts-model.py")
texts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(texts)


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        current = [i]
        for j, right in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--skip-existing", action="store_true")
    args = parser.parse_args()
    from huggingface_hub import HfApi, snapshot_download
    revision_file = ROOT / "Scripts" / "ModelAudit" / "asr.json"
    repo = "Systran/faster-whisper-small"
    if revision_file.exists():
        revision = json.loads(revision_file.read_text())["revision"]
    else:
        revision = HfApi(token=False).model_info(repo).sha
        revision_file.write_text(json.dumps({"repository": repo, "revision": revision}, indent=2))
    target = AUDIT / "models" / "asr"
    snapshot_download(repo, revision=revision, token=False, local_dir=target,
                      allow_patterns=["*.json", "*.txt", "model.bin"], max_workers=3)
    if args.download_only:
        return
    from faster_whisper import WhisperModel
    model = WhisperModel(str(target), device="cpu", compute_type="int8", cpu_threads=4)
    results_file = AUDIT / "results" / "transcripts.json"
    results = json.loads(results_file.read_text()) if args.skip_existing and results_file.exists() else []
    completed = {result["sample"] for result in results}
    for audio in sorted((AUDIT / "audio").glob("*.wav")):
        if audio.name in completed:
            continue
        name = audio.stem
        expected, language = (texts.LONG, "en") if "long" in name else (
            (texts.TURKISH, "tr") if "turkish" in name else (
                (texts.CHINESE, "zh") if "chinese" in name else (texts.SHORT, "en")))
        segments, info = model.transcribe(str(audio), language=language, beam_size=5,
                                          condition_on_previous_text=False, vad_filter=False)
        segments = list(segments)
        actual = " ".join(x.text.strip() for x in segments)
        def tokens(text):
            if language == "zh":
                return re.findall(r"[\u4e00-\u9fff]", text)
            return re.findall(r"\w+", text.lower())
        reference, hypothesis = tokens(expected), tokens(actual)
        result = {"sample": audio.name, "language": language, "expected": expected,
                  "transcript": actual, "asr_model_revision": revision,
                  "raw_cer" if language == "zh" else "raw_wer": distance(reference, hypothesis) / max(len(reference), 1),
                  "note": "Raw edit rate does not normalize numbers and abbreviations; inspect the transcript."}
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
        results_file.write_text(json.dumps(results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
