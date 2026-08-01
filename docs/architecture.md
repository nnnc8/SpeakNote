---
layout: default
title: Architecture
permalink: /architecture/
---

# SpeakNote architecture

SpeakNote is a native Swift 6 macOS application. SwiftUI owns the Window, menu
bar, Settings, onboarding, history, Voice Notes, and vocabulary surfaces. AppKit,
AVFoundation, Speech, SwiftData, Security, and Core Graphics provide the system
integrations.

## Boundaries

```text
SwiftUI scenes and views
        ↓
MainActor coordinators and explicit state machines
        ↓
Injected audio, transcription, text-processing, insertion, persistence,
permission, vocabulary, recovery, and rendering boundaries
        ↓
macOS frameworks, local app storage, Apple Speech, or Groq Cloud
```

Views do not perform provider, storage, or audio work directly. Coordinators
own user-visible state and cancellation. Actors and sendable services own
Keychain access, settings, file storage, provider calls, and long-running audio
or processing work.

## Quick dictation flow

1. The app, menu bar, or global shortcut starts a single dictation job. The
   in-app control chooses manual-copy output because SpeakNote is then frontmost.
2. For menu-bar or global-shortcut starts, SpeakNote records bounded audio and
   retains the original target app identity for guarded cross-app insertion.
3. The provider router checks availability, local-only mode, and fallback policy.
4. Recognition runs through Apple Speech or Groq. Optional language conversion
   and cleanup run only after raw text is available.
5. Profile vocabulary and explicit replacement rules are applied through their
   persisted configuration.
6. Automatic insertion rechecks the target, Secure Input, permission, and
   clipboard ownership. Unsafe cases become manual copy instead of forced paste.

Quick-dictation audio is deleted after the operation. Local text history is
controlled by the user's history setting, and reprocessing appends a new run
instead of overwriting the raw record.

## Voice Note flow

Voice Notes can start from an imported audio file or live recording. Imports are
copied through a security-scoped user selection. Long recordings use rolling,
immutable segments, a recording journal, and startup reconciliation so completed
segments can survive interruption.

Audio is decoded and streamed into bounded chunks. Each successful transcription
chunk is checkpointed before the next begins. The pipeline merges absolute
timestamps, saves the raw result, and renders timestamped Markdown locally.
Structured processing groups source ranges, validates model output, reduces it
into class, meeting, or general notes, and renders Markdown locally. Every
reprocess operation creates another run.

## Provider and privacy boundary

- **Apple Speech** is a local privacy class. Capability checks cover OS version,
  permission, language, on-device support, model availability, and duration.
- **Groq** is a cloud privacy class. Audio is uploaded for cloud transcription;
  text is uploaded for selected cloud cleanup, translation, compression, or
  structured processing.
- The default fallback policy asks before crossing between local and cloud.
  Local-only mode rejects cloud providers.

Credentials are kept in macOS Keychain. Non-secret preferences use UserDefaults.
SwiftData stores history and vocabulary metadata. Session files, recording
segments, raw results, Markdown, and processing runs stay under the sandboxed app
container.

## Reliability and verification

Audio ingress uses bounded queues and processing avoids real-time database work.
Long operations support cancellation, checkpointing, and explicit recovery.
Fixed-event logging excludes user content and credentials.

The Xcode test plan contains unit, integration, and UI targets. Tests inject
providers and transports and do not make live Groq requests. Binary distribution
has a separate release gate for Developer ID signing, notarization, privacy and
security scans, and clean-Mac verification; source tests alone do not establish
that a distributable release exists.
