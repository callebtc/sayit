#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_root="$project_root/Build/DerivedData-Local/Build/Products/Release/SayIt.app"
cli="$app_root/Contents/Helpers/SayItCLI.app/Contents/MacOS/sayit"
bundle_identifier="sh.sayit.mac.local"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -x "$app_root/Contents/MacOS/SayIt" ] || [ ! -x "$cli" ]; then
    echo "No runnable Release build was found. Run ./rebuild.sh first." >&2
    exit 1
fi

# Keep a previously installed development CLI pointed at the local app that
# this script launches. Leave production installs and unrelated commands alone.
path_cli=$(command -v sayit 2>/dev/null || true)
if [ -n "$path_cli" ] && [ -L "$path_cli" ]; then
    linked_cli=$(readlink "$path_cli")
    case "$linked_cli" in
        "$project_root"/Build/*/SayIt.app/Contents/Helpers/SayItCLI.app/Contents/MacOS/sayit)
            if [ "$linked_cli" != "$cli" ]; then
                ln -sfn "$cli" "$path_cli"
                echo "Updated the development sayit command: $path_cli"
            fi
            ;;
    esac
fi

if pgrep -x SayIt >/dev/null 2>&1; then
    echo "Stopping Say It…"
    osascript -e "tell application id \"$bundle_identifier\" to quit"

    attempts=0
    while pgrep -x SayIt >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            echo "Say It did not quit within 10 seconds." >&2
            exit 1
        fi
        sleep 0.1
    done
fi

"$launch_services" -f "$app_root"

echo "Starting Say It…"
open -n "$app_root"

attempts=0
until pgrep -x SayIt >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
        echo "Say It did not start within 10 seconds." >&2
        exit 1
    fi
    sleep 0.1
done

echo "Waiting for the background service…"
attempts=0
until "$cli" service status >/dev/null 2>&1; do
    if ! pgrep -x SayIt >/dev/null 2>&1; then
        echo "Say It exited before its background service was ready." >&2
        exit 1
    fi

    attempts=$((attempts + 1))
    if [ "$attempts" -ge 200 ]; then
        echo "The Say It background service did not start within 20 seconds." >&2
        exit 1
    fi
    sleep 0.1
done

echo "Say It and its background service are running: $app_root"
