# GitHub distribution

The release script handles notarization, stapling, validation, and signed update
assets. Continue here only when authorized to upload or publish on GitHub.

## Release description

Before creating the draft, write `Build/release-notes-VERSION.md`. Compare the
previous published tag with the release commit (`git log PREVIOUS_TAG..COMMIT`
and relevant diffs/PRs). Lead with a concise list of the biggest user-visible
features and fixes; group under Added, Improved, or Fixed only when useful.
Include installation/update instructions and current system requirements where
relevant. Use the previous release's description for style, not as a list of
changes to copy. Omit internal release tooling unless it affects users. Do not
claim notarization or update readiness before validation succeeds.

## GitHub draft and publication

Use `gh`. Check the intended tag/release does not already exist before creating
it; never overwrite or retarget published assets. Verify the exact reviewed
commit is on the remote, the source state matches the app, and the title/notes
contain no private identifiers or local paths.

The public asset is **SayIt.dmg**, not the versioned local filename. Verify it is
byte-identical to the notarized DMG and that the signed feed references its
immutable tag-specific URL. Both `SayIt.dmg` and the signed `appcast.xml` are
required for automatic updates and must be published together on the latest
release. The release script generates and verifies both; do not hand-edit the
signed feed. With GitHub-upload authorization:

```sh
release_tag="v$release_version"
release_commit=$(git rev-parse HEAD)
release_upload_dir="Build/Update-$release_version"
cmp "Build/SayIt-$release_version.dmg" "$release_upload_dir/SayIt.dmg"
gh release create "$release_tag" \
  "$release_upload_dir/SayIt.dmg#Say It $release_version for macOS" \
  "$release_upload_dir/appcast.xml#Signed software update feed" \
  --target "$release_commit" --draft --title "Say It $release_version" \
  --notes-file "Build/release-notes-$release_version.md"
gh release view "$release_tag" \
  --json tagName,targetCommitish,isDraft,body,assets,url
```

Verify the draft description includes the intended highlights, the target is
correct, both assets are attached, and the downloaded DMG checksum matches. With permission
to publish the reviewed draft, run `gh release edit "$release_tag" --draft=false
--latest`, then verify public status and assets. When auditing a downloaded DMG,
validate its read-only mounted layout with `Scripts/dmg-layout.sh validate MOUNT`.
Report only completed stages, final checksum, and the release URL when it exists.
