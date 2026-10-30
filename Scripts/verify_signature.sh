#!/usr/bin/env bash
# Verify Barback's production signing policy, optionally including offline notarization tickets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] \
  || die "usage: Scripts/verify_signature.sh Barback.app|release.dmg [--require-notarized]"
TARGET="${1%/}"
NOTARIZED=0
if [[ $# == 2 ]]; then
  [[ "$2" == --require-notarized ]] || die "unknown argument: $2"
  NOTARIZED=1
fi
[[ -e "$TARGET" ]] || die "not found: $TARGET"

case "$TARGET" in
  *.app)
    REQUIREMENT="$ROOT/packaging/signing/designated-requirement.txt"
    ASSESS=(--type execute)
    ;;
  *.dmg)
    REQUIREMENT="$ROOT/packaging/signing/developer-id-requirement.txt"
    ASSESS=(--type open --context context:primary-signature)
    ;;
  *) die "expected an .app or .dmg" ;;
esac
codesign --verify --deep --strict --verbose=2 -R="$(cat "$REQUIREMENT")" "$TARGET" \
  || die "signature does not satisfy Barback's Developer ID policy"
details="$(codesign --display --verbose=4 "$TARGET" 2>&1)" \
  || die "could not read the signature"
grep -q '^TeamIdentifier=TB3Z5R7SY8$' <<<"$details" || die "unexpected signing team"
grep -q '^Timestamp=.' <<<"$details" || die "missing secure timestamp"
if [[ "$TARGET" == *.app ]]; then
  archs="$(lipo -archs "$TARGET/Contents/MacOS/Barback")" || die "cannot read app architectures"
  [[ -n "$archs" ]] || die "the app has no architectures"
  for arch in $archs; do
    slice="$(codesign --display --arch "$arch" --verbose=4 "$TARGET" 2>&1)" \
      || die "cannot read the $arch signature"
    grep -q '^CodeDirectory .*flags=.*runtime' <<<"$slice" || die "$arch is missing hardened runtime"
    grep -q '^Timestamp=.' <<<"$slice" || die "$arch is missing a secure timestamp"
  done
  codesign --display --requirements - "$TARGET"
fi
printf '%s\n' "$details" | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)='

if ((NOTARIZED)); then
  xcrun stapler validate "$TARGET" || die "missing or invalid stapled notarization ticket"
  if ! assessment="$(spctl --assess "${ASSESS[@]}" --verbose=2 "$TARGET" 2>&1)"; then
    printf '%s\n' "$assessment" >&2
    die "Gatekeeper rejected $TARGET"
  fi
  printf '%s\n' "$assessment"
  grep -q '^source=Notarized Developer ID$' <<<"$assessment" \
    || die "Gatekeeper did not report Notarized Developer ID"
fi
