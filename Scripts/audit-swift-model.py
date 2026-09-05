#!/usr/bin/env python3
"""Run production SynthesisActor tests using an isolated Xcode test profile."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "Build" / "ModelAudit"
spec = importlib.util.spec_from_file_location("audit_text", ROOT / "Scripts" / "audit-tts-model.py")
texts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(texts)


def execute(template, key, name, values):
    config = plistlib.loads(template.read_bytes())
    def visit(value):
        if isinstance(value, dict):
            if "EnvironmentVariables" in value and "TestBundlePath" in value:
                env = value["EnvironmentVariables"]
                for k in list(env):
                    if k.startswith("SAYIT_MODEL_AUDIT_"):
                        del env[k]
                env.update(values)
                env.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(config)
    # __TESTROOT__ must retain the original products directory.
    runfile = template.parent / f"audit-{key}-{name}.xctestrun"
    runfile.write_bytes(plistlib.dumps(config))
    logfile = AUDIT / f"{key}-{name}-swift.log"
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(runfile),
               "-destination", "platform=macOS,arch=arm64",
               "-only-testing:SayItBackendTests/InstalledModelSmokeTests",
               "-parallel-testing-enabled", "NO"]
    environment = os.environ | {"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
    with logfile.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, env=environment,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            status = 124
    log = logfile.read_text()
    result = {"model": key, "case": name, "backend": "SayIt SynthesisActor", "exit_code": status}
    match = re.search(r"MODEL_AUDIT_RESULT (.+)", log)
    if match:
        for field, value in re.findall(r"(\w+)=([^\s]+)", match[1]):
            try:
                value = float(value)
            except ValueError:
                pass
            result[field] = value
    result["synthesis_observed"] = match is not None
    result["import_observed"] = "MODEL_AUDIT_IMPORT_RESULT" in log
    (AUDIT / "results" / f"{key}-{name}-swift.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    return status == 0 and (result["import_observed"] if name == "import" else match is not None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model", choices=["breeze", "index"])
    parser.add_argument("--case", choices=["all", "import", "short", "long", "chinese", "clone"], default="all")
    args = parser.parse_args()
    products = AUDIT / "TestProducts"
    if not products.exists():
        products = ROOT / "Build" / "DerivedData-Local" / "Build" / "Products"
    templates = list(products.glob("SayItBackendTests*.xctestrun"))
    if len(templates) != 1:
        raise SystemExit("Build the SayItBackendTests scheme for testing first.")
    (AUDIT / "results").mkdir(exist_ok=True)
    (AUDIT / "audio").mkdir(exist_ok=True)
    model_id = "breeze-2-4bit" if args.model == "breeze" else "index-tts-15"
    if args.case in ("all", "import"):
        ok = execute(templates[0], args.model, "import", {
            "SAYIT_MODEL_AUDIT_IMPORT_ID": model_id,
            "SAYIT_MODEL_AUDIT_IMPORT_SOURCE": str(AUDIT / "models" / args.model),
        })
        if not ok or args.case == "import":
            raise SystemExit(0 if ok else 1)
    models = Path.home() / "Library" / "Application Support" / "Say It Model Audit" / "Models"
    cases = [("short", texts.SHORT, "en"), ("long", texts.LONG, "en"),
             ("chinese", texts.CHINESE, "zh")]
    if args.model == "breeze":
        cases.append(("clone", texts.SHORT, "en"))
    failures = 0
    for name, text, language in cases:
        if args.case not in ("all", name):
            continue
        env = {"SAYIT_MODEL_AUDIT_ID": model_id,
               "SAYIT_MODEL_AUDIT_ROOT": str(models),
               "SAYIT_MODEL_AUDIT_TEXT": text,
               "SAYIT_MODEL_AUDIT_LANGUAGE": language,
               "SAYIT_MODEL_AUDIT_VOICE_DESCRIPTION": "A calm, clear adult voice with natural pacing.",
               "SAYIT_MODEL_AUDIT_OUTPUT": str(AUDIT / "audio" / f"{args.model}-{name}-swift.wav")}
        if args.model == "index" or name == "clone":
            env.update(SAYIT_MODEL_AUDIT_REFERENCE=str(AUDIT / "audio" / "reference.wav"),
                       SAYIT_MODEL_AUDIT_REFERENCE_TEXT=texts.SHORT)
        if not execute(templates[0], args.model, name, env):
            failures += 1
            # A failure on the simplest prompt is a viability finding. Diagnose
            # it before scheduling expensive longer generations.
            if name == "short":
                break
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
