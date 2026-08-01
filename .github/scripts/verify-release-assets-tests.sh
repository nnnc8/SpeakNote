#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)
verifier="$script_dir/verify-release-assets.sh"

assert_rejected() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: verifier accepted %s\n' "$label" >&2
    exit 1
  fi
}

assert_rejected 'a shell-bearing tag' \
  "$verifier" 'v0.1.0;touch-pwned' nnnc8/SpeakNote
assert_rejected 'a short version tag' \
  "$verifier" v0.1 nnnc8/SpeakNote
assert_rejected 'a shell-bearing repository' \
  "$verifier" v0.1.0 'nnnc8/SpeakNote;touch-pwned'
assert_rejected 'a missing repository owner' \
  "$verifier" v0.1.0 SpeakNote
assert_rejected 'a missing GitHub token' \
  env -u GH_TOKEN "$verifier" v0.1.0 nnnc8/SpeakNote

fixture_root=$(/usr/bin/mktemp -d /tmp/SpeakNote-release-assets-test.XXXXXX)
cleanup() {
  if [[ "$fixture_root" == /tmp/SpeakNote-release-assets-test.* && -d "$fixture_root" ]]; then
    /bin/rm -rf -- "$fixture_root"
  fi
}
trap cleanup EXIT
/bin/mkdir "$fixture_root/bin" "$fixture_root/runner"
fake_gh="$fixture_root/bin/gh"
/bin/cat >"$fake_gh" <<'FAKE_GH'
#!/bin/bash
if [[ "${1:-}" == 'api' ]]; then
  printf '%s\n' \
    '["SpeakNote-0.1.0.dmg","SpeakNote-0.1.0.dmg.sha256","unexpected.txt"]'
  exit 0
fi
: >"$FAKE_GH_DOWNLOAD_MARKER"
exit 97
FAKE_GH
/bin/chmod 700 "$fake_gh"

assert_rejected 'an additional release asset' \
  env PATH="$fixture_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    GH_TOKEN=test-token RUNNER_TEMP="$fixture_root/runner" \
    FAKE_GH_DOWNLOAD_MARKER="$fixture_root/download-called" \
    "$verifier" v0.1.0 nnnc8/SpeakNote
[[ ! -e "$fixture_root/download-called" ]] || {
  printf 'FAIL: verifier attempted download after detecting an extra asset\n' >&2
  exit 1
}

printf 'release asset verifier contract tests passed.\n'
