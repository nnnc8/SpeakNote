# Breeze-ASR-26 local verification

This is a developer verification record for the opt-in local inference gate.
The model binary is not stored in this repository.

## Artifact

* File: `breeze-q5_0.bin`
* Source: `weemed/Breeze-ASR-26-GGML`
* Revision: `16b8f9a257a99e0d21baa2667f3ffdc881b8e445`
* Size: `1,080,732,108` bytes
* SHA-256: `60f25e3a21feca12ec082e6d36f08f94455d9900d6343f7fcb2906f71cc7c449`
* Installed path: `~/Library/Application Support/SpeakNote/Models/Breeze-ASR-26/breeze-q5_0.bin`

The download took 240.84 seconds on this workstation. The file was first
written as `.partial`, checked for exact size and SHA-256, and then atomically
renamed to the installed path.

## Host

* Hardware: MacBook Pro 13-inch, MacBookPro17,1
* CPU: Apple M1 (arm64)
* Memory: 8 GB unified memory
* macOS reported by Xcode: 27.0 (build 26A5378n)
* Runtime: whisper.cpp v1.9.2 XCFramework, Metal enabled

## Inference results

The opt-in XCTest invokes `BreezeWhisperEngine` in-process. It converts the
input through the existing `PCM16WAVPreprocessor`, loads the model lazily,
and runs the same actor-owned context twice. No transcript content is printed
or persisted by the test.

### Voice Memos sample

Sample: local 12.649-second Voice Memos recording, copied to a temporary file
for the sandboxed test host. The source had RMS `0.027662`, so it was not
silent.

* First call (model load + inference): 5.120 s
* Second call (warm inference): 3.656 s
* Warm real-time factor: `0.289`
* Output: 41 characters, 1 segment
* Peak test-host RSS observed during the run: `1,537,824 KB` (~1.47 GiB)

### Known-voice control

As a control, macOS `Meijia` generated a 2.878-second Taiwan Mandarin sample.
The same path returned 12 characters and 1 segment, confirming that the
wrapper, model load, language selection, and segment extraction produce text
on this M1 machine.

The Voice Memos sample is not a labeled Taiwanese Hokkien benchmark; the
numbers above verify runtime execution and output production, not linguistic
accuracy. A labeled Taiwanese Hokkien sample should be added before claiming
an ASR quality benchmark.

## Reproduce

The normal CI suite does not download the model. To run the local gate after
installing the verified artifact, set `SPEAKNOTE_RUN_BREEZE_INTEGRATION=1` and
provide `SPEAKNOTE_BREEZE_AUDIO`; the test is
`BreezeASRTests.testOptInRealBreezeInferenceOnAppleSilicon`.
