# Software updates

Say It uses Sparkle 2.9.6 to verify and install updates in place. Update Now
consents to download, install, and restart. Active speech and recording stop
before installation. Models, voices, history, API credentials, service
preferences, and CLI symlinks remain in place.

Checks run daily while the app is running. A background discovery adds an
indicator to the menu bar; the offer opens when the user next interacts with
Say It. Later suppresses automatic reminders for 24 hours across app launches.
Manual checks always bypass this delay. Turning checks off suppresses automatic
reminders and network checks. Updates are never installed without consent.

The updater is disabled in Debug, Local, and Model Audit builds. An installed
production app must run from a writable location; apps launched from a DMG or
translocated by macOS should first be moved into Applications. macOS can request
administrator authorization when the user does not own the installed app.

## Release configuration

The app embeds a public Ed25519 key. Its matching private seed is stored as
`SAYIT_SPARKLE_PRIVATE_KEY` in the ignored `.env` file, with mode 0600.
`Scripts/update-key.swift create .env` creates a new seed and prints only its
public key. This refuses to overwrite an existing file. Use it only during
initial setup; do not regenerate the key for each release. Back up `.env`
securely and never commit, print, or upload it.

Signing reads this file through `Scripts/sparkle-tool.py` and passes the seed to
Sparkle over stdin with `--ed-key-file -`. No Keychain access is used. The helper
never places the private seed in command arguments or output. Override the file
location with `SAYIT_UPDATE_KEY_FILE` when working in another checkout.

Use `SAYIT_UPDATE_FEED_URL` for the GitHub repository's
`releases/latest/download/appcast.xml` URL. The former GitHub API setting is no
longer used. `SAYIT_SPARKLE_TOOLS_DIR` optionally locates Sparkle's
`generate_appcast` and `sign_update` tools; the default uses the SwiftPM artifact
under the build package cache.

After notarization and stapling, the release script prepares an ignored
`Build/Update-VERSION` directory containing:

- `SayIt.dmg`: a byte-identical copy of the final notarized DMG.
- `appcast.xml`: a signed feed referencing that version's immutable tag-specific
  DMG URL, archive signature, length, minimum OS, and build/display versions.

The generator refuses to reuse an output directory or sign with a key that does
not match the app. It verifies both signatures and the archive URL and size.
The production build verifies Sparkle's embedded components. Code signing runs
inside-out, including Sparkle's executable, XPC services, app, and framework.

Upload **both** assets to the same GitHub draft with `gh`, inspect the draft, and
publish it as latest only through the normal release approval process. Do not
edit or replace assets after publication. Increment `CURRENT_PROJECT_VERSION`
for every release and keep stable releases in the feed. Retain older tag assets
so a client that already downloaded an older feed can complete its update.

Current manual-only versions require one last manual installation to acquire
Sparkle. This implementation does not publish a release or retroactively change
those installed versions.

## Validation

Run the `SayItUpdateTests` Xcode scheme, the package suite, the local app build,
and catalog validation. The updater tests use isolated defaults and no network.

For a real installation test, use:

```sh
./Scripts/smoke-test-updater.py --sparkle SPARKLE_DISTRIBUTION --output Build/UpdateSmokeTest
```

The smoke test compiles tiny apps with a dedicated test identity and an explicit
test-only loopback feed. It signs the feed/archive using the ignored update key,
starts two isolated launchd helpers, clicks Update Now programmatically, and
verifies helper shutdown, replacement, relaunch, and helper restart. It saves a
screenshot of the actual offer and removes the fixture jobs and defaults on exit.
It never replaces or starts an installed Say It application. Repeat with
`--tamper feed` and `--tamper archive`, using fresh output directories, to verify
rejection before helpers are stopped or the installed fixture is replaced.

Before distributing the first release, additionally exercise a production-signed,
notarized older-to-newer upgrade. Confirm Accessibility permission continuity,
CLI/HTTP functionality, active model download cancellation, disabled services,
read-only installs, administrator authorization, and unchanged persisted data.
Local fixture success is not a substitute for this distribution check.
