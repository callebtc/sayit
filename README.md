# Say It

Say It is a private, local text-to-speech app for Apple silicon Macs. It lives
in the menu bar and uses MLX Audio to generate speech without sending text to
a cloud service.

You can read selected text through macOS Services, read the clipboard with a
keyboard shortcut, replay previous items, and export generated audio.

## Requirements

- Apple-silicon Mac
- macOS 15 or later

## Install

1. Download the latest DMG from the project's Releases page.
2. Open the DMG and drag Say It into Applications.
3. Launch Say It and complete the initial model download.
4. Keep Say It running from its menu-bar icon.

Model weights are not bundled with the app. After a model is installed, speech
generation works offline.

## Use

- Select text in another app and choose **Services → Say It**.
- Copy text and press **Control–Option–S**.
- Choose **Read Clipboard** from the Say It menu.

The shortcut can be changed in Settings. Say It only reads the clipboard after
an explicit command.

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

The build script generates `SayIt.xcodeproj`, resolves MLX Audio Swift 0.1.3,
and creates an arm64 app in `Build/DerivedData/Build/Products/Release`.

## Tests

```sh
swift test --disable-sandbox --filter SayItCoreTests
```

Core tests do not download model weights.

## Privacy

Source text, generated audio, models, and history remain on the Mac. Network
access is used only for model downloads and update checks. Say It does not use
analytics, a microphone, or passive clipboard monitoring.

See [SECURITY.md](SECURITY.md) for security and privacy details.
