---
layout: default
title: Privacy notice
permalink: /privacy/
---

# SpeakNote privacy notice

Last updated: 2026-08-02

This notice describes SpeakNote v0.1.0's implemented data flow. SpeakNote has no
advertising SDK, analytics SDK, or tracking feature.

## Data stored on your Mac

- The Groq credential is stored in macOS Keychain.
- Provider choice, language, history, fallback, onboarding, and profile settings
  are stored as non-secret preferences.
- Quick-dictation audio is deleted after the operation. When quick-dictation
  history is enabled, recognized text and processing runs remain in local app
  storage until deleted. When history is disabled, audio and text are removed
  after the current operation.
- Voice Note audio, imported-file copies, checkpoints, raw results, Markdown,
  structured runs, vocabulary, and replacement rules remain in the sandboxed app
  container until the related item is deleted.

SpeakNote accesses UserDefaults, file timestamps, system boot time, and available
disk space for app functionality. These required-reason APIs and the audio and
user-content categories are declared in the bundled Apple privacy manifest.

## Data sent to providers

### Apple Speech

Apple Speech is treated as an on-device provider. SpeakNote uses it only when
the OS, permission, language, model asset, on-device capability, and audio
duration checks pass. If the local provider is unavailable, local-only mode does
not send the request to cloud processing.

### Groq Cloud

When Groq transcription is selected, SpeakNote sends the chosen audio to Groq.
When cloud cleanup, translation, compression, or structured-note processing is
selected, SpeakNote also sends the necessary recognized text and instructions.
The Groq credential is used to authenticate those requests.

SpeakNote requires acknowledgement of its Groq cloud-processing disclosure
before saving the credential. The default fallback policy asks before crossing
the local/cloud boundary; cloud processing does not begin merely because a local
provider failed.

Groq controls its own processing and retention practices. Review
[Groq's data documentation](https://console.groq.com/docs/your-data) before using
cloud features.

## Permissions

| Permission | Purpose |
|---|---|
| Microphone | Live dictation and Voice Note recording |
| Input Monitoring | Detect the Right Option global shortcut |
| Accessibility | Send Command-V to the original app |
| Speech Recognition | Optional on-device Apple Speech |

Permissions are requested separately after the user chooses the related action.
Without Input Monitoring, the app/menu-bar control and Shift-Command-Space remain
available. Without Accessibility, SpeakNote keeps the result for manual copy.

SpeakNote records the original app's process identity for guarded insertion. It
does not read the other app's text through the Accessibility API. Clipboard
content is restored only while SpeakNote can prove ownership of its temporary
write.

## Logs and project website

Application logs contain fixed event identifiers, not audio, recognized text,
prompts, provider payloads, credentials, or file paths.

This documentation site is hosted by GitHub Pages. The SpeakNote application
does not add site analytics, but GitHub may process connection information under
the [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Your choices

You can use local-only transcription when Apple Speech is available, disable
quick-dictation history, delete individual history or Voice Note items, remove
the Groq credential in Settings, deny permissions in System Settings, and avoid
cloud features entirely.

For privacy questions, use the non-sensitive contact options on the
[support page]({{ '/support/' | relative_url }}). Do not post recordings,
recognized content, credentials, or private paths in a public issue.
