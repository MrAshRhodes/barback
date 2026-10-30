#!/usr/bin/env bash
#
# package_release.sh - build a universal Barback.app and package it for release.
#
# Usage:
#   Scripts/package_release.sh [--version X.Y.Z] [--formats zip[,dmg]] [--build-number N]
#                              [--require-universal] [--skip-build] [--notarize]
#
#   --version X.Y.Z       Release version. Default: the contents of VERSION.
#   --formats LIST        Comma-separated: zip, dmg. Default: zip (what releases and the cask use).
#   --build-number N      CFBundleVersion, passed to build_app.sh.
#   --require-universal   Fail when the x86_64 slice cannot be built instead of shipping an
#                         arm64-only app.
#   --skip-build          Package the existing dist/Barback.app (its version must match).
#   --notarize            Require Developer ID, notarize and staple before creating final archives.
#
# Outputs, all in dist/:
#   Barback-<v>.zip + Barback-<v>.zip.sha256   (ditto archive; what the Homebrew cask installs)
#   Barback-<v>.dmg + Barback-<v>.dmg.sha256   (optional drag-to-Applications disk image)
#   barback.rb                                 (Homebrew cask for the zip, when it is built)
#
# Every requested format has to succeed, otherwise the script exits non-zero.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/Barback.app"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/package_release.sh [--version X.Y.Z] [--formats zip[,dmg]] [--build-number N]
                                  [--require-universal] [--skip-build] [--notarize]

Builds a universal dist/Barback.app and packages it:
  dist/Barback-<v>.zip + .sha256, dist/barback.rb (Homebrew cask), optionally dist/Barback-<v>.dmg + .sha256

  --version X.Y.Z       release version (default: contents of VERSION)
  --formats LIST        comma-separated: zip, dmg (default: zip)
  --build-number N      CFBundleVersion (default: $GITHUB_RUN_NUMBER, git commit count, or 1)
  --require-universal   fail instead of shipping an arm64-only app
  --skip-build          package the existing dist/Barback.app
  --notarize            require Developer ID, notarize and staple app/DMG before checksums
EOF
}

VERSION=""
FORMATS="zip"
BUILD_NUMBER=""
REQUIRE_UNIVERSAL=0
SKIP_BUILD=0
NOTARIZE=0

while (($#)); do
  case "$1" in
    --version)
      VERSION="${2:?--version needs a value}"
      shift
      ;;
    --version=*) VERSION="${1#*=}" ;;
    --formats)
      FORMATS="${2:?--formats needs a value}"
      shift
      ;;
    --formats=*) FORMATS="${1#*=}" ;;
    --build-number)
      BUILD_NUMBER="${2:?--build-number needs a value}"
      shift
      ;;
    --build-number=*) BUILD_NUMBER="${1#*=}" ;;
    --require-universal) REQUIRE_UNIVERSAL=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --notarize) NOTARIZE=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

if [[ -z "$VERSION" ]]; then
  [[ -f "$ROOT/VERSION" ]] || die "no --version given and VERSION file not found"
  VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
VERSION="${VERSION#v}"
version_re='^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$'
[[ $VERSION =~ $version_re ]] || die "invalid version '$VERSION' (expected e.g. 1.2.3 or 1.2.3-beta.1)"

WANT_ZIP=0
WANT_DMG=0
IFS=',' read -r -a format_list <<<"$FORMATS"
for format in "${format_list[@]}"; do
  case "$format" in
    zip) WANT_ZIP=1 ;;
    dmg) WANT_DMG=1 ;;
    *) die "unknown format '$format' (expected zip and/or dmg)" ;;
  esac
done
((WANT_ZIP || WANT_DMG)) || die "no formats requested"

if ((NOTARIZE)); then
  [[ -n "${BARBACK_SIGN_IDENTITY:-}" && "$BARBACK_SIGN_IDENTITY" != "-" ]] \
    || die "--notarize requires BARBACK_SIGN_IDENTITY (Developer ID Application)"
  "$ROOT/Scripts/notarize.sh" --check-credentials
fi

ZIP="$DIST/Barback-$VERSION.zip"
DMG="$DIST/Barback-$VERSION.dmg"
STAGE="$DIST/dmg-stage"
VERIFY_DIR="$DIST/zip-verify"

if ((SKIP_BUILD)); then
  [[ -d "$APP" ]] || die "--skip-build was given but $APP does not exist"
