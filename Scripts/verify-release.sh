#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  Scripts/verify-release.sh (--archive PATH | --app PATH) [--dmg PATH]
    --expected-bundle-id ID --expected-team-id ID
    --expected-version VERSION --expected-build BUILD

Validates an already signed release artifact. A supplied DMG is mounted
read-only and its app must have the same bundle ID, version, build, Team ID,
and CodeDirectory hash as the supplied app/archive. The script never signs,
uploads, submits for notarization, staples, installs, or changes an artifact.
USAGE
}

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

temporary_root=''
dmg_mountpoint=''
dmg_mounted=0
validation_counter=0

cleanup() {
  if ((dmg_mounted)) && [[ -n "$dmg_mountpoint" ]]; then
    if ! /usr/bin/hdiutil detach "$dmg_mountpoint" >/dev/null 2>&1; then
      /usr/bin/hdiutil detach -force "$dmg_mountpoint" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$temporary_root" == /tmp/SpeakNote-release.* && -d "$temporary_root" ]]; then
    /bin/rm -rf -- "$temporary_root"
  fi
}

canonical_directory() {
  local input=$1
  local label=$2
  local physical

  [[ "$input" != *$'\n'* ]] || die "$label path contains a newline"
  [[ ! -L "$input" ]] || die "$label must not be a symlink"
  [[ -d "$input" ]] || die "$label is not a directory"
  if ! physical=$(cd "$input" && pwd -P); then
    die "$label could not be canonicalized"
  fi
  printf '%s\n' "$physical"
}

canonical_file() {
  local input=$1
  local label=$2
  local directory
  local filename
  local physical_directory
  local physical

  [[ "$input" != *$'\n'* ]] || die "$label path contains a newline"
  [[ ! -L "$input" ]] || die "$label must not be a symlink"
  [[ -f "$input" ]] || die "$label is not a regular file"
  directory=$(dirname "$input")
  filename=$(basename "$input")
  if ! physical_directory=$(cd "$directory" && pwd -P); then
    die "$label parent could not be canonicalized"
  fi
  physical="$physical_directory/$filename"
  [[ -f "$physical" && ! -L "$physical" ]] || die "$label canonical path is invalid"
  printf '%s\n' "$physical"
}

plist_extract() {
  local plist=$1
  local key_path=$2
  local expected_type=$3
  /usr/bin/plutil -extract "$key_path" raw -expect "$expected_type" \
    -o - "$plist" 2>/dev/null
}

plist_required() {
  local plist=$1
  local key_path=$2
  local expected_type=$3
  local label=$4
  local value

  if ! value=$(plist_extract "$plist" "$key_path" "$expected_type"); then
    die "$label is missing or has the wrong property-list type"
  fi
  printf '%s\n' "$value"
}

validate_dictionary_keys() {
  local plist=$1
  local key_path=$2
  local expected_csv=$3
  local label=$4
  local keys

  if ! keys=$(plist_extract "$plist" "$key_path" dictionary | /usr/bin/sort); then
    die "$label is not a dictionary"
  fi
  keys=$(printf '%s\n' "$keys" | /usr/bin/paste -sd, -)
  [[ "$keys" == "$expected_csv" ]] || die "$label contains missing or extra fields"
}

validate_privacy_root_keys() {
  local plist=$1
  local keys

  keys=$(/usr/libexec/PlistBuddy -c Print "$plist" | \
    /usr/bin/awk '/^    [^ ].* =/ { line=$0; sub(/^    /, "", line); sub(/ =.*/, "", line); print line }' | \
    /usr/bin/sort | /usr/bin/paste -sd, -) || \
    die 'PrivacyInfo.xcprivacy root dictionary could not be read'
  case "$keys" in
    NSPrivacyAccessedAPITypes,NSPrivacyCollectedDataTypes,NSPrivacyTracking|\
    NSPrivacyAccessedAPITypes,NSPrivacyCollectedDataTypes,NSPrivacyTracking,NSPrivacyTrackingDomains)
      ;;
    *)
      die 'PrivacyInfo.xcprivacy contains missing or unexpected root fields'
      ;;
  esac
}

