# Security and Privacy

Say It processes selected and copied text locally. It does not use analytics,
telemetry, cloud inference, passive clipboard monitoring, microphone access,
Accessibility access, Apple Events, or broad filesystem access.

The app stores only cleaned plain text in history. Diagnostic events use stable
codes and allowlisted numeric or categorical metadata; source text, access
tokens, local paths, exported filenames, machine names, and account names are
not accepted by the diagnostic API.

Hugging Face tokens for gated models are stored in the macOS Keychain. Model
snapshots are pinned to an immutable revision and installed inside the
sandboxed App Group container.

The menu-bar app and bundled CLI communicate with the per-user agent over XPC.
The agent accepts only same-user clients signed with the app or CLI bundle
identifier, the private Say It client entitlement, and the same signing team.
Service lifecycle and API-token administration are never exposed over HTTP.

The optional HTTP API is disabled by default and binds only to `127.0.0.1`.
It validates the loopback Host header, has no permissive CORS policy, limits
request sizes and per-token request rates, and accepts authentication only as
`Authorization: Bearer …`. API secrets contain 256 random bits, are displayed
once, and are stored only as SHA-256 digests plus non-secret metadata in
Keychain. Submitted text and bearer tokens are excluded from normal logs.

Loopback HTTP is intended for local automation. A future network-accessible
mode would require HTTPS and certificate management; changing the bind address
is not supported.

Please report security issues privately to the repository owner rather than
opening a public issue with sensitive logs.
