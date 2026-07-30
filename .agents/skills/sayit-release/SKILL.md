---
name: sayit-release
description: Prepare, build, sign, notarize, validate, tag, and publish versioned macOS DMG releases for the Say It project. Use this skill whenever the user mentions a Say It release, version bump, production DMG, Developer ID signing, Apple notarization or stapling, a GitHub Release/tag/asset, or asks whether a build is ready to distribute—even if they request only one stage. Enforce privacy-safe, explicit-upload boundaries and use the repository release scripts plus gh.
compatibility: Requires macOS, Xcode, XcodeGen, notarytool, codesign, hdiutil, Git, and GitHub CLI. Expects Scripts/release.sh and project.yml in the repository.
---

# Say It Release

Create repeatable macOS releases without exposing signing material, account
details, or local-machine information. Treat preparation, Apple notarization,
GitHub draft upload, and public publication as separate authorization stages.

## Start by determining the authorized stage

Map the user's request to one or more stages:

1. **Inspect** — report readiness without changing files or contacting external
   services.
2. **Prepare** — update the version/build number, regenerate the Xcode project,
   test, and commit locally when requested. Do not upload.
3. **Notarize** — build the final DMG and upload it to Apple's notarization
   service. This requires explicit Apple-upload approval in the current request.
4. **Draft on GitHub** — create the tag/release draft and upload the approved
   DMG. This requires explicit GitHub-upload approval in the current request.
5. **Publish on GitHub** — make the verified draft public. Require explicit
   publication approval after the draft has been inspected.

A request to build a DMG does not authorize notarization. A request to notarize
does not authorize GitHub upload. A request to prepare a GitHub release does not
authorize making a draft public unless the user clearly asks to publish it.

## Protect private information

- Read the repository's `AGENTS.md` instructions before doing release work.
- Never read, print, summarize, copy, commit, or upload a `.p8`, `.p12`, private
  key, password, Keychain secret, or provisioning-profile payload.
- Never print `.env.release`. Check only that it exists and is ignored.
- Do not place certificate fingerprints, API key IDs, issuer IDs, Apple Account
  identifiers, email addresses, usernames, device names, local absolute paths,
  or GitHub account identifiers in commits, tags, release notes, or assets.
- Do not enumerate every Keychain identity in user-visible output. Let the
  release script perform its filtered identity check.
- Before any Git or GitHub action, scan staged content, the commit message,
  release title, and release notes for local paths and personally identifying
  information.
- Confirm `.env.release`, `*.p8`, `*.p12`, `*.key`, `*.cer`,
  `*.provisionprofile`, and generated release artifacts are ignored.
- Use `gh` for GitHub releases. Never use raw GitHub HTTP requests when `gh`
  supports the operation.
- Preserve the configured Git author and committer. Never override either
  identity.

Public product data such as the product name, semantic version, public bundle
identifiers already stored in tracked project files, and the public organization
name present in a Developer ID signature may be reported when necessary. Do not
add unrelated signing metadata merely because it is technically public.

## Inspect the repository safely

Run read-only checks first:

```sh
git status --short
git diff --check
git tag --list --sort=-version:refname
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' project.yml
test -x Scripts/release.sh
test -x Scripts/build-app.sh
test -x Scripts/package-local-dmg.sh
sh -n Scripts/release.sh Scripts/build-app.sh Scripts/package-local-dmg.sh
git check-ignore -q .env.release
```

Do not continue to a production release from a dirty worktree. Existing changes
may belong to the user or another task; do not stash, discard, reset, or commit
them without authorization. Report the blocker and let the user finish or
approve those changes.

Check that the machine-local setup exists without exposing its values:

```sh
test -f .env.release
```

The local setup is reusable on the configured Mac. A new Mac needs its own
Developer ID identity/private key, provisioning profiles, ignored
`.env.release`, and `notarytool` Keychain profile. If an identity, profile, or
API key is expired, revoked, or unavailable, stop and rotate it; never weaken
signing to work around the failure.

## Prepare a version

Use the version explicitly requested by the user. Prefer tags in the form
`vMAJOR.MINOR.PATCH`; Say It's update checker removes the leading `v` or `V`.

1. Update `MARKETING_VERSION` in `project.yml`.
2. Increment `CURRENT_PROJECT_VERSION`; it must be a positive, monotonically
   increasing integer.
3. Regenerate the tracked Xcode project:

   ```sh
   xcodegen generate --spec project.yml --project .
   ```