reject_symlinks_in_tree() {
  local path=$1
  local label=$2
  local symlink

  if ! symlink=$(/usr/bin/find -P "$path" -type l -print -quit); then
    die "$label symlink inventory could not be created"
  fi
  [[ -z "$symlink" ]] || die "$label contains a symlink"
}

validate_privacy_manifest() {
  local privacy_manifest=$1
  local tracking
  local collected_count
  local accessed_count
  local index
  local base
  local data_type
  local linked
  local item_tracking
  local purposes_count
  local purpose
  local category
  local reasons_count
  local reason
  local seen_audio=0
  local seen_content=0
  local seen_defaults=0
  local seen_timestamp=0
  local seen_boot_time=0
  local seen_disk_space=0
  local tracking_domains_count

  [[ -f "$privacy_manifest" && ! -L "$privacy_manifest" ]] || \
    die 'PrivacyInfo.xcprivacy is missing or is a symlink'
  /usr/bin/plutil -lint "$privacy_manifest" >/dev/null || \
    die 'PrivacyInfo.xcprivacy is not a valid property list'
  validate_privacy_root_keys "$privacy_manifest"

  tracking=$(plist_required \
    "$privacy_manifest" 'NSPrivacyTracking' bool 'NSPrivacyTracking')
  [[ "$tracking" == 'false' ]] || die 'NSPrivacyTracking must be false'

  if tracking_domains_count=$(plist_extract \
    "$privacy_manifest" 'NSPrivacyTrackingDomains' array); then
    [[ "$tracking_domains_count" == '0' ]] || \
      die 'NSPrivacyTrackingDomains must be absent or empty'
  fi

  collected_count=$(plist_required \
    "$privacy_manifest" 'NSPrivacyCollectedDataTypes' array \
    'NSPrivacyCollectedDataTypes')
  [[ "$collected_count" == '2' ]] || \
    die 'NSPrivacyCollectedDataTypes must contain exactly two dictionaries'

  index=0
  while ((index < collected_count)); do
    base="NSPrivacyCollectedDataTypes.$index"
    validate_dictionary_keys "$privacy_manifest" "$base" \
      'NSPrivacyCollectedDataType,NSPrivacyCollectedDataTypeLinked,NSPrivacyCollectedDataTypePurposes,NSPrivacyCollectedDataTypeTracking' \
      "collected-data dictionary $index"
    data_type=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyCollectedDataType" string \
      "collected-data type $index")
    linked=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyCollectedDataTypeLinked" bool \
      "collected-data linked flag $index")
    item_tracking=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyCollectedDataTypeTracking" bool \
      "collected-data tracking flag $index")
    purposes_count=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyCollectedDataTypePurposes" array \
      "collected-data purposes $index")
    [[ "$linked" == 'true' && "$item_tracking" == 'false' ]] || \
      die "collected-data flags are invalid at index $index"
    [[ "$purposes_count" == '1' ]] || \
      die "collected-data purposes must contain one value at index $index"
    purpose=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyCollectedDataTypePurposes.0" string \
      "collected-data purpose $index")
    [[ "$purpose" == 'NSPrivacyCollectedDataTypePurposeAppFunctionality' ]] || \
      die "collected-data purpose is invalid at index $index"

    case "$data_type" in
      NSPrivacyCollectedDataTypeAudioData)
        ((seen_audio == 0)) || die 'audio-data collection is duplicated'
        seen_audio=1
        ;;
      NSPrivacyCollectedDataTypeOtherUserContent)
        ((seen_content == 0)) || die 'other-user-content collection is duplicated'
        seen_content=1
        ;;
      *)
        die 'an unexpected collected-data type is declared'
        ;;
    esac
    index=$((index + 1))
  done
  ((seen_audio == 1 && seen_content == 1)) || \
    die 'required collected-data declarations are incomplete'

  accessed_count=$(plist_required \
    "$privacy_manifest" 'NSPrivacyAccessedAPITypes' array \
    'NSPrivacyAccessedAPITypes')
  [[ "$accessed_count" == '4' ]] || \
    die 'NSPrivacyAccessedAPITypes must contain exactly four dictionaries'

  index=0
  while ((index < accessed_count)); do
    base="NSPrivacyAccessedAPITypes.$index"
    validate_dictionary_keys "$privacy_manifest" "$base" \
      'NSPrivacyAccessedAPIType,NSPrivacyAccessedAPITypeReasons' \
      "required-reason dictionary $index"
    category=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyAccessedAPIType" string \
      "required-reason category $index")
    reasons_count=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyAccessedAPITypeReasons" array \
      "required-reason list $index")
    [[ "$reasons_count" == '1' ]] || \
      die "required-reason list must contain one value at index $index"
    reason=$(plist_required "$privacy_manifest" \
      "$base.NSPrivacyAccessedAPITypeReasons.0" string \
      "required-reason value $index")

    case "$category:$reason" in
      NSPrivacyAccessedAPICategoryUserDefaults:CA92.1)
        ((seen_defaults == 0)) || die 'UserDefaults required reason is duplicated'
        seen_defaults=1
        ;;
      NSPrivacyAccessedAPICategoryFileTimestamp:C617.1)
        ((seen_timestamp == 0)) || die 'FileTimestamp required reason is duplicated'
        seen_timestamp=1
        ;;
      NSPrivacyAccessedAPICategorySystemBootTime:35F9.1)
        ((seen_boot_time == 0)) || die 'SystemBootTime required reason is duplicated'
        seen_boot_time=1
        ;;
      NSPrivacyAccessedAPICategoryDiskSpace:E174.1)
        ((seen_disk_space == 0)) || die 'DiskSpace required reason is duplicated'
        seen_disk_space=1
        ;;
      *)
        die 'an unexpected required-reason category/code pair is declared'
        ;;
    esac
    index=$((index + 1))
  done

  ((seen_defaults == 1 && seen_timestamp == 1 && seen_boot_time == 1 \
    && seen_disk_space == 1)) || \
    die 'required-reason category/code pairs are incomplete'
}

