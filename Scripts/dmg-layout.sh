#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python="$project_root/Build/DMGTools/bin/python3"
[ -x "$python" ] || {
    echo 'DMG tools are missing. Run ./Scripts/setup-dmg-tools.sh first.' >&2
    exit 1
}
exec "$python" "$project_root/Scripts/dmg-layout.py" "$@"
