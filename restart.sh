#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_root="$project_root/Build/DerivedData/Build/Products/Release/SayIt.app"
bundle_identifier="com.sayit.mac"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

"$project_root/Scripts/build-app.sh"

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

echo "Say It is running: $app_root"
