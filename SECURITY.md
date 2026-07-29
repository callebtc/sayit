# Security and Privacy

Say It processes selected and copied text locally. It does not use analytics,
telemetry, cloud inference, passive clipboard monitoring, microphone access,
Accessibility access, Apple Events, or broad filesystem access.

The app stores only cleaned plain text in history. Diagnostic events use stable
codes and allowlisted numeric or categorical metadata; source text, access
tokens, local paths, exported filenames, machine names, and account names are
not accepted by the diagnostic API.

Hugging Face tokens for gated models are stored in the macOS Keychain. Model
snapshots are pinned to an immutable revision and installed inside the app's
sandbox Application Support container.

Please report security issues privately to the repository owner rather than
opening a public issue with sensitive logs.
