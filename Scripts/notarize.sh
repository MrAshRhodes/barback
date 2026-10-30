#!/usr/bin/env bash
# Staple the app before archiving it: a ZIP cannot carry its own stapled ticket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 ]] || die "usage: Scripts/notarize.sh Barback.app|release.dmg|--check-credentials"

auth=()
if [[ -n "${BARBACK_NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$BARBACK_NOTARY_PROFILE")
  if [[ -n "${BARBACK_NOTARY_KEYCHAIN:-}" ]]; then
    auth+=(--keychain "$BARBACK_NOTARY_KEYCHAIN")
  fi
else
  [[ -n "${BARBACK_NOTARY_KEY_PATH:-}" && -n "${BARBACK_NOTARY_KEY_ID:-}" && -n "${BARBACK_NOTARY_ISSUER_ID:-}" ]] \
    || die "set BARBACK_NOTARY_PROFILE or BARBACK_NOTARY_KEY_PATH, BARBACK_NOTARY_KEY_ID and BARBACK_NOTARY_ISSUER_ID"
  [[ -s "$BARBACK_NOTARY_KEY_PATH" ]] || die "notarization key file is missing or empty"
  auth=(--key "$BARBACK_NOTARY_KEY_PATH" --key-id "$BARBACK_NOTARY_KEY_ID" --issuer "$BARBACK_NOTARY_ISSUER_ID")
fi
command -v jq >/dev/null || die "jq is required to validate Apple's notarization response"
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
if [[ "$1" == --check-credentials ]]; then
  xcrun notarytool history "${auth[@]}" --output-format json >/dev/null
  exit 0
fi

target="${1%/}"
"$ROOT/Scripts/verify_signature.sh" "$target"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/barback-notary.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
submission="$target"
if [[ "$target" == *.app ]]; then
  submission="$work/submission.zip"
  ditto -c -k --norsrc --noextattr --keepParent "$target" "$submission"
fi

printf '==> Submitting %s to Apple\n' "$target"
status=0
xcrun notarytool submit "$submission" "${auth[@]}" --wait --timeout 30m \
  --output-format json >"$work/result.json" || status=$?
cat "$work/result.json"
if ((status != 0)) || ! jq -e '.status == "Accepted"' "$work/result.json" >/dev/null; then
  if id="$(jq -er '.id | select(type == "string" and length > 0)' "$work/result.json" 2>/dev/null)"; then
    xcrun notarytool log "$id" "${auth[@]}" \
      || printf 'warning: could not retrieve diagnostics for submission %s\n' "$id" >&2
  fi
  die "notarization did not finish with Accepted status; nothing will be published"
fi
xcrun stapler staple "$target"
"$ROOT/Scripts/verify_signature.sh" "$target" --require-notarized