signature_field() {
  local metadata_file=$1
  local field=$2
  /usr/bin/awk -F= -v field="$field" '$1 == field { sub(/^[^=]*=/, ""); print; exit }' \
    "$metadata_file"
}

read_signature_metadata() {
  local code_path=$1
  local output_file=$2
  /usr/bin/codesign -d --verbose=4 "$code_path" >"$output_file" 2>&1
}

validate_developer_id_metadata() {
  local metadata_file=$1
  local label=$2
  local require_runtime=$3
  local team
  local timestamp

  /usr/bin/grep -q '^Signature=adhoc' "$metadata_file" && \
    die "$label has an ad-hoc signature"
  /usr/bin/grep -q '^Authority=Developer ID Application:' "$metadata_file" || \
    die "$label is not signed with Developer ID Application"
  team=$(signature_field "$metadata_file" 'TeamIdentifier')
  [[ "$team" == "$expected_team_id" ]] || \
    die "$label does not match the expected Team ID"
  timestamp=$(signature_field "$metadata_file" 'Timestamp')
  [[ -n "$timestamp" && "$timestamp" != 'none' ]] || \
    die "$label does not contain a secure signing timestamp"
  if ((require_runtime)); then
    /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' "$metadata_file" || \
      die "$label does not include Hardened Runtime"
  fi
}

