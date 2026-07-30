# Say It

Private, local text-to-speech for Apple silicon Macs. Say It turns selected or
copied text into speech with open models running through
[MLX Audio](https://github.com/Blaizzy/mlx-audio)—your text and generated audio
stay on your Mac.

<table>
  <tr>
    <td width="46%"><img src="public/resources/player.png" alt="Say It menu-bar player"></td>
    <td width="54%"><img src="public/resources/models.png" alt="Say It model library"></td>
  </tr>
</table>

<p align="center">
  <a href="public/resources/introducing.mp4">Watch the introduction</a>
</p>

## Highlights

- **Speak from anywhere.** Select text in another app and press the configurable
  selection hotkey, choose **Services → Say It**, or use the separate clipboard
  hotkey.
- **A native menu-bar player.** Read the clipboard, pause, seek, change playback
  speed, follow the spoken text, and revisit history without leaving your
  current app.
- **Open models from Hugging Face.** Download supported MLX models in the app,
  including [Qwen3 TTS](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit),
  [Kokoro](https://huggingface.co/mlx-community/Kokoro-82M-bf16),
  [Chatterbox](https://huggingface.co/mlx-community/Chatterbox-TTS-fp16), and
  [OmniVoice](https://huggingface.co/mlx-community/OmniVoice). Compatible
  community models can be added by Hugging Face repository ID.
- **Create voices.** Models expose the features they support, from built-in
  voices and voice descriptions to random voice discovery and voice cloning.
- **Efficient model loading.** Only one model is kept in memory, and it is
  automatically unloaded after a configurable period of inactivity (ten
  minutes by default).
- **Local by design.** Synthesis works offline after model download. There is no
  analytics, cloud inference, or passive clipboard monitoring.

## Clone your voice

For models with voice-cloning support, Voice Studio guides you through recording
or importing a clean reference sample, checks its quality, and saves it as a
reusable voice profile. You stay in control of the recording: voice samples and
profiles remain on your Mac, and cloning runs locally.

Only clone a voice when you have the speaker's permission.

## Getting started

Say It requires macOS 15 or later on an Apple silicon Mac.

1. Install and launch Say It.
2. Choose and download a model during onboarding.
3. Optionally allow Accessibility access, select text in another app, and press
   **Control–Option–S**. You can also copy text and press
   **Control–Option–V**, or choose **Services → Say It**.

Both shortcuts can be changed in Settings. Say It queries the current selection
or reads clipboard text only when you explicitly invoke the matching action.

### Terminal

The app includes a `sayit` CLI for speech, playback, models, voices, and
automation:

```sh
sayit "Read this aloud"
printf 'Read standard input' | sayit
sayit status
sayit pause
sayit resume
```

Run `sayit --help` to see all commands and options.

## Architecture

The native SwiftUI frontend is separate from a per-user backend service that
owns model downloads, synthesis, playback, and history. The app and CLI talk to
that service over XPC. A narrowly scoped accessibility helper retrieves the
frontmost app's selection only when requested. An optional, token-protected HTTP
server exposes the same synthesis engine to other local apps through a
versioned REST API bound to `127.0.0.1`.

The synthesis layer is built primarily on
[MLX Audio](https://github.com/Blaizzy/mlx-audio), with the native Swift
integration provided by
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift).

## Build from source

Install Xcode with Swift 6.2 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen), then run:

```sh
brew install xcodegen
./Scripts/build-app.sh
```

Local builds compile independent targets and Swift source batches in parallel,
using all available logical CPUs by default. Set `SAYIT_BUILD_JOBS` to cap the
number of concurrent build operations. Signed release builds keep whole-module
optimization; set `SAYIT_SWIFT_COMPILATION_MODE=wholemodule` to reproduce that
behavior in an ad-hoc local build.

For a stable Accessibility grant across Debug rebuilds, set
`SAYIT_SELECTION_SIGN_IDENTITY` to the same Apple Development signing identity
used for the app. The build does not select a certificate from your keychain
automatically.

Tests run with `swift test --disable-sandbox`.

## Make a release

The release workflow is automated, but publishing to GitHub is deliberately
separate. The script builds and tests the app, applies Developer ID signatures
with secure timestamps, creates the DMG, submits it to Apple's notarization
service, staples the ticket, mounts the result, and audits its signatures and
contents.

One time only:

1. Copy `.env.release.example` to `.env.release` and set the Developer ID
   Application identity. A certificate SHA-1 fingerprint avoids ambiguity when
   Keychain contains multiple certificates with the same display name.
2. Store App Store Connect notarization credentials in Keychain:

   ```sh
   xcrun notarytool store-credentials "sayit-notary" \
     --apple-id "YOUR_APPLE_ID" \
     --team-id "YOUR_TEAM_ID" \
     --password "YOUR_APP_SPECIFIC_PASSWORD"
   ```

For each release, update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`project.yml`, commit that release state, then run:

```sh
SAYIT_ALLOW_NOTARIZATION_UPLOAD=YES ./Scripts/release.sh 0.1.0
```

Replace `0.1.0` with the committed marketing version. The explicit environment
flag authorizes that run's upload to Apple. The script stops if the Git
worktree is dirty, a test or signature check fails, notarization is rejected,
or the mounted DMG contains a local user path. It prints the final DMG path and
SHA-256 checksum but does not create a GitHub release or upload anything to
GitHub.

## More screenshots

[Voice cloning](public/resources/cloning.png)

## License

Say It is available under the [MIT License](LICENSE). Models are distributed
under their own licenses; review the model card before downloading or using one.
