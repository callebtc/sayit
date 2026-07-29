# Say It

Say It is a private, local text-to-speech service for Apple silicon Macs. Its
menu-bar app, command-line tool, and opt-in loopback API all use the same
per-user background service and MLX Audio engine without sending source text
to a cloud service.

You can read selected text through macOS Services, read the clipboard with a
keyboard shortcut, replay previous items, and export generated audio.

## Requirements

- Apple-silicon Mac
- macOS 15 or later

## Install

1. Download the latest DMG from the project's Releases page.
2. Open the DMG and drag Say It into Applications.
3. Launch Say It and complete the initial model download.
4. Leave the background service enabled in **Settings → Service**.

Model weights are not bundled with the app. After a model is installed, speech
generation works offline.

## Use

- Select text in another app and choose **Services → Say It**.
- Copy text and press **Control–Option–S**.
- Choose **Read Clipboard** from the Say It menu.

The shortcut can be changed in Settings. Say It only reads the clipboard after
an explicit command.

### Command line

The signed `sayit` executable is bundled inside the app. Settings shows its
location and a command for linking it into `~/.local/bin`.

```sh
sayit "Read this aloud"
printf 'Read standard input' | sayit
sayit --interrupt --detach "Read this now"
sayit status
sayit pause
sayit resume
sayit clear
```

Run `sayit --help` for model, voice, language, rate, pace, queue, JSON, and
long-text options.

### Local HTTP API

The versioned REST API is disabled by default. Enable it in
**Settings → Service**, create a scoped token, then send it only in the
`Authorization` header:

```sh
curl \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"text":"Hello from local automation"}' \
  http://127.0.0.1:59125/v1/jobs
```

The API binds only to `127.0.0.1`. Its OpenAPI 3.1 document is available at
`/v1/openapi.json`; state changes can be followed at `/v1/events` with
Server-Sent Events.

## Build from source

Install:

- Xcode with Swift 6.2 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Then run:

```sh
brew install xcodegen
./Scripts/build-app.sh
open Build/DerivedData/Build/Products/Release/SayIt.app
```

The build script generates `SayIt.xcodeproj`, resolves the declared Swift
packages, builds and signs the app, background agent, and CLI, then creates an
arm64 app in `Build/DerivedData/Build/Products/Release`.

## Tests

```sh
swift test --disable-sandbox
```

Core tests do not download model weights.

## Privacy

Source text, generated audio, models, history, settings, and diagnostics remain
on the Mac. Network access is used only for model downloads and update checks;
the optional automation API is loopback-only. Say It does not use analytics, a
microphone, or passive clipboard monitoring.

See [SECURITY.md](SECURITY.md) for security and privacy details.