entitlement_value() {
  local entitlements=$1
  local key=$2
  local expected_type=$3
  local escaped_key=${key//./\\.}
  plist_extract "$entitlements" "$escaped_key" "$expected_type"
}

validate_entitlements() {
  local app_path=$1
  local label=$2
  local require_app_entitlements=${3:-1}
  local entitlements="$temporary_root/entitlements-$validation_counter.plist"
  local keys_file="$temporary_root/entitlement-keys-$validation_counter.txt"
  local key
  local value
  local application_identifier
  local developer_team

  /usr/bin/codesign -d --entitlements :- "$app_path" \
    >"$entitlements" 2>"$temporary_root/entitlements-errors-$validation_counter.txt" || \
    die "$label entitlements could not be read"
  if [[ ! -s "$entitlements" ]]; then
    ((require_app_entitlements == 0)) && return
    die "$label required entitlements are missing"
  fi
  /usr/bin/plutil -lint "$entitlements" >/dev/null || \
    die "$label entitlements are not a valid property list"

  if ((require_app_entitlements)); then
    for key in \
      'com.apple.security.app-sandbox' \
      'com.apple.security.device.audio-input' \
      'com.apple.security.files.user-selected.read-write' \
      'com.apple.security.network.client'; do
      if ! value=$(entitlement_value "$entitlements" "$key" bool); then
        die "$label is missing a required boolean entitlement: $key"
      fi
      [[ "$value" == 'true' ]] || die "$label has a false required entitlement: $key"
    done
  fi

  /usr/libexec/PlistBuddy -c Print "$entitlements" | \
    /usr/bin/awk '/^    [^ ]/ { line=$0; sub(/^    /, "", line); sub(/ =.*/, "", line); print line }' \
    >"$keys_file"
  while IFS= read -r key; do
    case "$key" in
      com.apple.security.app-sandbox|\
      com.apple.security.device.audio-input|\
      com.apple.security.files.user-selected.read-write|\
      com.apple.security.network.client|\
      com.apple.application-identifier|\
      com.apple.developer.team-identifier|\
      com.apple.security.get-task-allow)
        ;;
      *)
        die "$label contains an unapproved entitlement: $key"
        ;;
    esac
  done <"$keys_file"

  if value=$(entitlement_value \
    "$entitlements" 'com.apple.security.get-task-allow' bool); then
    [[ "$value" == 'false' ]] || die "$label enables get-task-allow"
  fi
  if application_identifier=$(entitlement_value \
    "$entitlements" 'com.apple.application-identifier' string); then
    [[ "$application_identifier" == "$expected_team_id.$expected_bundle_id" ]] || \
      die "$label application identifier does not match expected Team/bundle IDs"
  fi
  if developer_team=$(entitlement_value \
    "$entitlements" 'com.apple.developer.team-identifier' string); then
    [[ "$developer_team" == "$expected_team_id" ]] || \
      die "$label entitlement Team ID does not match"
  fi
}

validate_nested_code() {
  local app_path=$1
  local label=$2
  local file_list="$temporary_root/nested-files-$validation_counter"
  local candidate
  local file_description
  local metadata_file
  local nested_count=0

  /usr/bin/find -P "$app_path/Contents" -type f -print0 >"$file_list" || \
    die "$label nested-code inventory could not be created"
  while IFS= read -r -d '' candidate; do
    if ! file_description=$(/usr/bin/file -b "$candidate" 2>/dev/null); then
      die "$label contains an unreadable nested file"
    fi
    [[ "$file_description" == *Mach-O* ]] || continue
    nested_count=$((nested_count + 1))
    /usr/bin/codesign --verify --strict "$candidate" \
      >"$temporary_root/nested-verify-$validation_counter-$nested_count.txt" 2>&1 || \
      die "$label contains nested code with an invalid signature"
    metadata_file="$temporary_root/nested-metadata-$validation_counter-$nested_count.txt"
    read_signature_metadata "$candidate" "$metadata_file" || \
      die "$label nested signature metadata could not be read"
    validate_developer_id_metadata "$metadata_file" "$label nested code" 0
    validate_entitlements "$candidate" "$label nested code" 0
  done <"$file_list"
  ((nested_count > 0)) || die "$label contains no signed Mach-O executable"
}

