# Release SpeakNote outside the Mac App Store

SpeakNote releases are Developer ID signed, notarized, and stapled Universal
DMGs. An ad-hoc or unsigned build is never uploaded as a public release.

The release scripts intentionally keep Apple credentials in the operator's
Keychain. They do not accept a certificate, private key, Apple password, or API
key as a command-line argument.

## Prerequisites

- An active Apple Developer Program membership and 10-character Team ID.
- A valid `Developer ID Application` identity in the login Keychain.
- A stable full Xcode installation. Beta and release-candidate Xcode builds are
  rejected by the packaging script.
- Gatekeeper assessments enabled on the verification Mac.
- A `notarytool` Keychain profile. Create it interactively so the app-specific
  password is not written to shell history:

  ```sh
  xcrun notarytool store-credentials SpeakNote-Notary \
    --apple-id YOUR_APPLE_ID \
    --team-id YOUR_TEAM_ID
  ```

- A clean repository whose `v<version>` tag points at `HEAD`.

Do not copy certificates, `.p8` files, passwords, API keys, transcripts, audio,
notary logs, or local release records into the repository.

## Build, sign, notarize, and verify

Choose a new empty output directory outside the repository and pass the stable
Xcode developer directory explicitly:

```sh
Scripts/package-release.sh \
  --team-id YOUR_TEAM_ID \
  --notary-profile SpeakNote-Notary \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --output-dir /absolute/path/outside-the-repository/SpeakNote-0.1.0 \
  --version 0.1.0 \
  --build 1 \
  --tag v0.1.0
```

The script fails closed unless all of the following are true:

1. The source history and runtime artifact scans find no credential-shaped
   content.
2. Release build settings resolve to bundle ID `com.nc8.SpeakNote` and the
   requested version and build.
3. The archive is built for both `arm64` and `x86_64` and exported using the
   requested Developer ID team.
4. The DMG and contained app have valid Developer ID signatures and secure
   timestamps.
5. Apple's notary service accepts the DMG and `stapler` attaches its ticket.
6. Gatekeeper accepts both the DMG and contained app, and the signed
   entitlements and privacy manifest match SpeakNote's allowlist.

Successful output contains:

```text
SpeakNote-0.1.0.dmg
SpeakNote-0.1.0.dmg.sha256
SpeakNote.xcarchive/
export/SpeakNote.app
notary-submission.json
```

Keep the archive and notary result in the private release record. Only the DMG
and checksum are public release assets.

## Independent verification

The package script calls the verifier automatically. A second operator or clean
test Mac can run the same checks without signing or changing the artifact:

```sh
Scripts/verify-release.sh \
  --app /absolute/path/SpeakNote.app \
  --dmg /absolute/path/SpeakNote-0.1.0.dmg \
  --expected-bundle-id com.nc8.SpeakNote \
  --expected-team-id YOUR_TEAM_ID \
  --expected-version 0.1.0 \
  --expected-build 1
```

After exercising the signed app, run the strict privacy scan against the
exported app. Strict mode requires real preferences, Application Support data,
and unified logs from that signed smoke test:

```sh
Scripts/security-scan.sh \
  --repo "$PWD" \
  --build-root /absolute/path/SpeakNote.app \
  --require-git-history \
  --strict-runtime
```

The scan reports only the affected surface; it never prints a matched secret or
payload value.

## Clean-user acceptance

Test the same notarized DMG on clean macOS 14, 15, and 26 environments. Record
the OS build, app version/build, artifact SHA-256, tester, date, and notary
submission ID for every row.

| Check | Required result |
|---|---|
| Download, mount, and copy to Applications | No corruption or quarantine workaround |
| First launch | Gatekeeper accepts the app |
| Idle launch | No permission prompt before a feature is used |
| Microphone, Input Monitoring, Accessibility, Speech | Each permission is requested separately and only when needed |
| Quick dictation | Keeps the original target, inserts when permitted, and offers Copy fallback otherwise |
| Secure Input or target change | Does not paste into the wrong destination |
| Apple local-only route | Does not silently cross the network boundary |
| Groq route | Disclosure and consent occur before audio or text upload |
| Voice-note import, recording, recovery, and playback | Durable across relaunch and interruption |
| Offline, cancellation, 429/5xx, sleep/wake | Presents a recoverable state without losing committed work |
| Strict security scan | No credential-shaped values in scanned runtime files, no secret-bearing preference keys, and no forbidden payload markers in unified-log metadata |

A build or unit-test result does not replace this signed clean-user matrix.

## Publish the GitHub release

1. Confirm the tagged commit's required GitHub Actions checks are green.
2. Create a draft release for `v0.1.0`.
3. Upload `SpeakNote-0.1.0.dmg` and its `.sha256` file.
4. Download both assets anonymously and repeat the checksum, signature,
   notarization, and Gatekeeper checks.
5. Publish the draft only after every required result passes.

GitHub Actions deliberately builds and tests ad-hoc development products only.
The first release does not place Developer ID or notary credentials in GitHub.
Automated signing, Homebrew distribution, in-app updates, and Mac App Store
submission are separate future milestones.
