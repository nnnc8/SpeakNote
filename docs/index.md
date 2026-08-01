---
layout: default
title: SpeakNote
permalink: /
---

# SpeakNote

SpeakNote turns speech into ready-to-use text and structured Markdown on macOS.
Use it for quick dictation, long recordings, imported audio, class notes,
meeting notes, and reusable personal vocabulary.

[Download the latest available build](https://github.com/nnnc8/SpeakNote/releases/latest)

> v0.1.0 is the current source version. A download should be treated as a public
> release only when its GitHub release notes identify the asset and its signing
> and notarization status.

## What it does

- Dictates through the app, menu bar, Right Option, or Shift-Command-Space.
- Uses guarded insertion for menu-bar and global-shortcut starts; the in-app
  button and unsafe insertion cases keep the result for manual copy.
- Records recoverable Voice Notes or imports M4A, MP3, WAV, AIFF, and CAF.
- Produces structured Markdown without replacing earlier runs.
- Uses on-device Apple Speech when supported or Groq Cloud after disclosure and
  user choice.
- Stores the Groq credential in Keychain and user content in the sandboxed app
  container.

## Documentation

- [Privacy notice]({{ '/privacy/' | relative_url }})
- [Support]({{ '/support/' | relative_url }})
- [Architecture]({{ '/architecture/' | relative_url }})
- [Build and contribution guide](https://github.com/nnnc8/SpeakNote/blob/main/CONTRIBUTING.md)
- [Source code](https://github.com/nnnc8/SpeakNote)

SpeakNote requires macOS 14 or later. Apple Speech capabilities vary by OS,
language, downloaded model, and audio duration; unavailable combinations are
shown to the user instead of silently switching to cloud processing.
