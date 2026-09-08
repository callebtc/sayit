#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 -m venv "$project_root/Build/DMGTools"
"$project_root/Build/DMGTools/bin/python3" -m pip install -r "$project_root/Scripts/dmg-tools-requirements.txt"