4. Review only the intended version/generated-project diff.
5. Run `git diff --check`.
6. Commit the release state locally only when authorized, using a generic
   message such as `Prepare 1.2.3 release`.
7. Confirm the worktree is clean and the release commit is the exact commit
   intended for the tag.

Do not tag yet. First create and inspect the notarized artifact so a failed
Apple submission cannot leave behind a misleading release tag.

## Build and notarize the production DMG

Run this stage only after explicit permission to upload to Apple:

```sh
release_version=1.2.3
SAYIT_ALLOW_NOTARIZATION_UPLOAD=YES \
  ./Scripts/release.sh "$release_version"
```

Never set `SAYIT_ALLOW_DIRTY_WORKTREE=YES` or `SAYIT_SKIP_TESTS=YES` for a
production release.

The repository script is responsible for:

- running the Swift test suite;
- regenerating and building the Release app;
- applying Developer ID signatures and secure timestamps;
- verifying hardened runtime for the app and bundled helpers;
- creating and signing `Build/SayIt-VERSION.dmg`;
- submitting the DMG to Apple and waiting for `Accepted`;
- stapling and validating the ticket;
- running Gatekeeper, code-signature, disk-image, and mounted-content checks;
- checking the mounted app for local user paths; and
- printing the final SHA-256 checksum and notarization submission ID.

Stop if any check fails. Do not tag or upload a failed or partially processed
artifact. If notarization fails, retrieve the log only when useful:

```sh
xcrun notarytool log SUBMISSION_ID \
  --keychain-profile PROFILE_NAME \
  Build/notarization-log.json
```

Keep the log under ignored `Build/`, inspect it for private paths before quoting
it, and report only redacted issue summaries.

## Inspect the final artifact locally

The production artifact is:

```text
Build/SayIt-VERSION.dmg
```

Do not substitute a file whose name contains `-local` or `-signed-local`.

The release script already performs mechanical validation. Before GitHub
upload, also let the user inspect the DMG and, when practical, test installation
and launch on a compatible clean user account or another Mac. Record the
SHA-256 checksum shown by the script. Do not modify, repackage, or re-sign the
DMG after notarization; rebuild and notarize again if its contents change.

## Create a GitHub draft and upload the DMG

Run only after explicit GitHub-upload permission and after confirming that the
tested release commit is available on the remote repository. Use variables so
commands remain version-independent:

```sh
release_version=1.2.3
release_tag="v$release_version"
release_commit=$(git rev-parse HEAD)
release_dmg="Build/SayIt-$release_version.dmg"
```

Recheck the artifact checksum and repository state. Then create a draft release
against the exact reviewed commit:

```sh
gh release create "$release_tag" \
  "$release_dmg#Say It $release_version for macOS" \
  --target "$release_commit" \
  --draft \
  --title "Say It $release_version" \
  --generate-notes
```

`gh release create` creates the tag when it does not exist and uploads the DMG
as a release asset. A draft is intentionally not public.

If the tag or release already exists, inspect it with `gh release view` and
stop. Never overwrite, delete, retarget, or replace an existing release asset
without explicit approval.

Verify the draft metadata:

```sh
gh release view "$release_tag" \
  --json tagName,targetCommitish,isDraft,isPrerelease,assets,url
```

Confirm that:

- the tag is the requested version;
- the target is the reviewed release commit;
- the release is still a draft;
- exactly the intended DMG asset is attached; and
- no local path or private identifier appears in the title, notes, or label.

For higher assurance, download the draft asset to an explicit temporary
directory and compare its SHA-256 with the local approved artifact. Remove only
that validated temporary directory afterward.

## Publish the GitHub release

Require explicit approval to make the inspected draft public:

```sh
gh release edit "$release_tag" --draft=false --latest
```

Verify the result:

```sh
gh release view "$release_tag" \
  --json tagName,isDraft,isPrerelease,assets,publishedAt,url
```

The app's update checker reads the latest GitHub Release tag and links users to
the release page. A published release with the DMG asset therefore provides the
download without embedding account or signing credentials in the app.

## Report the outcome

State only the stages actually completed. Include:

- version and build number;
- local artifact path, when one was created;
- SHA-256 checksum;
- whether Apple notarization was accepted and stapled;
- whether GitHub state is absent, draft, or public;
- GitHub release URL only after it exists; and
- any remaining compatibility caveats.

Explicitly say when no Apple or GitHub upload occurred. Never claim a release is
ready merely because compilation succeeded; the production DMG must complete
the release script and local inspection first.
