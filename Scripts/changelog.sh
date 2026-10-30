#!/usr/bin/env bash
#
# changelog.sh - small helper for CHANGELOG.md (Keep a Changelog 1.1.0 format).
#
# Usage:
#   Scripts/changelog.sh check
#       Validate the structure: an "## [Unreleased]" section first, then
#       "## [X.Y.Z] - YYYY-MM-DD" sections, newest first, each with a link reference.
#   Scripts/changelog.sh notes X.Y.Z [--allow-unreleased]
#       Print the body of the X.Y.Z section (used as GitHub release notes). With
#       --allow-unreleased, fall back to the Unreleased section when X.Y.Z has none.
#   Scripts/changelog.sh release X.Y.Z [--date YYYY-MM-DD]
#       Move the Unreleased entries into a new dated X.Y.Z section and update the links.
#
# Environment: CHANGELOG (default: CHANGELOG.md in the project root).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FILE="${CHANGELOG:-$ROOT/CHANGELOG.md}"
REPO_URL="https://github.com/MrAshRhodes/barback"

die() {
  printf 'changelog: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

version_re='^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$'

check_version() {
  [[ $1 =~ $version_re ]] || die "invalid version '$1' (expected e.g. 1.2.3)"
}

# Print the body of the "## [name]" section, without its heading and trailing blank lines.
section_body() {
  awk -v name="$1" '
    BEGIN { heading = "## [" name "]" }
    /^## \[/ {
      if (inside) exit
      if (index($0, heading) == 1) { inside = 1; next }
    }
    /^\[[^]]+\]: / { if (inside) exit }
    inside { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      start = 1
      while (start <= n && lines[start] ~ /^[[:space:]]*$/) start++
      for (i = start; i <= n; i++) print lines[i]
    }
  ' "$FILE"
}

has_section() {
  grep -Fq "## [$1]" "$FILE"
}

cmd_check() {
  [[ -f "$FILE" ]] || die "$FILE not found"
  local errors=0 first="" prev_date="" line name rest date headings
  headings="$(grep -E "^## " "$FILE" || true)"
  while IFS= read -r line; do
    if [[ $line =~ ^##\ \[([^]]+)\](.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      if [[ -z "$first" ]]; then
        first="$name"
        [[ "$name" == Unreleased ]] || {
          echo "error: the first section must be [Unreleased], found [$name]" >&2
          errors=$((errors + 1))
        }
        continue
      fi
      if [[ ! $name =~ $version_re ]]; then
        echo "error: invalid version heading: $line" >&2
        errors=$((errors + 1))
        continue
      fi
      if [[ $rest =~ ^\ -\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
        date="${BASH_REMATCH[1]}"
        if [[ -n "$prev_date" && "$date" > "$prev_date" ]]; then
          echo "error: [$name] ($date) is newer than the section above it ($prev_date)" >&2
          errors=$((errors + 1))
        fi
        prev_date="$date"
      else
        echo "error: expected '## [$name] - YYYY-MM-DD', found: $line" >&2
        errors=$((errors + 1))
      fi
      if ! grep -q "^\[${name//./\\.}\]: " "$FILE"; then
        echo "error: no link reference for [$name]" >&2
        errors=$((errors + 1))
      fi
    fi
  done <<<"$headings"
  [[ -n "$first" ]] || {
    echo "error: no sections found" >&2
    errors=$((errors + 1))
  }
  grep -Eq '^\[Unreleased\]: ' "$FILE" || {
    echo "error: no link reference for [Unreleased]" >&2
    errors=$((errors + 1))
  }
  ((errors == 0)) || die "$errors problem(s) in ${FILE#"$ROOT"/}"
  echo "${FILE#"$ROOT"/} looks good"
}

cmd_notes() {
  local version="${1:-}" allow_unreleased=0
  [[ -n "$version" ]] || die "notes needs a version"
  shift
  [[ "${1:-}" == --allow-unreleased ]] && allow_unreleased=1
  version="${version#v}"
  check_version "$version"
  if has_section "$version"; then
    section_body "$version"
  elif ((allow_unreleased)); then
    section_body Unreleased
  else
    die "no '## [$version]' section in ${FILE#"$ROOT"/}"
  fi
}

cmd_release() {
  local version="${1:-}" date
  [[ -n "$version" ]] || die "release needs a version"
  shift
  date="$(date +%Y-%m-%d)"
  if [[ "${1:-}" == --date ]]; then
    date="${2:?--date needs a value}"
  fi
  version="${version#v}"
  check_version "$version"
  has_section "$version" && die "${FILE#"$ROOT"/} already has a [$version] section"
  [[ -n "$(section_body Unreleased)" ]] || die "the [Unreleased] section is empty"

  local previous
  previous="$(grep -Eo '^## \[[0-9][^]]*\]' "$FILE" | head -n 1 | sed -E 's/^## \[(.*)\]$/\1/' || true)"

  local out="$FILE.new"
  awk -v version="$version" -v date="$date" -v repo="$REPO_URL" -v previous="$previous" '
    /^## \[Unreleased\]/ { print; print ""; print "## [" version "] - " date; next }
    /^\[Unreleased\]: / {
      print "[Unreleased]: " repo "/compare/v" version "...HEAD"
      if (previous != "") print "[" version "]: " repo "/compare/v" previous "...v" version
      else print "[" version "]: " repo "/releases/tag/v" version
      next
    }
    { print }
  ' "$FILE" >"$out"
  mv "$out" "$FILE"
  echo "Moved the Unreleased entries into [$version] - $date"
}

case "${1:-}" in
  check) cmd_check ;;
  notes) cmd_notes "${@:2}" ;;
  release) cmd_release "${@:2}" ;;
  -h | --help | "") usage ;;
  *) die "unknown command '$1' (see --help)" ;;
esac
