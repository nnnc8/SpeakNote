# Breeze-ASR-26 integration plan

## Repository-specific Stage 1 result

SpeakNote already has one `TranscriptionEngine` contract, one
`TranscriptionProviderRouter` for Quick Dictation, and one checkpointed
`VoiceNoteTranscriptionPipeline` for imported and recorded Voice Notes. Audio
is converted to 16 kHz mono PCM16 WAV by `PCM16WAVPreprocessor` and the
time-based chunker; each chunk is copied into the session manifest with a
checksum before transcription. `TranscriptMerger` and the frozen
`TranscriptionConfiguration` already provide durable merge and resume behavior.
No second audio or transcription pipeline is needed.

Quick Dictation reaches the router from
`SpeakNote/Features/Dictation/DictationCoordinator.swift`. Voice Notes reach
the same engine contract through `VoiceNoteTranscriptionPipeline`, but the
live dependency graph currently uses the private
`ProviderDispatchingTranscriptionEngine` in
`SpeakNote/App/DependencyContainer.swift`, which only dispatches Apple Speech
and Groq. Settings, Voice Note retry, and local-only validation also contain
the same two-provider assumptions. These are the required integration points.

## Runtime and model decisions

Use the official whisper.cpp v1.9.2 XCFramework as a pinned SwiftPM binary
target exposed through a small local package at `Vendor/WhisperRuntime`. This
keeps inference in-process, preserves Metal/Accelerate, avoids a runtime
Python/CLI dependency, and matches the existing XcodeGen project. The package
uses the v1.9.2 release URL and upstream checksum
`af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b`.

The official MediaTek repository at revision
`7b992682e7f5ceedd0a41ebec240f01ba469d19e` contains only the large
Transformers/safetensors model; it does not contain a GGML Q5 artifact. The
first app artifact is therefore explicitly documented as the third-party
`weemed/Breeze-ASR-26-GGML` `breeze-q5_0.bin` conversion, repository revision
`16b8f9a257a99e0d21baa2667f3ffdc881b8e445`, size `1,080,732,108` bytes, and
LFS SHA-256
`60f25e3a21feca12ec082e6d36f08f94455d9900d6343f7fcb2906f71cc7c449`.
The app never bundles this file. The model manager downloads it only after an
explicit user action and verifies the SHA-256 before atomic installation.
The third-party conversion is not presented as a MediaTek release or
endorsement. Q4 metadata remains extensible but is not exposed in this
milestone.

The native wrapper uses an actor-owned whisper context, lazy file loading,
Metal-enabled context parameters, one serialized `whisper_full` call at a
time, bounded PCM16-to-Float32 conversion, and whisper's abort callback for
cancellation. No Core ML encoder is enabled in this milestone. `Breeze ASR 26`
is a separate local provider; it does not replace Apple Speech or Groq.

## Planned changes and responsibilities

* `ProviderProtocols.swift` — add `ProviderID.breezeASR`, provider metadata,
  local privacy classification, and provider language/model catalogs.
* `TranscriptionProviderRouter.swift` — add a registration-based initializer
  while retaining the two-provider compatibility initializer for existing
  tests; route Breeze through the same capability/fallback/privacy checks.
* `BreezeModelStore.swift` — actor for Application Support model paths,
  temporary partial files, resumable URLSession download, incremental SHA-256,
  disk checks, cancellation, atomic install, and safe deletion.
* `BreezeWhisperEngine.swift` — actor-backed lazy whisper.cpp context and WAV
  reader; map `TranscriptSegment` timestamps from whisper's 10 ms units, expose
  the `TranscriptionEngine` and capability checker, and return explicit
  missing/load/cancel errors without routing Breeze audio to Groq.
* `DependencyContainer.swift` — inject one model store and one Breeze engine
  into the router, Voice Note dispatcher, and Settings coordinator.
* `AppSettings.swift` / `SettingsCoordinator.swift` / `SettingsView.swift` —
  persist `breeze-asr` normally, use Picker-based provider/model/language
  choices, display local Taiwanese Hokkien status and model lifecycle, and
  generalize `localOnly` without overwriting an already-local provider.
* `VoiceNoteWorkflow.swift` — accept Breeze configurations and use the same
  pipeline/checkpoint path for import, recording recovery, retry, and resume.
* `DictationCoordinator.swift` — include Breeze in fallback metadata and keep
  the existing disclosure boundary for cloud processing.
* `Config/Info.plist` / `docs/THIRD_PARTY_NOTICES.md` — keep non-empty usage
  descriptions and record whisper.cpp MIT, Breeze Apache-2.0, and conversion
  provenance separately.
* `SpeakNoteTests/M8/Breeze*Tests.swift` and routing tests — cover persistence,
  local-only semantics, path/state/download/hash behavior, missing model,
  capability and error mapping, Quick Dictation and Voice Note dispatch, and
  the no-automatic-cloud-fallback invariant. Tests use fakes and never fetch
  the 1 GB artifact.

## Concurrency, lifecycle, and privacy

The store and inference context are actors. Settings only observes async state
and starts model operations through its coordinator. Download, hashing, model
loading, audio conversion, and inference never run on the MainActor. The model
is not loaded at app launch; the explicit `unload()` hook releases the context
when the app chooses to reclaim model memory. Fixed-event logging records only
provider/model/state/duration/error category; it never records API keys,
transcripts, audio bytes, or user paths.

`localOnly` is evaluated from provider metadata (`groq = cloud`, Apple Speech
and Breeze = local). A Breeze failure is surfaced as a local provider error;
cloud fallback is possible only when the existing fallback policy and consent
allow it. No code path silently changes Breeze to Groq.

## Stage 2 checklist

1. Add the pinned local binary package and regenerate XcodeGen.
2. Add Breeze provider identity, metadata, model catalog, and persistence
   normalization.
3. Implement and unit-test the model store lifecycle and SHA-256 verifier.
4. Implement the actor-backed whisper.cpp wrapper and WAV conversion.
5. Add the Breeze engine/capability checker and inject it into both dispatch
   paths and the router.
6. Generalize local-only and Voice Note retry/alternative-provider logic.
7. Add Settings model status/download/cancel/retry/delete controls and
   provider/language/model pickers.
8. Add attribution, release-security scan assertions, and tests; do not add
   the binary model or build artifacts to Git.
9. Run formatter/lint only if repository configuration provides one; otherwise
   run XcodeGen, Debug/Release builds, unit tests, security scans, and UI smoke.
10. Perform opt-in Apple Silicon inference only when the model artifact is
    explicitly downloaded and its final local SHA-256 is recorded. Until then,
    report model/inference and M1 memory/RTF gates as unverified.

## Acceptance gates

The implementation is accepted when Breeze is a first-class local provider in
Quick Dictation and Voice Notes, uses the existing chunk/checkpoint/merge path,
loads whisper.cpp lazily in-process, preserves Apple Speech and Groq, never
silently uploads Breeze audio, provides integrity-checked explicit model
management, keeps heavy work off MainActor, passes the ordinary test suite and
Debug/Release builds, and documents any unavailable real-model or hardware
verification instead of fabricating it.

## Sources

* [whisper.cpp v1.9.2 release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.2)
* [whisper.cpp XCFramework build](https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/build-xcframework.sh)
* [MediaTek Breeze-ASR-26 model card](https://huggingface.co/MediaTek-Research/Breeze-ASR-26)
* [Third-party Breeze GGML conversion](https://huggingface.co/weemed/Breeze-ASR-26-GGML)