else
  build_args=(--universal --configuration release --version "$VERSION")
  if [[ -n "$BUILD_NUMBER" ]]; then
    build_args+=(--build-number "$BUILD_NUMBER")
  fi
  if ((REQUIRE_UNIVERSAL)); then
    build_args+=(--require-universal)
  fi
  "$ROOT/Scripts/build_app.sh" "${build_args[@]}"
fi

built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$built_version" == "$VERSION" ]] \
  || die "$APP is version $built_version, expected $VERSION (rebuild without --skip-build)"
codesign --verify --deep --strict "$APP" || die "$APP has an invalid code signature"

archs="$(lipo -archs "$APP/Contents/MacOS/Barback")"
if ((REQUIRE_UNIVERSAL)) && [[ " $archs " != *" x86_64 "* || " $archs " != *" arm64 "* ]]; then
  die "the app is not universal (archs: $archs)"
fi
log "Packaging Barback $VERSION (archs: $archs)"

if ((NOTARIZE)); then
  "$ROOT/Scripts/notarize.sh" "$APP"
fi

write_checksum() {
  local file="$1"
  (cd "$(dirname "$file")" && shasum -a 256 "$(basename "$file")" >"$(basename "$file").sha256")
}

if ((WANT_ZIP)); then
  log "Creating ${ZIP#"$ROOT"/}"
  rm -f "$ZIP" "$ZIP.sha256"
  # --norsrc/--noextattr keep macOS provenance attributes out of the archive; they would
  # otherwise become ._* entries that plain `unzip` extracts into the signed bundle.
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  if unzip -Z1 "$ZIP" | grep -Eq '(^|/)\._|^__MACOSX/'; then
    die "${ZIP#"$ROOT"/} contains AppleDouble (._*) entries"
  fi

  # The archive must unpack (with plain unzip, as Homebrew does) into an intact signed bundle.
  rm -rf "$VERIFY_DIR"
  mkdir -p "$VERIFY_DIR"
  unzip -q "$ZIP" -d "$VERIFY_DIR"
  codesign --verify --deep --strict "$VERIFY_DIR/Barback.app" \
    || die "the app extracted from ${ZIP#"$ROOT"/} fails signature verification"
  if ((NOTARIZE)); then
    xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");BarbackReleaseVerification;" \
      "$VERIFY_DIR/Barback.app"
    "$ROOT/Scripts/verify_signature.sh" "$VERIFY_DIR/Barback.app" --require-notarized
    xattr -p com.apple.quarantine "$VERIFY_DIR/Barback.app" >/dev/null \
      || die "verification unexpectedly removed quarantine"
  fi
  rm -rf "$VERIFY_DIR"
  write_checksum "$ZIP"
fi

if ((WANT_DMG)); then
  log "Creating ${DMG#"$ROOT"/}"
  rm -rf "$STAGE"
  rm -f "$DMG" "$DMG.sha256"
  mkdir -p "$STAGE"
  ditto --norsrc --noextattr "$APP" "$STAGE/Barback.app"
  if ((NOTARIZE)); then
    "$ROOT/Scripts/verify_signature.sh" "$STAGE/Barback.app" --require-notarized
  fi
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Barback $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG"
  rm -rf "$STAGE"
  if [[ -n "${BARBACK_SIGN_IDENTITY:-}" && "$BARBACK_SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$BARBACK_SIGN_IDENTITY" --timestamp "$DMG"
  fi
  hdiutil verify -quiet "$DMG" || die "${DMG#"$ROOT"/} failed hdiutil verify"
  if ((NOTARIZE)); then
    "$ROOT/Scripts/notarize.sh" "$DMG"
  fi
  write_checksum "$DMG"
fi

if ((WANT_ZIP)); then
  "$ROOT/Scripts/render_cask.sh" --version "$VERSION" --zip "$ZIP" --output "$DIST/barback.rb"
fi

log "Release artifacts for Barback $VERSION"
for artifact in "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256" "$DIST/barback.rb"; do
  [[ -f "$artifact" ]] || continue
  printf '    %-28s %6s\n' "${artifact#"$ROOT"/}" "$(du -h "$artifact" | cut -f1)"
done
if ((WANT_ZIP)); then
  printf '    sha256 (zip): %s\n' "$(cut -d' ' -f1 "$ZIP.sha256")"
fi