app_info_value() {
  local app_path=$1
  local key=$2
  /usr/libexec/PlistBuddy -c "Print :$key" "$app_path/Contents/Info.plist" 2>/dev/null
}

validate_app() {
  local app_path=$1
  local label=$2
  local metadata_file
  local identifier
  local bundle_id
  local version
  local build
  local package_type
  local executable_name
  local executable_path

  validation_counter=$((validation_counter + 1))
  [[ -d "$app_path" && ! -L "$app_path" ]] || die "$label is missing or is a symlink"
  reject_symlinks_in_tree "$app_path" "$label"
  [[ -f "$app_path/Contents/Info.plist" && ! -L "$app_path/Contents/Info.plist" ]] || \
    die "$label Info.plist is missing or is a symlink"
  /usr/bin/plutil -lint "$app_path/Contents/Info.plist" >/dev/null || \
    die "$label Info.plist is invalid"

  bundle_id=$(app_info_value "$app_path" 'CFBundleIdentifier') || \
    die "$label bundle identifier is missing"
  version=$(app_info_value "$app_path" 'CFBundleShortVersionString') || \
    die "$label marketing version is missing"
  build=$(app_info_value "$app_path" 'CFBundleVersion') || \
    die "$label build number is missing"
  package_type=$(app_info_value "$app_path" 'CFBundlePackageType') || \
    die "$label package type is missing"
  executable_name=$(app_info_value "$app_path" 'CFBundleExecutable') || \
    die "$label executable name is missing"
  [[ "$bundle_id" == "$expected_bundle_id" ]] || \
    die "$label bundle identifier does not match the expected value"
  [[ "$version" == "$expected_version" ]] || \
    die "$label marketing version does not match the expected value"
  [[ "$build" == "$expected_build" ]] || \
    die "$label build number does not match the expected value"
  [[ "$package_type" == 'APPL' ]] || die "$label is not an application bundle"
  executable_path="$app_path/Contents/MacOS/$executable_name"
  [[ -f "$executable_path" && ! -L "$executable_path" ]] || \
    die "$label main executable is missing or is a symlink"

  /usr/bin/codesign --verify --deep --strict "$app_path" \
    >"$temporary_root/app-verify-$validation_counter.txt" 2>&1 || \
    die "$label failed strict code-signature verification"
  metadata_file="$temporary_root/app-metadata-$validation_counter.txt"
  read_signature_metadata "$app_path" "$metadata_file" || \
    die "$label signature metadata could not be read"
  validate_developer_id_metadata "$metadata_file" "$label" 1
  identifier=$(signature_field "$metadata_file" 'Identifier')
  [[ "$identifier" == "$expected_bundle_id" ]] || \
    die "$label CodeDirectory identifier does not match the expected bundle ID"
  [[ -n "$(signature_field "$metadata_file" 'CDHash')" ]] || \
    die "$label CodeDirectory hash is missing"

  validate_entitlements "$app_path" "$label"
  validate_privacy_manifest "$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
  validate_nested_code "$app_path" "$label"

  /usr/sbin/spctl --assess --type execute --verbose=4 "$app_path" \
    >"$temporary_root/spctl-app-$validation_counter.txt" 2>&1 || \
    die "Gatekeeper rejected $label"
}

locate_dmg_app() {
  local app_list="$temporary_root/dmg-app-list"
  local candidate
  local candidate_bundle
  local match=''
  local app_count=0
  local match_count=0

  /usr/bin/find -P "$dmg_mountpoint" -type d -name '*.app' -print0 \
    >"$app_list" || die 'mounted DMG app inventory could not be created'
  while IFS= read -r -d '' candidate; do
    app_count=$((app_count + 1))
    [[ -f "$candidate/Contents/Info.plist" ]] || continue
    candidate_bundle=$(app_info_value "$candidate" 'CFBundleIdentifier' || true)
    [[ "$candidate_bundle" == "$expected_bundle_id" ]] || continue
    match=$candidate
    match_count=$((match_count + 1))
  done <"$app_list"
  [[ "$app_count" == '1' && "$match_count" == '1' ]] || \
    die 'DMG must contain exactly one app and it must have the expected bundle identifier'
  printf '%s\n' "$match"
}

