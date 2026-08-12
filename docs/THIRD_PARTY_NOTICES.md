# Third-party notices

SpeakNote remains MIT-licensed. The following components are used by the
offline Breeze ASR integration:

## whisper.cpp

* Project: [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp)
* Revision: v1.9.2, commit
  306c88f4d1286aec1bf96e544632897886af5501
* Distribution: official v1.9.2 XCFramework, pinned in
  Vendor/WhisperRuntime/Package.swift
* License: MIT

The XCFramework supplies the in-process C API and Metal/Accelerate runtime.
SpeakNote does not invoke whisper-cli, a shell, Python, or a local server.
The complete upstream license is available at
<https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/LICENSE>.

## Breeze-ASR-26

* Original model: [MediaTek-Research/Breeze-ASR-26](https://huggingface.co/MediaTek-Research/Breeze-ASR-26)
* Original revision: 7b992682e7f5ceedd0a41ebec240f01ba469d19e
* License: Apache-2.0
* Intended input: Taiwanese Hokkien (台語)
* Reported output style: primarily Mandarin Chinese characters, not formal
  Taiwanese Hokkien orthography

The original MediaTek repository contains a Transformers/safetensors model,
not the GGML file used by SpeakNote.

## GGML conversion

The initial opt-in artifact is a separate third-party conversion:

* Repository: [weemed/Breeze-ASR-26-GGML](https://huggingface.co/weemed/Breeze-ASR-26-GGML)
* Revision: 16b8f9a257a99e0d21baa2667f3ffdc881b8e445
* File: breeze-q5_0.bin
* Expected size: 1,080,732,108 bytes
* Expected SHA-256: 60f25e3a21feca12ec082e6d36f08f94455d9900d6343f7fcb2906f71cc7c449
* Declared license metadata: Apache-2.0

This conversion is not an official MediaTek release and does not imply
MediaTek endorsement. SpeakNote never commits or bundles the binary. It is
downloaded only after explicit user action, verified, and atomically installed
under Application Support.

## Attribution boundary

The original Breeze model, the third-party GGML conversion, and whisper.cpp
are separate works. Any future replacement conversion must update this file,
the pinned URL/revision, the expected byte count and SHA-256, and the release
verification record.
