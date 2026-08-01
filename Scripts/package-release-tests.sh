#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=package-release.sh
source "$script_dir/package-release.sh"

assert_passes() {
  local label=$1
  shift
  if ! ("$@") >/dev/null 2>&1; then
    printf 'FAIL: expected pass: %s\n' "$label" >&2
    exit 1
  fi
}

assert_fails() {
  local label=$1
  shift
  if ("$@") >/dev/null 2>&1; then
    printf 'FAIL: expected failure: %s\n' "$label" >&2
    exit 1
  fi
}

assert_passes 'valid Team ID' validate_team_id ABCDE12345
assert_fails 'short Team ID' validate_team_id ABC123
assert_fails 'Team ID punctuation' validate_team_id 'ABCDE-2345'

assert_passes 'valid Keychain profile' validate_notary_profile SpeakNote-Notary
assert_fails 'profile whitespace' validate_notary_profile 'SpeakNote Notary'
assert_fails 'profile shell punctuation' validate_notary_profile 'SpeakNote;Notary'

assert_passes 'semantic version' validate_version 0.1.0
assert_fails 'short version' validate_version 0.1
assert_fails 'version suffix' validate_version 0.1.0-beta

assert_passes 'positive build' validate_build 1
assert_fails 'zero build' validate_build 0
assert_fails 'non-numeric build' validate_build one

assert_passes 'stable Xcode' validate_xcode_version $'Xcode 16.4\nBuild version 16F6'
assert_fails 'beta Xcode' validate_xcode_version $'Xcode 27.0 beta\nBuild version 27A1'
assert_fails 'release candidate Xcode' validate_xcode_version $'Xcode 27.0 RC\nBuild version 27A2'
assert_passes 'normal Xcode path' validate_developer_dir_path /Applications/Xcode.app/Contents/Developer
assert_fails 'beta Xcode path' validate_developer_dir_path /Applications/Xcode-27-beta.app/Contents/Developer

if LC_ALL=C /usr/bin/grep -Eq \
  '(^[[:space:]]*xcodebuild[[:space:]]|[$][(]xcodebuild[[:space:]])' \
  "$script_dir/package-release.sh"; then
  printf 'FAIL: package script contains a PATH-resolved xcodebuild invocation\n' >&2
  exit 1
fi

help_output=$("$script_dir/package-release.sh" --help)
[[ "$help_output" == *'Developer ID'* && "$help_output" == *'notary service'* ]] || {
  printf 'FAIL: help omits the signing or notarization contract\n' >&2
  exit 1
}

printf 'package-release contract tests passed.\n'
