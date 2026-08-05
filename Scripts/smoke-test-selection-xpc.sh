#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_root="$project_root/Build"
app_root="${SAYIT_APP_PATH:-$build_root/DerivedData-Release/Build/Products/Release/SayIt.app}"
app_executable="$app_root/Contents/MacOS/SayIt"
timeout_seconds="${SAYIT_SELECTION_SMOKE_TIMEOUT_SECONDS:-15}"

case "$timeout_seconds" in
    ''|*[!0-9]*|0)
        echo "SAYIT_SELECTION_SMOKE_TIMEOUT_SECONDS must be a positive integer." >&2
        exit 2
        ;;
esac

if [ ! -x "$app_executable" ]; then
    echo "The selected-text helper smoke test requires a built app." >&2
    exit 1
fi

if pgrep -x SayIt >/dev/null 2>&1; then
    echo "Quit every running copy of Say It before the selected-text helper smoke test." >&2
    exit 1
fi

smoke_log=$(mktemp "${TMPDIR:-/tmp}/sayit-selection-smoke.XXXXXX")
smoke_pid=
watchdog_pid=
cleanup() {
    if [ -n "$watchdog_pid" ]; then
        kill "$watchdog_pid" >/dev/null 2>&1 || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$smoke_pid" ]; then
        kill "$smoke_pid" >/dev/null 2>&1 || true
        wait "$smoke_pid" 2>/dev/null || true
    fi
    rm -f "$smoke_log"
}
trap cleanup EXIT HUP INT TERM

"$app_executable" --smoke-test-selection-xpc \
    >"$smoke_log" 2>&1 &
smoke_pid=$!
(
    sleep "$timeout_seconds"
    kill -TERM "$smoke_pid" >/dev/null 2>&1 || exit 0
    sleep 2
    kill -KILL "$smoke_pid" >/dev/null 2>&1 || true
) &
watchdog_pid=$!

status=0
wait "$smoke_pid" || status=$?
smoke_pid=
kill "$watchdog_pid" >/dev/null 2>&1 || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=

if [ "$status" -ne 0 ]; then
    echo "The selected-text helper XPC smoke test did not complete successfully." >&2
    exit 1
fi

rm -f "$smoke_log"
trap - EXIT HUP INT TERM
echo "Selected-text helper XPC smoke test passed."
