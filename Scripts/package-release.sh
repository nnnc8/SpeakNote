#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  Scripts/package-release.sh \
    --team-id TEAM_ID \
    --notary-profile KEYCHAIN_PROFILE \
    --developer-dir /path/to/Xcode.app/Contents/Developer \
    --output-dir /absolute/output/directory \
    [--version 0.1.0] [--build 1] [--tag v0.1.0]

Builds a clean tagged commit with Developer ID, creates and signs a Universal
DMG, submits it to Apple's notary service, staples the ticket, runs the release
verifier, and writes a SHA-256 file. The notary profile must already exist in
the login Keychain. Release output must be outside the repository.
USAGE
}

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_value() {
  local option=$1
  local count=$2
  ((count >= 2)) || die "$option requires a value"
}

validate_team_id() {
  [[ "$1" =~ ^[A-Za-z0-9]{10}$ ]] || \
    die 'Team ID must contain exactly 10 letters or digits'
}

validate_notary_profile() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || \
    die 'notary profile must use only letters, digits, dot, underscore, or hyphen'
}

validate_version() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+){2}$ ]] || \
    die 'version must use three numeric components, for example 0.1.0'
}

validate_build() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || die 'build must be a positive integer'
}

validate_xcode_version() {
  local version_output=$1
  local lowercase
  lowercase=$(printf '%s' "$version_output" | /usr/bin/tr '[:upper:]' '[:lower:]')
  [[ "$version_output" == Xcode\ * ]] || die 'selected developer directory is not a full Xcode installation'
  [[ "$lowercase" != *beta* && "$lowercase" != *rc* ]] || \
    die 'release packaging requires a stable Xcode installation'
}

validate_developer_dir_path() {
  local lowercase
  lowercase=$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')
  [[ "$lowercase" != *beta* && "$lowercase" != *preview* && "$lowercase" != *release-candidate* ]] || \
    die 'release packaging requires a stable Xcode application'
}

