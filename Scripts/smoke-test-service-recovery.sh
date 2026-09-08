#!/bin/sh
# Exercise real launchd cleanup with an isolated label; never touch production jobs.
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sayit-service-recovery.XXXXXX")
label="sh.sayit.mac.recovery-test.$(uuidgen | tr '[:upper:]' '[:lower:]')"
target="gui/$(id -u)/$label"
cleanup() {
    launchctl bootout "$target" >/dev/null 2>&1 || true
    rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

cat > "$test_root/RecoverySmoke.swift" <<'SWIFT'
import Foundation

@main
struct RecoverySmoke {
    static func main() async throws {
        let arguments = CommandLine.arguments
        try await LegacyServiceJobRecovery.removeConflict(
            label: arguments[1],
            machServiceName: arguments[1],
            agentURL: URL(filePath: "/bin/sleep"),
            bundledPlistURL: URL(filePath: arguments[2])
        )
    }
}
SWIFT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    "$project_root/Sources/SayItXPC/ServiceJobManager.swift" \
    "$project_root/Sources/SayItXPC/LegacyServiceJobRecovery.swift" \
    "$test_root/RecoverySmoke.swift" -o "$test_root/recovery-smoke"

# A sleeping fixture stands in for a running older helper. Register a Mach
# endpoint just like the stale manual job, using a unique test-only service name.
/usr/bin/plutil -create xml1 "$test_root/agent.plist"
/usr/bin/plutil -insert Label -string "$label" "$test_root/agent.plist"
/usr/bin/plutil -insert ProgramArguments -xml '<array><string>/bin/sleep</string><string>60</string></array>' "$test_root/agent.plist"
/usr/bin/plutil -insert RunAtLoad -bool YES "$test_root/agent.plist"
/usr/bin/plutil -insert MachServices -xml "<dict><key>$label</key><true/></dict>" "$test_root/agent.plist"
launchctl bootstrap "gui/$(id -u)" "$test_root/agent.plist"
launchctl print "$target" >/dev/null
"$test_root/recovery-smoke" "$label" "$test_root/Example.app/Contents/Library/LaunchAgents/agent.plist"
if launchctl print "$target" >/dev/null 2>&1; then
    echo "FAIL: the stale test job is still registered." >&2
    exit 1
fi
# Recovery must also be idempotent when no old job remains.
"$test_root/recovery-smoke" "$label" "$test_root/Example.app/Contents/Library/LaunchAgents/agent.plist"
echo "PASS: isolated stale job removed; repeated recovery succeeded."
