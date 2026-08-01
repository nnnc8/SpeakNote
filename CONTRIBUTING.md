# Contributing to SpeakNote

Thanks for helping improve SpeakNote. Small, focused changes with a reproducible
check are easiest to review.

## Before you start

- Search [Issues](https://github.com/nnnc8/SpeakNote/issues) for an existing bug
  or proposal.
- Use [Discussions](https://github.com/nnnc8/SpeakNote/discussions) for design
  questions or ideas that need clarification.
- For a sensitive vulnerability, follow [SECURITY.md](SECURITY.md) instead of
  opening a public issue.

## Development setup

You need macOS, a full Xcode installation with the macOS 26 SDK or later, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/nnnc8/SpeakNote.git
cd SpeakNote
xcodegen generate
xcodebuild -project SpeakNote.xcodeproj -scheme SpeakNote \
  -destination 'platform=macOS' build test
```

`project.yml` is the project source of truth. Regenerate the checked-in Xcode
project after changing targets, build settings, or source layout; do not hand-edit
generated project entries.

## Change guidelines

- Keep UI state on `MainActor`; keep audio, persistence, networking, and file
  work behind the existing actor or protocol boundaries.
- Preserve the explicit local/cloud consent boundary. Never add silent provider
  fallback.
- Do not log or commit credentials, audio, recognized text, prompts, provider
  payloads, personal paths, or private release evidence.
- Keep the app usable without Input Monitoring or Accessibility by preserving
  the app/menu-bar controls and manual-copy fallback.
- Add or update the smallest test that proves the changed behavior. Tests must
  use injected providers and local fixtures, never a live cloud request.
- Add English and Traditional Chinese entries together when UI copy changes.

Format touched Swift files before submitting:

```sh
xcrun swift-format lint --strict path/to/ChangedFile.swift
```

## Pull requests

Include:

- the user-visible problem and the chosen behavior;
- test commands and results;
- screenshots for visible UI changes;
- privacy, permission, storage, or provider-flow effects;
- any signed-system behavior that still needs manual verification.

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE).
