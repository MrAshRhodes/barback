#!/usr/bin/env bash
# Import the release identity into an isolated keychain, as in Glint's release workflow.
set -euo pipefail
set +x
umask 077

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
KEYCHAIN_NAME="barback-signing.keychain-db"
WORK_PARENT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
WORK_PARENT="$(cd "$WORK_PARENT" 2>/dev/null && pwd -P)" || die "the temporary directory is not usable"

SEARCH_LIST=()
read_search_list() {
  local output line
  output="$(security list-keychains -d user)" || return 1
  SEARCH_LIST=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#\"}"
    line="${line%\"}"
    if [[ -n "$line" ]]; then SEARCH_LIST+=("$line"); fi
  done <<<"$output"
}

cleanup() {
  local keychain="$1" work entry status=0 kept=()
  work="$(dirname "$keychain")"
  # Only remove the exact directory created by this script, never an arbitrary keychain.
  if [[ "$(basename "$keychain")" != "$KEYCHAIN_NAME" ||
        "$(dirname "$work")" != "$WORK_PARENT" ||
        "$(basename "$work")" != barback-signing.?????? || -L "$work" ]]; then
    printf 'error: refusing to remove a keychain outside a temporary Barback signing directory\n' >&2
    return 1
  fi
  if read_search_list; then
    for entry in ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}; do
      if [[ "$entry" != "$keychain" ]]; then kept+=("$entry"); fi
    done
    if ((${#kept[@]} > 0 && ${#kept[@]} != ${#SEARCH_LIST[@]})); then
      security list-keychains -d user -s "${kept[@]}" || status=1
    fi
  else
    status=1
  fi
  if [[ -e "$keychain" ]]; then
    security delete-keychain "$keychain" || status=1
  fi
  rm -rf "$work" || status=1
  return "$status"
}

if [[ $# == 2 && "$1" == --cleanup ]]; then
  cleanup "$2" || die "could not remove the temporary signing keychain"
  exit 0
fi
[[ $# == 0 ]] || die "usage: Scripts/import_signing_identity.sh [--cleanup KEYCHAIN]"
[[ "$(uname -s)" == Darwin ]] || die "this script needs macOS"
[[ -n "${BARBACK_SIGNING_P12_BASE64:-}" ]] || die "BARBACK_SIGNING_P12_BASE64 is empty"
[[ -n "${BARBACK_SIGNING_P12_PASSWORD:-}" ]] || die "BARBACK_SIGNING_P12_PASSWORD is empty"

WORK="$(mktemp -d "$WORK_PARENT/barback-signing.XXXXXX")"
KEYCHAIN="$WORK/$KEYCHAIN_NAME"
P12="$WORK/identity.p12"
IMPORTED=0
on_exit() {
  local status=$?
  if ! rm -f "$P12"; then
    printf 'error: could not remove the temporary PKCS#12 file\n' >&2
    status=1
  fi
  if ((!IMPORTED)); then
    if ! cleanup "$KEYCHAIN"; then
      printf 'error: temporary signing keychain cleanup failed\n' >&2
      status=1
    fi
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'keychain=%s\n' "$KEYCHAIN" >>"$GITHUB_OUTPUT"
fi

printf '%s' "$BARBACK_SIGNING_P12_BASE64" | tr -d '[:space:]' | base64 --decode >"$P12" \
  || die "BARBACK_SIGNING_P12_BASE64 is not valid base64"
[[ -s "$P12" ]] || die "the decoded PKCS#12 file is empty"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
read_search_list
ORIGINAL_SEARCH_LIST=(${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"})

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$BARBACK_SIGNING_P12_PASSWORD" \
  -T /usr/bin/codesign -f pkcs12 >/dev/null \
  || die "could not import the PKCS#12 signing identity"
rm -f "$P12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" ${ORIGINAL_SEARCH_LIST[@]+"${ORIGINAL_SEARCH_LIST[@]}"}

identities="$(security find-identity -v -p codesigning "$KEYCHAIN")"
identity=""
developer_id_re='^Developer ID Application: .+ \(TB3Z5R7SY8\)$'
while IFS= read -r line; do
  if [[ $line =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+\"(.*)\" ]]; then
    hash="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    if [[ $name =~ $developer_id_re ]]; then
      [[ -z "$identity" || "$identity" == "$hash" ]] || die "multiple matching Developer ID identities"
      identity="$hash"
    fi
  fi
done <<<"$identities"
[[ -n "$identity" ]] || die "no valid Developer ID Application identity for team TB3Z5R7SY8"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'identity=%s\n' "$identity" >>"$GITHUB_OUTPUT"
fi
printf '%s\n' "$identity"
IMPORTED=1
