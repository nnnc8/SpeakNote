#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  Scripts/security-scan.sh [--repo PATH] [--build-root PATH]
    [--bundle-id ID] [--log-window DURATION] [--log-file PATH]
    [--require-git-history] [--strict-runtime]

The scanner reports only the affected surface, never the matched value.
--strict-runtime requires a build root, existing sandbox UserDefaults and
Application Support data, and reachable Git history. Without it, unavailable
runtime/history surfaces are reported as skipped for source-only CI.
USAGE
}

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
}

skip() {
  printf 'SKIP: %s\n' "$1"
}

script_directory=$(cd "$(dirname "$0")" && pwd -P)
repo_path=$(cd "$script_directory/.." && pwd -P)
build_root=''
bundle_id='com.nc8.SpeakNote'
log_window='1h'
log_file=''
strict_runtime=0
require_git_history=0

while (($# > 0)); do
  case "$1" in
    --repo)
      (($# >= 2)) || { usage >&2; exit 2; }
      repo_path=$2
      shift 2
      ;;
    --build-root)
      (($# >= 2)) || { usage >&2; exit 2; }
      build_root=$2
      shift 2
      ;;
    --bundle-id)
      (($# >= 2)) || { usage >&2; exit 2; }
      bundle_id=$2
      shift 2
      ;;
    --log-window)
      (($# >= 2)) || { usage >&2; exit 2; }
      log_window=$2
      shift 2
      ;;
    --log-file)
      (($# >= 2)) || { usage >&2; exit 2; }
      log_file=$2
      shift 2
      ;;
    --strict-runtime)
      strict_runtime=1
      require_git_history=1
      shift
      ;;
    --require-git-history)
      require_git_history=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ ! -L "$repo_path" ]] || { printf 'Repository scan root must not be a symlink.\n' >&2; exit 2; }
[[ -d "$repo_path" ]] || { printf 'Repository path is not a directory.\n' >&2; exit 2; }
repo_path=$(cd "$repo_path" && pwd -P)
[[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || {
  printf 'Bundle identifier contains unsupported characters.\n' >&2
  exit 2
}
[[ "$log_window" =~ ^[0-9]+[smhd]$ ]] || {
  printf 'Log window must look like 30m, 1h, or 2d.\n' >&2
  exit 2
}

for tool in /usr/bin/find /usr/bin/git /usr/bin/grep /usr/bin/log /usr/bin/mktemp /usr/bin/plutil; do
  [[ -x "$tool" ]] || { printf 'Required scanner tool is unavailable.\n' >&2; exit 2; }
done

temporary_root=$(/usr/bin/mktemp -d /tmp/SpeakNote-security.XXXXXX)
cleanup() {
  if [[ "$temporary_root" == /tmp/SpeakNote-security.* && -d "$temporary_root" ]]; then
    /bin/rm -rf -- "$temporary_root"
  fi
}
trap cleanup EXIT

# Split prefixes keep the scanner's own source from containing credential-shaped values.
groq_prefix='gsk'
generic_prefix='s''k'
github_prefix='gh'
aws_prefix='AKIA'
google_prefix='AIza'
slack_prefix='xox'
stripe_prefix='s''k'
private_key_begin='-----BEGIN'
secret_pattern="${groq_prefix}_[A-Za-z0-9_-]{20,}|${generic_prefix}-[A-Za-z0-9_-]{32,}|bearer[[:space:]]+[A-Za-z0-9._~+/-]{20,}|${github_prefix}[pousr]_[A-Za-z0-9]{20,}|${github_prefix}ithub_pat_[A-Za-z0-9_]{20,}|${aws_prefix}[0-9A-Z]{16}|${google_prefix}[A-Za-z0-9_-]{35}|${slack_prefix}[baprs]-[A-Za-z0-9-]{20,}|${stripe_prefix}_(live|test)_[A-Za-z0-9]{20,}|${private_key_begin}[[:space:]]+(RSA[[:space:]]+|EC[[:space:]]+|OPENSSH[[:space:]]+)?PRIVATE[[:space:]]+KEY-----"
generic_secret_pattern="['\"]?(api[_ -]?key|apikey|access[_ -]?token|client[_ -]?secret|secret)['\"]?[[:space:]]*[:=][[:space:]]*['\"][A-Za-z0-9_+./~-]{24,}['\"]|(api[_ -]?key|apikey)[[:space:]]*:[[:space:]]*[A-Za-z0-9_+./~-]{32,}"
environment_secret_pattern="(^|[^A-Za-z0-9_])(API_KEY|GROQ_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|ACCESS_TOKEN|GITHUB_TOKEN|CLIENT_SECRET|STRIPE_SECRET_KEY|AWS_SECRET_ACCESS_KEY)[[:space:]]*=[[:space:]]*['\"]?[A-Za-z0-9_+./~-]{24,}"
log_payload_pattern="['\"]?(authorization|api[_ -]?key|transcript|prompt|response[_ -]?body|audio[_ -]?(bytes|path))['\"]?[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z0-9_+./~-]{4,}"
scan_counter=0

canonical_existing_path() {
  local input=$1
  local label=$2
  local directory
  local filename
  local physical_directory

  [[ "$input" != *$'\n'* ]] || { printf '%s path contains a newline.\n' "$label" >&2; exit 2; }
  [[ ! -L "$input" ]] || { printf '%s must not be a symlink.\n' "$label" >&2; exit 2; }
  if [[ -d "$input" ]]; then
    (cd "$input" && pwd -P) || exit 2
    return
  fi
  [[ -f "$input" ]] || { printf '%s does not exist.\n' "$label" >&2; exit 2; }
  directory=$(dirname "$input")
  filename=$(basename "$input")
  physical_directory=$(cd "$directory" && pwd -P) || exit 2
  [[ -f "$physical_directory/$filename" && ! -L "$physical_directory/$filename" ]] || {
    printf '%s canonical path is invalid.\n' "$label" >&2
    exit 2
  }
  printf '%s/%s\n' "$physical_directory" "$filename"
}

file_has_secret() {
  local file=$1
  LC_ALL=C /usr/bin/grep -a -E -i -q \
    "$secret_pattern|$generic_secret_pattern" "$file" 2>/dev/null && return 0
  local status=$?
  ((status == 1)) || return "$status"
  LC_ALL=C /usr/bin/grep -a -E -q "$environment_secret_pattern" "$file" 2>/dev/null
}

scan_tree() {
  local label=$1
  local path=$2
  local exclude_git=${3:-0}
  local file
  local status
  local found=0
  local file_list
  local symlink_found=0

  if [[ ! -e "$path" ]]; then
    return 2
  fi
  if [[ -L "$path" ]]; then
    fail "$label scan root is a symlink"
    return 0
  fi

  if [[ -f "$path" ]]; then
    if file_has_secret "$path"; then
      found=1
    else
      status=$?
      if ((status > 1)); then
        fail "$label could not be scanned"
        return 0
      fi
    fi
  else
    scan_counter=$((scan_counter + 1))
    file_list="$temporary_root/file-list-$scan_counter"
    if ((exclude_git)); then
      if ! /usr/bin/find -P "$path" -path "$path/.git" -prune -o \
        \( -type f -o -type l \) -print0 \
        >"$file_list"; then
        fail "$label file list could not be read"
        return 0
      fi
    elif ! /usr/bin/find -P "$path" \( -type f -o -type l \) -print0 \
      >"$file_list"; then
      fail "$label file list could not be read"
      return 0
    fi
    while IFS= read -r -d '' file; do
      if [[ -L "$file" ]]; then
        symlink_found=1
        continue
      fi
      if file_has_secret "$file"; then
        found=1
        break
      else
        status=$?
        if ((status > 1)); then
          fail "$label could not be scanned"
          return 0
        fi
      fi
    done <"$file_list"
  fi

  if ((symlink_found)); then
    fail "$label contains a symlink that could bypass content scanning"
  fi

  if ((found)); then
    fail "$label contains a credential-shaped value or private key"
  else
    pass "$label secret-shape scan"
  fi
}

scan_tree 'repository' "$repo_path" 1 || true

scan_git_history() {
  local commit_list="$temporary_root/git-commits"
  local names_file="$temporary_root/git-names"
  local commit
  local status
  local found=0

  if ! /usr/bin/git -C "$repo_path" rev-parse --is-inside-work-tree \
    >/dev/null 2>&1; then
    if ((require_git_history)); then
      fail 'repository is not a Git worktree; reachable history cannot be scanned'
    else
      skip 'reachable Git history scan; repository is not a Git worktree'
    fi
    return
  fi
  if ! /usr/bin/git -C "$repo_path" rev-parse --verify HEAD >/dev/null 2>&1; then
    if ((require_git_history)); then
      fail 'repository has no reachable commits; release history gate cannot pass'
    else
      skip 'reachable Git history scan; repository has no commits'
    fi
    return
  fi
  if ! /usr/bin/git -C "$repo_path" rev-list --all >"$commit_list"; then
    fail 'reachable Git commit inventory could not be created'
    return
  fi

  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    if /usr/bin/git -C "$repo_path" grep -E -i -q \
      "$secret_pattern|$generic_secret_pattern" "$commit" -- 2>/dev/null; then
      found=1
      break
    else
      status=$?
      if ((status > 1)); then
        fail 'reachable Git blob content could not be scanned'
        return
      fi
    fi
    if /usr/bin/git -C "$repo_path" grep -E -q \
      "$environment_secret_pattern" "$commit" -- 2>/dev/null; then
      found=1
      break
    else
      status=$?
      if ((status > 1)); then
        fail 'reachable Git blob content could not be scanned'
        return
      fi
    fi
    if ! /usr/bin/git -C "$repo_path" ls-tree -r --name-only "$commit" \
      >"$names_file"; then
      fail 'reachable Git filename inventory could not be scanned'
      return
    fi
    if LC_ALL=C /usr/bin/grep -Eiq \
      '(^|/)([.]env|[.]env[.]local|[.]env[.]production|[^/]+[.](p8|p12))$' \
      "$names_file"; then
      found=1
      break
    fi
  done <"$commit_list"

  if ((found)); then
    fail 'reachable Git history contains a credential-shaped value or private credential file'
  else
    pass 'reachable Git history secret scan'
  fi
}

scan_git_history

sensitive_file=''
if ! sensitive_file=$(/usr/bin/find -P "$repo_path" \
  -path "$repo_path/.git" -prune -o -type f \
  \( -name '.env' -o -name '.env.local' -o -name '.env.production' \
     -o -name '*.p8' -o -name '*.p12' \) -print -quit); then
  fail 'repository private credential filenames could not be scanned'
elif [[ -n "$sensitive_file" ]]; then
  fail 'repository contains a private credential file'
else
  pass 'repository private credential filename scan'
fi

if [[ -n "$build_root" ]]; then
  if [[ -e "$build_root" ]]; then
    build_root=$(canonical_existing_path "$build_root" 'Build scan root')
    scan_tree 'build artifact' "$build_root" || true
  else
    fail 'the requested build root does not exist'
  fi
elif ((strict_runtime)); then
  fail '--strict-runtime requires --build-root'
else
  skip 'build artifact scan; pass --build-root to enable it'
fi

preference_paths=(
  "$HOME/Library/Containers/$bundle_id/Data/Library/Preferences/$bundle_id.plist"
  "$HOME/Library/Preferences/$bundle_id.plist"
)
preference_count=0
for preference_path in "${preference_paths[@]}"; do
  if [[ -L "$preference_path" ]]; then
    fail 'UserDefaults scan root is a symlink'
    continue
  fi
  [[ -f "$preference_path" ]] || continue
  preference_count=$((preference_count + 1))
  normalized_preferences="$temporary_root/preferences-$preference_count.plist"
  if ! /usr/bin/plutil -convert xml1 -o "$normalized_preferences" "$preference_path" \
    >/dev/null 2>&1; then
    fail 'a UserDefaults property list could not be decoded'
    continue
  fi
  scan_tree 'UserDefaults' "$normalized_preferences" || true
  if LC_ALL=C /usr/bin/grep -Eiq \
    '<key>(api[_ -]?key|authorization|credential|secret)</key>' \
    "$normalized_preferences"; then
    fail 'UserDefaults contains a forbidden secret-bearing key'
  else
    pass 'UserDefaults forbidden-key scan'
  fi
done
if ((preference_count == 0)); then
  if ((strict_runtime)); then
    fail 'no UserDefaults file exists for the bundle identifier'
  else
    skip 'UserDefaults scan; no preferences file exists yet'
  fi
fi

support_paths=(
  "$HOME/Library/Containers/$bundle_id/Data/Library/Application Support/SpeakNote"
  "$HOME/Library/Application Support/SpeakNote"
)
support_count=0
for support_path in "${support_paths[@]}"; do
  if [[ -L "$support_path" ]]; then
    fail 'Application Support scan root is a symlink'
    continue
  fi
  [[ -d "$support_path" ]] || continue
  support_count=$((support_count + 1))
  scan_tree 'Application Support' "$support_path" || true
done
if ((support_count == 0)); then
  if ((strict_runtime)); then
    fail 'no Application Support directory exists for SpeakNote'
  else
    skip 'Application Support scan; no runtime data exists yet'
  fi
fi

if [[ -n "$log_file" ]]; then
  if [[ ! -f "$log_file" ]]; then
    fail 'the requested log file does not exist'
    log_file=''
  fi
  if [[ -n "$log_file" ]]; then
    log_file=$(canonical_existing_path "$log_file" 'Log scan file')
  fi
else
  log_file="$temporary_root/unified-log.ndjson"
  if ! /usr/bin/log show --last "$log_window" --style ndjson \
    --predicate "subsystem == \"$bundle_id\"" >"$log_file" 2>/dev/null; then
    fail 'unified log metadata could not be queried'
    log_file=''
  fi
fi

if [[ -n "$log_file" ]]; then
  scan_tree 'unified log metadata' "$log_file" || true
  if LC_ALL=C /usr/bin/grep -Eiq "$log_payload_pattern" "$log_file"; then
    fail 'unified log metadata contains a forbidden payload marker'
  else
    pass 'unified log payload-marker scan'
  fi
fi

if ((failures > 0)); then
  printf 'Security scan failed on %d surface(s); matched values were not printed.\n' \
    "$failures" >&2
  exit 1
fi

printf 'Security scan passed; no matched values were printed.\n'
