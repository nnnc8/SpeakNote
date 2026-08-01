#!/bin/bash

set -euo pipefail

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

release_tag=${1:-}
repository=${2:-}

[[ "$release_tag" =~ ^v[0-9]+([.][0-9]+){2}$ ]] || \
  die 'release tag must match v followed by three numeric components'
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  die 'repository must use owner/name format'
[[ -n "${GH_TOKEN:-}" ]] || die 'GitHub token is unavailable'
[[ "${RUNNER_TEMP:-}" == /* && -d "$RUNNER_TEMP" && ! -L "$RUNNER_TEMP" ]] || \
  die 'RUNNER_TEMP must be an existing absolute non-symlink directory'

for tool in /usr/bin/basename /usr/bin/codesign /usr/bin/find \
  /usr/bin/hdiutil /usr/bin/lipo /usr/bin/shasum /usr/bin/sw_vers \
  /usr/bin/tr /usr/bin/wc /usr/bin/xcrun /usr/libexec/PlistBuddy \
  /usr/sbin/spctl; do
  [[ -x "$tool" ]] || die "required tool is unavailable: $tool"
done
gh_path=$(command -v gh) || die 'GitHub CLI is unavailable'

version=${release_tag#v}
dmg_name="SpeakNote-$version.dmg"
checksum_name="$dmg_name.sha256"
expected_asset_manifest="[\"$dmg_name\",\"$checksum_name\"]"
asset_dir="$RUNNER_TEMP/SpeakNote-release-smoke"
[[ ! -e "$asset_dir" ]] || die 'release verification directory already exists'
/bin/mkdir "$asset_dir"

asset_manifest=$("$gh_path" api "repos/$repository/releases/tags/$release_tag" \
  --jq '[.assets[].name] | sort | @json') || \
  die 'release asset manifest could not be read'
[[ "$asset_manifest" == "$expected_asset_manifest" ]] || \
  die 'release must contain exactly the expected DMG and checksum assets'

"$gh_path" release download "$release_tag" \
  --repo "$repository" \
  --dir "$asset_dir" \
  --pattern "$dmg_name" \
  --pattern "$checksum_name"

dmg_path="$asset_dir/$dmg_name"
checksum_path="$asset_dir/$checksum_name"
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || die 'DMG asset is missing or unsafe'
[[ -f "$checksum_path" && ! -L "$checksum_path" ]] || \
  die 'checksum asset is missing or unsafe'

asset_count=$(/usr/bin/find -P "$asset_dir" -maxdepth 1 -type f -print | \
  /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')
[[ "$asset_count" == '2' ]] || die 'download must contain exactly two release assets'
line_count=$(/usr/bin/wc -l <"$checksum_path" | /usr/bin/tr -d '[:space:]')
[[ "$line_count" == '1' ]] || die 'checksum asset must contain exactly one line'

checksum_hash=''
checksum_file=''
checksum_extra=''
read -r checksum_hash checksum_file checksum_extra <"$checksum_path"
[[ "$checksum_hash" =~ ^[0-9A-Fa-f]{64}$ ]] || die 'checksum hash is malformed'
checksum_file=${checksum_file#\*}
[[ "$checksum_file" == "$dmg_name" && -z "$checksum_extra" ]] || \
  die 'checksum filename does not match the expected DMG'
(
  cd "$asset_dir"
  /usr/bin/shasum -a 256 -c "$checksum_name"
)

/usr/bin/codesign --verify --strict --verbose=2 "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
[[ "$(/usr/sbin/spctl --status 2>&1)" == 'assessments enabled' ]] || \
  die 'Gatekeeper assessments are not enabled'
/usr/sbin/spctl --assess --type open \
  --context context:primary-signature --verbose=4 "$dmg_path"

mount_point="$asset_dir/mount"
/bin/mkdir "$mount_point"
mounted=0
cleanup() {
  local status=$?
  if ((mounted)); then
    if ! /usr/bin/hdiutil detach "$mount_point" >/dev/null 2>&1; then
      printf 'FAIL: mounted DMG could not be detached\n' >&2
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/hdiutil attach "$dmg_path" -readonly -nobrowse -noautoopen \
  -owners off -mountpoint "$mount_point" >/dev/null
mounted=1

app_list="$asset_dir/apps"
/usr/bin/find -P "$mount_point" -type d -name '*.app' -print0 >"$app_list"
app_count=0
app_path=''
while IFS= read -r -d '' candidate; do
  [[ "$candidate" != *$'\n'* ]] || die 'mounted app path contains a newline'
  app_count=$((app_count + 1))
  app_path=$candidate
done <"$app_list"
[[ "$app_count" == '1' && "$(/usr/bin/basename "$app_path")" == 'SpeakNote.app' ]] || \
  die 'DMG must contain exactly one app named SpeakNote.app'
[[ -d "$app_path" && ! -L "$app_path" ]] || die 'SpeakNote.app is missing or unsafe'

info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" && ! -L "$info_plist" ]] || die 'app Info.plist is missing or unsafe'
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist") || \
  die 'app bundle identifier is unavailable'
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist") || \
  die 'app version is unavailable'
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist") || \
  die 'app executable name is unavailable'
[[ "$bundle_id" == 'com.nc8.SpeakNote' ]] || die 'app bundle identifier is unexpected'
[[ "$app_version" == "$version" ]] || die 'app version does not match the release tag'
[[ "$executable_name" =~ ^[A-Za-z0-9._-]+$ ]] || die 'app executable name is unsafe'
executable_path="$app_path/Contents/MacOS/$executable_name"
[[ -f "$executable_path" && ! -L "$executable_path" ]] || \
  die 'app executable is missing or unsafe'

architectures=$(/usr/bin/lipo -archs "$executable_path") || \
  die 'app architectures could not be read'
[[ "$architectures" == 'arm64 x86_64' || "$architectures" == 'x86_64 arm64' ]] || \
  die 'app executable must contain exactly arm64 and x86_64'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"

if ! /usr/bin/hdiutil detach "$mount_point" >/dev/null; then
  die 'mounted DMG could not be detached'
fi
mounted=0
trap - EXIT INT TERM

printf 'Release smoke passed for %s on %s.\n' "$release_tag" "$(/usr/bin/sw_vers -productVersion)"
