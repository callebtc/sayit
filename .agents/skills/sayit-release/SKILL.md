---
name: sayit-release
description: Build, sign, validate, notarize, and publish Say It macOS DMG releases using the repository release script. Use for Say It version bumps, release builds, installer packaging, notarization, and GitHub release assets.
metadata:
  compatibility: Requires the Say It repository, macOS, Xcode, XcodeGen, Developer ID signing, hdiutil, and gh.
---

# Say It Release

Use `Scripts/release.sh` as the single entrypoint. Once the release source is
prepared, one command builds, tests, signs, packages, validates, notarizes,
staples, and generates the signed update feed. **No visual review or Finder
interaction is required.** Honor any checkpoint the user explicitly requests.

## Prepare the release source

- Read `AGENTS.md`; inspect the source diff, current versions, and latest tag.
  Use `gh` to check main and the latest release when asked for the latest features.
- Use the requested version, or the next patch version if none is specified.
  Update `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in
  `project.yml` above the released build. Regenerate with
  `xcodegen generate --spec project.yml --project .` and check the diff.
- Resolve unrelated changes without discarding or silently including them.
  Commit the prepared source when authorized; the full release command requires
  a clean worktree. The local prepare-only mode allows the task's uncommitted
  version bump and fixes.
- Keep `.env.release` and signing material ignored. Never print configuration,
  private keys, or Keychain identities. Keep logs/artifacts under `Build/`; keep
  machine/user information out of Git history and GitHub. Preserve Git identity.

## Run one command

When authorized to build and notarize:

```sh
SAYIT_ALLOW_NOTARIZATION_UPLOAD=YES ./Scripts/release.sh VERSION
```

Replace `VERSION` with the prepared version. Signing and notarization settings
come from the existing ignored `.env.release`. The script uses
`Scripts/prepare-release-dmg.sh` for the shared build/test/package/audit pipeline;
do not copy or reconstruct these steps in temporary version-specific scripts.
Tests include the package suite with its MLX Metal library, DSP and muted playback
integration tests, and the selected-text XPC smoke test. The final compressed
DMG is audited before Apple submission and again after stapling. Failures stop
the pipeline. Do not bypass tests or disable secure timestamps.

For an explicitly local-only task:

```sh
./Scripts/release.sh --prepare VERSION
```

This produces the same signed, validated DMG without uploading. To check an
existing DMG without changing it, use `./Scripts/release.sh --audit VERSION`.
To later notarize an already prepared artifact without rebuilding it:

```sh
SAYIT_ALLOW_NOTARIZATION_UPLOAD=YES \
  ./Scripts/release.sh --notarize-existing VERSION RECORDED_SHA256
```

The script preserves existing DMGs, update assets, and submission records rather
than silently overwriting them. Inspect a previous attempt before retrying. If
Say It is running, arrange to quit it without interrupting active playback when
the build or XPC smoke test requires it.

## Keep DMG generation deterministic

`Scripts/package-local-dmg.sh` writes the layout directly using `dmg-layout.sh`,
then compresses, signs, and validates the read-only artifact. The preparation
helper also runs the layout regression suite. Do not replace this with Finder
automation, screenshots, sleeps, or manual icon positioning.

The picture background requires `icvp.backgroundType=2` **and all three
`backgroundColorRed/Green/Blue` fields set to 1.0**. Without the color fields,
Finder ignored both the picture and icon sizes. Preserve the fix and regression
coverage in `Scripts/dmg-layout.py` and `Scripts/test-dmg-layout.py`. Checks also
cover the background bytes and alias, window bounds, icon positions, Applications
link, and absence of private/temporary paths. These automated checks are the
release requirement; do not stop for visual approval.

## Deliver or publish

Report version/build, the versioned DMG, checksum, test status, and actual
notarization status. Full release output includes `Build/Update-VERSION/SayIt.dmg`
and signed `appcast.xml`. Keep pre-notarization and post-stapling hashes distinct.
Write a release description highlighting the biggest changes since the previous
release and publish both update assets together. GitHub upload/publication is
separate; follow [distribution.md](references/distribution.md)
when authorized. Do not claim an upload occurred merely because a script exists
or its workflow tests passed.