assert_app_identity_binding() {
  local external_app=$1
  local contained_app=$2
  local external_bundle
  local contained_bundle
  local external_version
  local contained_version
  local external_build
  local contained_build
  local external_team
  local contained_team
  local external_hash
  local contained_hash
  local external_metadata="$temporary_root/external-bind-metadata.txt"
  local contained_metadata="$temporary_root/contained-bind-metadata.txt"

  external_bundle=$(app_info_value "$external_app" 'CFBundleIdentifier')
  contained_bundle=$(app_info_value "$contained_app" 'CFBundleIdentifier')
  external_version=$(app_info_value "$external_app" 'CFBundleShortVersionString')
  contained_version=$(app_info_value "$contained_app" 'CFBundleShortVersionString')
  external_build=$(app_info_value "$external_app" 'CFBundleVersion')
  contained_build=$(app_info_value "$contained_app" 'CFBundleVersion')
  read_signature_metadata "$external_app" "$external_metadata" || \
    die 'the supplied app identity metadata could not be read'
  read_signature_metadata "$contained_app" "$contained_metadata" || \
    die 'the DMG-contained app identity metadata could not be read'
  external_team=$(signature_field "$external_metadata" 'TeamIdentifier')
  contained_team=$(signature_field "$contained_metadata" 'TeamIdentifier')
  external_hash=$(signature_field "$external_metadata" 'CDHash')
  contained_hash=$(signature_field "$contained_metadata" 'CDHash')

  [[ "$external_bundle" == "$contained_bundle" \
    && "$external_version" == "$contained_version" \
    && "$external_build" == "$contained_build" \
    && "$external_team" == "$contained_team" \
    && -n "$external_hash" \
    && "$external_hash" == "$contained_hash" ]] || \
    die 'the DMG-contained app does not match the supplied app identity'
}

validate_dmg_signature() {
  local dmg_path=$1
  local metadata_file="$temporary_root/dmg-metadata.txt"

  /usr/bin/codesign --verify --strict "$dmg_path" \
    >"$temporary_root/codesign-dmg.txt" 2>&1 || \
    die 'the DMG failed code-signature verification'
  read_signature_metadata "$dmg_path" "$metadata_file" || \
    die 'the DMG signature metadata could not be read'
  validate_developer_id_metadata "$metadata_file" 'DMG' 0
  /usr/bin/xcrun stapler validate "$dmg_path" \
    >"$temporary_root/stapler-dmg.txt" 2>&1 || \
    die 'the DMG does not have a valid stapled notarization ticket'
  /usr/sbin/spctl --assess --type open \
    --context context:primary-signature --verbose=4 "$dmg_path" \
    >"$temporary_root/spctl-dmg.txt" 2>&1 || \
    die 'Gatekeeper rejected the DMG'
}

mount_and_bind_dmg() {
  local dmg_path=$1
  local external_app=$2
  local contained_app

  dmg_mountpoint="$temporary_root/dmg"
  /bin/mkdir "$dmg_mountpoint"
  /usr/bin/hdiutil attach "$dmg_path" -readonly -nobrowse -noautoopen \
    -owners off -mountpoint "$dmg_mountpoint" \
    >"$temporary_root/hdiutil-attach.txt" 2>&1 || \
    die 'the DMG could not be mounted read-only'
  dmg_mounted=1

  contained_app=$(locate_dmg_app)
  validate_app "$contained_app" 'DMG-contained app'
  assert_app_identity_binding "$external_app" "$contained_app"
  pass 'DMG-contained app identity and CodeDirectory hash binding'
}

