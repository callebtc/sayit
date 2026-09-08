#!/usr/bin/env python3
"""Pass the ignored .env signing seed to Sparkle over stdin, never Keychain."""
import base64
import os
from pathlib import Path
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        raise ValueError("A Sparkle tool path is required")
    tool = Path(sys.argv[1])
    if tool.name not in {"sign_update", "generate_appcast"}:
        raise ValueError("Unsupported Sparkle tool")
    if any(arg in {"--account", "--ed-key-file", "-f", "-s"} for arg in sys.argv[2:]):
        raise ValueError("Signing keys must come only from the environment file")
    env_file = Path(os.environ.get("SAYIT_UPDATE_KEY_FILE", str(Path(__file__).resolve().parent.parent / ".env")))
    lines = env_file.read_text().splitlines()
    keys = [line.removeprefix("SAYIT_SPARKLE_PRIVATE_KEY=") for line in lines if line.startswith("SAYIT_SPARKLE_PRIVATE_KEY=")]
    if len(keys) != 1 or len(base64.b64decode(keys[0], validate=True)) != 32:
        raise ValueError("Invalid update signing seed")
    result = subprocess.run([str(tool), "--ed-key-file", "-", *sys.argv[2:]], input=keys[0], text=True)
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError):
        print("Update signing failed: check the ignored .env signing seed and Sparkle tool path.", file=sys.stderr)
        sys.exit(1)
