#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
catalog="$project_root/Sources/SayItCore/Resources/ModelCatalog.json"

plutil -lint "$project_root/Config/Info.plist"
plutil -lint "$project_root/Config/SayIt.entitlements"
python3 -m json.tool "$catalog" >/dev/null
echo "Catalog and bundle metadata are valid."
