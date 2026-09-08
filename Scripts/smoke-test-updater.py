#!/usr/bin/env python3
"""Exercise Sparkle's actual replacement/relaunch using isolated fixture apps.

Requires the pinned Sparkle release tools/framework and the Say It update key
in the ignored .env file. Uses loopback only; never starts or replaces an installed Say It.
"""
import argparse
import http.server
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sparkle", type=Path, required=True, help="Sparkle distribution root")
    parser.add_argument("--output", type=Path, required=True, help="Fresh output directory")
    parser.add_argument("--tamper", choices=("feed", "archive"), help="Verify tampered downloads are rejected")
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sdk = args.sparkle.resolve()
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    key_file = Path(os.environ.get("SAYIT_UPDATE_KEY_FILE", str(project / ".env")))
    public_key = subprocess.check_output(
        ["xcrun", "swift", str(project / "Scripts/update-key.swift"), "public", str(key_file)],
        text=True, env=env).strip()
    signer = str(project / "Scripts/sparkle-tool.py")
    domain = f"gui/{os.getuid()}"
    app_id = "sh.sayit.mac.update-test"
    # This identity is deliberately separate from every production/local app.
    subprocess.run(["defaults", "delete", app_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    requests = []
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(output), **kwargs)
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    feed_url = f"http://127.0.0.1:{server.server_port}/"
    helper_pids = []
    fixture_process = None
    try:
        for index in (1, 2):
            label = f"sh.sayit.update-fixture.{index}"
            # Fail rather than touching another concurrent fixture's jobs.
            exists = subprocess.run(["launchctl", "print", f"{domain}/{label}"], capture_output=True)
            if exists.returncode == 0:
                raise RuntimeError("Another update fixture is already running")
            helper = {"Label": label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": True}
            path = output / f"helper-{index}.plist"
            path.write_bytes(plistlib.dumps(helper))
            run("launchctl", "bootstrap", domain, str(path))
            helper_pids.append(label)
        sources = sorted((project / "Sources/SayIt/Updates").glob("*.swift"))
        binary = output / "UpdateFixture"
        run("xcrun", "swiftc", "-swift-version", "6", "-D", "SAYIT_UPDATE_TEST_BUILD",
            "-module-cache-path", str(output / "ModuleCache"), "-F", str(sdk),
            "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            *map(str, sources), str(project / "Sources/SayItXPC/ServiceJobTermination.swift"),
            str(project / "Scripts/UpdateSmokeTest/Fixture.swift"), "-o", str(binary), env=env)
        for version in (1, 2):
            app = output / f"v{version}" / "Say It Update Test.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Frameworks").mkdir()
            shutil.copy2(binary, contents / "MacOS/UpdateFixture")
            run("ditto", str(sdk / "Sparkle.framework"), str(contents / "Frameworks/Sparkle.framework"))
            info = {
                "CFBundleIdentifier": app_id, "CFBundleExecutable": "UpdateFixture",
                "CFBundleName": "Say It Update Test", "CFBundlePackageType": "APPL",
                "CFBundleVersion": str(version), "CFBundleShortVersionString": f"0.0.{version}",
                "LSMinimumSystemVersion": "15.0", "SUFeedURL": feed_url + "appcast.xml",
                "SUPublicEDKey": public_key, "SUEnableAutomaticChecks": False,
                "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True,
                "SURequireSignedFeed": True, "SUEnableSystemProfiling": False,
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                "FixtureRoot": str(output),
            }
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            run("codesign", "--force", "--deep", "--sign", "-", str(app))
        run("ditto", "-c", "-k", "--keepParent", str(output / "v2/Say It Update Test.app"), str(output / "SayIt.zip"))
        # Remove the unpacked new app before launch so LaunchServices cannot pick it.
        shutil.rmtree(output / "v2")
        run(signer, str(sdk / "bin/generate_appcast"), "--maximum-deltas", "0",
            "--download-url-prefix", feed_url, "-o", str(output / "appcast.xml"), str(output))
        run(signer, str(sdk / "bin/sign_update"), "--verify", str(output / "appcast.xml"))
        if args.tamper == "feed":
            feed = output / "appcast.xml"
            data = feed.read_bytes()
            assert b"<title>" in data
            feed.write_bytes(data.replace(b"<title>", b"<title>Modified ", 1))
        elif args.tamper == "archive":
            with (output / "SayIt.zip").open("ab") as stream:
                stream.write(b"modified after signing")
        app = output / "v1/Say It Update Test.app"
        fixture_process = subprocess.Popen([str(app / "Contents/MacOS/UpdateFixture")])
        deadline = time.monotonic() + 90
        while not (output / "success").exists():
            if (output / "failure").exists():
                if args.tamper:
                    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                    assert info["CFBundleVersion"] == "1"
                    assert not (output / "prepared").exists()
                    if args.tamper == "feed":
                        assert not any(path.endswith(".zip") for path in requests)
                    for label in helper_pids:
                        run("launchctl", "print", f"{domain}/{label}", stdout=subprocess.DEVNULL)
                    print(f"PASS: tampered {args.tamper} rejected before helper shutdown or app replacement")
                    return
                raise RuntimeError((output / "failure").read_text())
            if time.monotonic() >= deadline:
                raise TimeoutError("The fixture did not finish its update and relaunch")
            time.sleep(0.25)
        assert args.tamper is None, "A tampered update was installed"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert info["CFBundleVersion"] == "2"
        assert (output / "prepared").exists()
        for label in helper_pids:
            run("launchctl", "print", f"{domain}/{label}", stdout=subprocess.DEVNULL)
        print("PASS: signed feed, archive verification, helper shutdown, app replacement, relaunch and helper restart")
    finally:
        server.shutdown()
        if fixture_process is not None and fixture_process.poll() is None:
            fixture_process.terminate()
            fixture_process.wait(timeout=10)
        for label in helper_pids:
            subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], capture_output=True)
        subprocess.run(["defaults", "delete", app_id], capture_output=True)


if __name__ == "__main__":
    main()
