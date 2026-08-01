# Security policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose user content,
credentials, local files, or system access.

Use GitHub's private **Report a vulnerability** flow for
[nnnc8/SpeakNote](https://github.com/nnnc8/SpeakNote/security) when it is
available. If the repository does not offer that flow, start a
[Discussion](https://github.com/nnnc8/SpeakNote/discussions) containing only a
request for a private contact channel. Do not include exploit details or user
data in that public request.

Please include privately:

- the affected source version or release;
- macOS version and hardware architecture;
- reproduction steps and security impact;
- a minimal proof of concept with all personal content removed;
- whether the issue is already public or actively exploited.

There is no guaranteed response SLA. The maintainer will confirm receipt when
possible, investigate, coordinate a fix, and credit reporters who request credit.
Please allow time for a fix before public disclosure.

## Supported versions

The current development target is v0.1.0. Until a signed public build is listed
on [Releases](https://github.com/nnnc8/SpeakNote/releases), security reports
should identify the affected commit on the default branch. Published support
status will be recorded in release notes when binary releases begin.

## Scope reminders

SpeakNote handles microphone audio, imported files, clipboard writes, local
history, macOS permissions, a Keychain-held Groq credential, and optional cloud
requests. Reports about those boundaries are welcome. Reports should not include
real recordings, recognized content, credentials, or unrelated personal files.