main() {
  local archive_path=''
  local app_path=''
  local dmg_path=''
  local expected_bundle=''
  local expected_team=''
  local expected_marketing_version=''
  local expected_build_number=''
  local spctl_status

  while (($# > 0)); do
    case "$1" in
      --archive)
        (($# >= 2)) || die '--archive requires a path'
        archive_path=$2
        shift 2
        ;;
      --app)
        (($# >= 2)) || die '--app requires a path'
        app_path=$2
        shift 2
        ;;
      --dmg)
        (($# >= 2)) || die '--dmg requires a path'
        dmg_path=$2
        shift 2
        ;;
      --expected-bundle-id)
        (($# >= 2)) || die '--expected-bundle-id requires a value'
        expected_bundle=$2
        shift 2
        ;;
      --expected-team-id)
        (($# >= 2)) || die '--expected-team-id requires a value'
        expected_team=$2
        shift 2
        ;;
      --expected-version)
        (($# >= 2)) || die '--expected-version requires a value'
        expected_marketing_version=$2
        shift 2
        ;;
      --expected-build)
        (($# >= 2)) || die '--expected-build requires a value'
        expected_build_number=$2
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

  [[ -z "$archive_path" || -z "$app_path" ]] || \
    die 'pass either --archive or --app, not both'
  [[ -n "$archive_path" || -n "$app_path" ]] || \
    die 'an archive or app is required'
  [[ "$expected_bundle" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || \
    die 'a valid --expected-bundle-id is required'
  [[ "$expected_team" =~ ^[A-Za-z0-9]{10}$ ]] || \
    die 'a 10-character --expected-team-id is required'
  [[ "$expected_marketing_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || \
    die 'a numeric --expected-version is required'
  [[ "$expected_build_number" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || \
    die 'a valid --expected-build is required'

  expected_bundle_id=$expected_bundle
  expected_team_id=$expected_team
  expected_version=$expected_marketing_version
  expected_build=$expected_build_number

  for tool in /usr/bin/awk /usr/bin/codesign /usr/bin/file /usr/bin/find \
    /usr/bin/grep /usr/bin/hdiutil /usr/bin/head /usr/bin/mktemp /usr/bin/paste \
    /usr/bin/plutil /usr/bin/sort /usr/bin/xcrun /usr/sbin/spctl \
    /usr/libexec/PlistBuddy; do
    [[ -x "$tool" ]] || die "required tool is unavailable: $tool"
  done

  if [[ -n "$archive_path" ]]; then
    archive_path=$(canonical_directory "$archive_path" 'archive path')
    app_path=$(canonical_directory \
      "$archive_path/Products/Applications/SpeakNote.app" 'archive app')
  else
    app_path=$(canonical_directory "$app_path" 'app path')
  fi
  if [[ -n "$dmg_path" ]]; then
    dmg_path=$(canonical_file "$dmg_path" 'DMG path')
  fi

  temporary_root=$(/usr/bin/mktemp -d /tmp/SpeakNote-release.XXXXXX)
  trap cleanup EXIT

  if /usr/sbin/spctl --status >"$temporary_root/spctl-status.txt" 2>&1; then
    :
  fi
  spctl_status=$(/usr/bin/head -n 1 "$temporary_root/spctl-status.txt" || true)
  [[ "$spctl_status" == 'assessments enabled' ]] || \
    die 'Gatekeeper assessments are disabled or unavailable on this Mac'

  validate_app "$app_path" 'supplied app'
  pass 'supplied app identity, signatures, entitlements, privacy, and Gatekeeper'

  if [[ -n "$dmg_path" ]]; then
    validate_dmg_signature "$dmg_path"
    pass 'DMG signature, secure timestamp, notarization ticket, and Gatekeeper'
    mount_and_bind_dmg "$dmg_path" "$app_path"
  else
    /usr/bin/xcrun stapler validate "$app_path" \
      >"$temporary_root/stapler-app.txt" 2>&1 || \
      die 'the app does not have a valid stapled notarization ticket'
    pass 'app stapled notarization ticket'
  fi

  printf 'Release verification passed.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
