#!/usr/bin/env python3
"""Exercise release orchestration without building or contacting Apple/GitHub."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

RELEASE_SCRIPT = Path(__file__).with_name("release.sh")


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir()
        (self.root / "Build").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shutil.copyfile(RELEASE_SCRIPT, self.scripts / "release.sh")
        (self.root / ".env.release").write_text("SAYIT_NOTARY_PROFILE=workflow-test\n")
        self.log = self.root / "events"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_RELEASE_EVENTS=str(self.log))
        self.env.pop("SAYIT_ALLOW_NOTARIZATION_UPLOAD", None)
        self.executable(self.bin / "git", '''#!/bin/sh
if [ "$1" = status ] && [ "${TEST_RELEASE_DIRTY:-0}" = 1 ]; then echo ' M project.yml'; fi
''')
        self.executable(self.bin / "codesign", "#!/bin/sh\necho codesign >> \"$TEST_RELEASE_EVENTS\"\n")
        self.executable(self.bin / "spctl", "#!/bin/sh\necho gatekeeper >> \"$TEST_RELEASE_EVENTS\"\n")
        self.executable(self.bin / "xcrun", '''#!/bin/sh
set -eu
echo "$1 $2" >> "$TEST_RELEASE_EVENTS"
case "$1 $2" in
    'notarytool history') ;;
    'notarytool submit')
        if [ "${TEST_RELEASE_SUBMIT_FAIL:-0}" = 1 ]; then exit 1; fi
        printf '{"status":"%s","id":"test-submission"}' "${TEST_RELEASE_STATUS:-Accepted}" ;;
    'stapler staple') printf 'ticket' >> "$3" ;;
    'stapler validate') ;;
    *) exit 99 ;;
esac
''')
        self.executable(self.scripts / "prepare-release-dmg.sh", '''#!/bin/sh
set -eu
if [ "$1" = --audit ]; then
    echo audit >> "$TEST_RELEASE_EVENTS"
    [ "${TEST_RELEASE_AUDIT_FAIL:-0}" != 1 ]
else
    echo prepare >> "$TEST_RELEASE_EVENTS"
    [ "${TEST_RELEASE_PREPARE_FAIL:-0}" != 1 ]
    printf artifact > "Build/SayIt-$1.dmg"
fi
''')
        self.executable(self.scripts / "prepare-update-feed.sh", '''#!/bin/sh
set -eu
echo updates >> "$TEST_RELEASE_EVENTS"
mkdir "$3"
cp "$1" "$3/SayIt.dmg"
printf feed > "$3/appcast.xml"
''')

    def executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_release(self, *args, upload=False, **env):
        command_env = dict(self.env, **env)
        if upload:
            command_env["SAYIT_ALLOW_NOTARIZATION_UPLOAD"] = "YES"
        return subprocess.run(["sh", str(self.scripts / "release.sh"), *args],
                              env=command_env, capture_output=True, text=True)

    def events(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def existing_artifact(self):
        path = self.root / "Build/SayIt-1.2.3.dmg"
        path.write_bytes(b"artifact")
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_full_release_orders_checks_and_creates_updates(self):
        result = self.run_release("1.2.3", upload=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["notarytool history", "prepare", "notarytool submit",
                                        "stapler staple", "stapler validate", "codesign",
                                        "gatekeeper", "audit", "updates"])
        build = self.root / "Build"
        self.assertEqual((build / "Update-1.2.3/SayIt.dmg").read_bytes(), b"artifactticket")
        before = (build / "release-1.2.3-pre-notarization.sha256").read_text().split()[0]
        after = (build / "release-1.2.3-notarized.sha256").read_text().split()[0]
        self.assertNotEqual(before, after)

    def test_local_modes_never_contact_apple(self):
        for mode, event in [("--prepare", "prepare"), ("--audit", "audit")]:
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                result = self.run_release(mode, "1.2.3")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.events(), [event])

    def test_upload_requires_authorization(self):
        self.assertNotEqual(self.run_release("1.2.3").returncode, 0)
        self.assertEqual(self.events(), [])

    def test_failed_preparation_never_submits(self):
        result = self.run_release("1.2.3", upload=True, TEST_RELEASE_PREPARE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), ["notarytool history", "prepare"])

    def test_rejection_never_staples_or_publishes(self):
        result = self.run_release("1.2.3", upload=True, TEST_RELEASE_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), ["notarytool history", "prepare", "notarytool submit"])
        saved = json.loads((self.root / "Build/notarization-1.2.3.json").read_text())
        self.assertEqual(saved["status"], "Invalid")

    def test_resume_uses_exact_existing_bytes_without_building(self):
        checksum = self.existing_artifact()
        result = self.run_release("--notarize-existing", "1.2.3", checksum, upload=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events()[:3], ["notarytool history", "audit", "notarytool submit"])
        self.assertNotIn("prepare", self.events())

    def test_wrong_resume_checksum_never_contacts_apple(self):
        self.existing_artifact()
        result = self.run_release("--notarize-existing", "1.2.3", "0" * 64, upload=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), [])

    def test_failed_resume_audit_never_submits(self):
        checksum = self.existing_artifact()
        result = self.run_release("--notarize-existing", "1.2.3", checksum, upload=True,
                                  TEST_RELEASE_AUDIT_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), ["notarytool history", "audit"])

    def test_full_release_preserves_existing_artifact(self):
        checksum = self.existing_artifact()
        self.assertNotEqual(self.run_release("1.2.3", upload=True).returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertEqual(hashlib.sha256((self.root / "Build/SayIt-1.2.3.dmg").read_bytes()).hexdigest(), checksum)

    def test_previous_submission_blocks_duplicate_upload(self):
        (self.root / "Build/notarization-1.2.3.json").write_text('{}')
        self.assertNotEqual(self.run_release("1.2.3", upload=True).returncode, 0)
        self.assertEqual(self.events(), [])

    def test_dirty_release_does_not_build_or_submit(self):
        result = self.run_release("1.2.3", upload=True, TEST_RELEASE_DIRTY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), [])


if __name__ == "__main__":
    unittest.main()
