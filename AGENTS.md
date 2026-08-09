# Repository Guidelines

## Project Structure & Module Organization

`Sources/` is organized by Swift Package Manager target. `SayIt/` contains the
SwiftUI menu-bar app, while `SayItCore/`, `SayItBackend/`, `SayItProtocol/`, and
`SayItXPC/` separate shared logic, services, wire types, and IPC. Supporting
targets include `SayItHTTP/`, `SayItCLI/`, `SayItAgent/`, and
`SayItSelectionAgent/`. Tests mirror these modules under `Tests/*Tests/`;
fixtures belong beside their suite. App resources live in
`Sources/SayIt/Resources/`, configuration in `Config/`, build automation in
`Scripts/`, and README media in `public/`. The static landing page lives in
`public/index.html` (self-contained, no build step). Treat `project.yml` as the
source of truth for the generated `SayIt.xcodeproj`.

## Build, Test, and Development Commands

- `./Scripts/build-app.sh` regenerates the Xcode project and produces a local
  Release app in `Build/`.
- `swift test --disable-sandbox` runs the package test suite.
- `swift test --disable-sandbox --filter TextChunkerTests` runs one suite while
  iterating.
- `./Scripts/validate-catalog.sh` validates the model catalog, plist, and
  entitlements.
- `xcodegen generate --spec project.yml` refreshes the Xcode project after
  target or build-setting changes.

Development requires macOS 15+, Apple silicon, Xcode with Swift 6.2+, and
XcodeGen.

## Coding Style & Naming Conventions

Use four-space indentation and follow nearby Swift formatting. Name types in
`UpperCamelCase` and methods, properties, and test functions in
`lowerCamelCase`. Keep one primary type per file and organize app code by
feature. Preserve strict Swift concurrency: prefer value types, `Sendable`,
actors, and structured `async` work. Use modern SwiftUI APIs and ensure controls
remain keyboard- and VoiceOver-accessible. No repository formatter is
configured; warnings are treated as errors, so keep builds warning-free.

## Testing Guidelines

Most tests use Swift Testing (`@Suite`, `@Test`, and `#expect`); UI automation
uses XCTest. Name files `FeatureTests.swift` and write behavior-focused test
names. Add regression coverage in the owning module, keep tests deterministic,
and use fixtures instead of network dependencies. There is no fixed coverage
threshold, but changed logic should exercise success and failure paths.

## Commit & Pull Request Guidelines

Use a concise, imperative subject consistent with history, such as
`Fix release timestamp validation` or `Add global selected-text shortcut`.
Keep commits focused. Pull requests should explain behavior and risk, list
commands run, link relevant issues, and include screenshots or video for UI
changes.

## Security & Agent Conduct

Never commit credentials, `.env.release`, generated build products, or user
data. Never expose personally identifiable machine or user information in Git
history, GitHub issues, or pull requests. Use `gh` for GitHub operations, and
never override the configured Git author or committer identity.