canonical_existing_directory() {
  local input=$1
  local label=$2
  local resolved

  [[ "$input" == /* ]] || die "$label must be an absolute path"
  [[ "$input" != *$'\n'* && ! -L "$input" && -d "$input" ]] || \
    die "$label must be an existing non-symlink directory"
  resolved=$(cd "$input" && pwd -P) || die "$label could not be resolved"
  printf '%s\n' "$resolved"
}

resolve_output_directory() {
  local input=$1
  local repository_root=$2
  local parent
  local leaf
  local resolved_parent
  local resolved

  [[ "$input" == /* ]] || die 'output directory must be an absolute path'
  [[ "$input" != *$'\n'* && ! -L "$input" ]] || \
    die 'output directory must not contain a newline or be a symlink'

  if [[ -e "$input" ]]; then
    [[ -d "$input" ]] || die 'output path exists and is not a directory'
    resolved=$(cd "$input" && pwd -P) || die 'output directory could not be resolved'
    [[ -z "$(/bin/ls -A "$resolved")" ]] || die 'output directory must be empty'
  else
    parent=$(/usr/bin/dirname "$input")
    leaf=$(/usr/bin/basename "$input")
    resolved_parent=$(canonical_existing_directory "$parent" 'output parent')
    [[ "$leaf" != '.' && "$leaf" != '..' && -n "$leaf" ]] || \
      die 'output directory name is invalid'
    resolved="$resolved_parent/$leaf"
  fi

  case "$resolved/" in
    "$repository_root/"*) die 'release output must be outside the repository' ;;
  esac

  printf '%s\n' "$resolved"
}

build_setting() {
  local settings=$1
  local key=$2
  /usr/bin/awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' \
    "$settings"
}

cleanup_root=''

cleanup() {
  if [[ "$cleanup_root" == /tmp/SpeakNote-package.* && -d "$cleanup_root" ]]; then
    /bin/rm -rf -- "$cleanup_root"
  fi
}

main() {
  local team_id=''
  local notary_profile=''
  local developer_dir=''
  local output_input=''
  local version='0.1.0'
  local build='1'
  local tag='v0.1.0'
  local script_dir
  local repository_root
  local output_dir
  local xcode_version
  local head_commit
  local tag_commit
  local identities
  local identity_hash
  local settings
  local archive_path
  local export_path
  local exported_app
  local executable_name
  local staging_dir
  local dmg_path
  local dmg_name
  local notary_log
  local notary_status

  while (($# > 0)); do
    case "$1" in
      --team-id)
        require_value "$1" "$#"
        team_id=$2
        shift 2
        ;;
      --notary-profile)
        require_value "$1" "$#"
        notary_profile=$2
        shift 2
        ;;
      --developer-dir)
        require_value "$1" "$#"
        developer_dir=$2
        shift 2
        ;;
      --output-dir)
        require_value "$1" "$#"
        output_input=$2
        shift 2
        ;;
      --version)
        require_value "$1" "$#"
        version=$2
        shift 2
        ;;
      --build)
        require_value "$1" "$#"
        build=$2
        shift 2
        ;;
      --tag)
        require_value "$1" "$#"
        tag=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  validate_team_id "$team_id"
  validate_notary_profile "$notary_profile"
  validate_version "$version"
  validate_build "$build"
  [[ "$tag" == "v$version" ]] || die 'tag must equal v followed by the release version'
  [[ -n "$developer_dir" ]] || die '--developer-dir is required'
  [[ -n "$output_input" ]] || die '--output-dir is required'

  script_dir=$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)
  repository_root=$(cd "$script_dir/.." && pwd -P)
  developer_dir=$(canonical_existing_directory "$developer_dir" 'developer directory')
  validate_developer_dir_path "$developer_dir"
  xcodebuild_path="$developer_dir/usr/bin/xcodebuild"
  [[ -x "$xcodebuild_path" ]] || \
    die 'developer directory does not contain xcodebuild'
  export DEVELOPER_DIR="$developer_dir"
  xcode_version=$("$xcodebuild_path" -version) || die 'Xcode version could not be read'
  validate_xcode_version "$xcode_version"

  output_dir=$(resolve_output_directory "$output_input" "$repository_root")

  cd "$repository_root"
  /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die 'repository is not a Git worktree'
  head_commit=$(/usr/bin/git rev-parse --verify HEAD 2>/dev/null) || \
    die 'release requires a committed repository'
  [[ -z "$(/usr/bin/git status --porcelain)" ]] || die 'release requires a clean worktree'
  tag_commit=$(/usr/bin/git rev-parse --verify "$tag^{commit}" 2>/dev/null) || \
    die 'release tag does not exist'
  [[ "$head_commit" == "$tag_commit" ]] || die 'release tag must point to HEAD'

  identities=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null) || \
    die 'code-signing identities could not be read'
  identity_hash=$(printf '%s\n' "$identities" | \
    /usr/bin/awk -v team="($team_id)" \
      'index($0, "Developer ID Application:") && index($0, team) { print $2; exit }')
  [[ "$identity_hash" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    die 'matching Developer ID Application identity was not found'
  /usr/bin/xcrun notarytool history --keychain-profile "$notary_profile" \
    --output-format json >/dev/null || die 'notary Keychain profile could not authenticate'

  /bin/mkdir -p "$output_dir"
  cleanup_root=$(/usr/bin/mktemp -d /tmp/SpeakNote-package.XXXXXX)
  trap cleanup EXIT
  settings="$cleanup_root/build-settings.txt"
  archive_path="$output_dir/SpeakNote.xcarchive"
  export_path="$output_dir/export"
  staging_dir="$cleanup_root/dmg-root"
  dmg_name="SpeakNote-$version.dmg"
  dmg_path="$output_dir/$dmg_name"
  notary_log="$output_dir/notary-submission.json"

  "$xcodebuild_path" -project SpeakNote.xcodeproj -scheme SpeakNote \
    -configuration Release -showBuildSettings DEVELOPMENT_TEAM="$team_id" \
    >"$settings"
  [[ "$(build_setting "$settings" PRODUCT_BUNDLE_IDENTIFIER)" == 'com.nc8.SpeakNote' ]] || \
    die 'resolved bundle identifier is not com.nc8.SpeakNote'
  [[ "$(build_setting "$settings" MARKETING_VERSION)" == "$version" ]] || \
    die 'resolved marketing version does not match --version'
  [[ "$(build_setting "$settings" CURRENT_PROJECT_VERSION)" == "$build" ]] || \
    die 'resolved build number does not match --build'

  "$script_dir/security-scan.sh" --repo "$repository_root" --require-git-history

  /usr/bin/plutil -create xml1 "$cleanup_root/ExportOptions.plist"
  /usr/bin/plutil -insert method -string developer-id "$cleanup_root/ExportOptions.plist"
  /usr/bin/plutil -insert destination -string export "$cleanup_root/ExportOptions.plist"
  /usr/bin/plutil -insert signingStyle -string automatic "$cleanup_root/ExportOptions.plist"
  /usr/bin/plutil -insert teamID -string "$team_id" "$cleanup_root/ExportOptions.plist"
  /usr/bin/plutil -insert stripSwiftSymbols -bool true "$cleanup_root/ExportOptions.plist"

  "$xcodebuild_path" archive -project SpeakNote.xcodeproj -scheme SpeakNote \
    -configuration Release -archivePath "$archive_path" \
    DEVELOPMENT_TEAM="$team_id" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
  "$xcodebuild_path" -exportArchive -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$cleanup_root/ExportOptions.plist"

  exported_app="$export_path/SpeakNote.app"
  [[ -d "$exported_app" && ! -L "$exported_app" ]] || \
    die 'export did not produce SpeakNote.app'
  executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$exported_app/Contents/Info.plist" 2>/dev/null) || \
    die 'exported app has no executable name'
  /usr/bin/lipo -verify_arch arm64 x86_64 \
    "$exported_app/Contents/MacOS/$executable_name" || \
    die 'exported app is not Universal arm64 and x86_64'
  "$script_dir/security-scan.sh" --repo "$repository_root" \
    --build-root "$exported_app" --require-git-history

  /bin/mkdir "$staging_dir"
  /usr/bin/ditto "$exported_app" "$staging_dir/SpeakNote.app"
  /bin/ln -s /Applications "$staging_dir/Applications"
  /usr/bin/hdiutil create -volname SpeakNote -srcfolder "$staging_dir" \
    -format UDZO -fs HFS+ -ov "$dmg_path"
  /usr/bin/codesign --force --timestamp --sign "$identity_hash" "$dmg_path"

  /usr/bin/xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$notary_profile" --wait --output-format json \
    >"$notary_log"
  notary_status=$(/usr/bin/plutil -extract status raw -o - "$notary_log" 2>/dev/null) || \
    die 'notary result did not contain a status'
  [[ "$notary_status" == 'Accepted' ]] || die 'Apple did not accept the notarization submission'
  /usr/bin/xcrun stapler staple "$dmg_path"

  "$script_dir/verify-release.sh" --app "$exported_app" --dmg "$dmg_path" \
    --expected-bundle-id com.nc8.SpeakNote --expected-team-id "$team_id" \
    --expected-version "$version" --expected-build "$build"

  (
    cd "$output_dir"
    /usr/bin/shasum -a 256 "$dmg_name" >"$dmg_name.sha256"
  )

  printf 'Release package passed verification.\n'
  printf 'DMG: %s\n' "$dmg_path"
  printf 'SHA-256: %s\n' "$dmg_path.sha256"
  printf 'Notary result: %s\n' "$notary_log"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
