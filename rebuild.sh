#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"$project_root/Scripts/build-app.sh"
exec "$project_root/restart.sh"
