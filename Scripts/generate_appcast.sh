#!/usr/bin/env bash
# Sign the final ZIP and appcast. Run only after packaging/notarization; never modify either afterward.
set -euo pipefail
set +x

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 ]] || die "usage: Scripts/generate_appcast.sh X.Y.Z"
VERSION="${1#v}"
version_re='^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$'
[[ $VERSION =~ $version_re ]] || die "invalid version"
: "${BARBACK_SPARKLE_PRIVATE_KEY:?Missing Sparkle private key (exported by generate_keys)}"
: "${BARBACK_SPARKLE_PUBLIC_KEY:?Missing Sparkle public key}"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$TOOLS/generate_appcast" && -x "$TOOLS/sign_update" ]] || die "resolve the Sparkle package first"
ARCHIVE="$ROOT/dist/Barback-$VERSION.zip"
[[ -s "$ARCHIVE" ]] || die "missing packaged ZIP: $ARCHIVE"
STAGE="$(mktemp -d "$ROOT/dist/appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$ARCHIVE" "$STAGE/"
flags=()
if [[ "$VERSION" == *-* ]]; then flags+=(--allow-unreleased); fi
Scripts/changelog.sh notes "$VERSION" ${flags[@]+"${flags[@]}"} > "$STAGE/Barback-$VERSION.md"
PREFIX="https://github.com/MrAshRhodes/barback/releases/download/v$VERSION/"
printf '%s' "$BARBACK_SPARKLE_PRIVATE_KEY" | "$TOOLS/generate_appcast" \
  --ed-key-file - --maximum-deltas 0 --maximum-versions 1 --embed-release-notes \
  --download-url-prefix "$PREFIX" \
  --link "https://github.com/MrAshRhodes/barback/releases/tag/v$VERSION" \
  "$STAGE"

# Validate the generated entry against the exact final archive, not just the generator's exit status.
signature="$(python3 - "$STAGE/appcast.xml" "$ARCHIVE" "$VERSION" "$PREFIX" <<'PY'
import os
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile

feed, archive, version, prefix = sys.argv[1:]
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
with zipfile.ZipFile(archive) as package:
    info = plistlib.loads(package.read("Barback.app/Contents/Info.plist"))
assert info.get("SUPublicEDKey") == os.environ["BARBACK_SPARKLE_PUBLIC_KEY"], "archive public key mismatch"
assert info.get("SURequireSignedFeed") is True, "archive must require a signed feed"
assert info.get("SUVerifyUpdateBeforeExtraction") is True, "archive must verify before extraction"
assert info.get("CFBundleShortVersionString") == version, "archive version mismatch"
items = ET.parse(feed).findall("./channel/item")
assert len(items) == 1, "expected exactly one update"
item = items[0]
enclosure = item.find("enclosure")
assert enclosure is not None, "missing update enclosure"
assert enclosure.get("url") == prefix + os.path.basename(archive), "incorrect download URL"
assert enclosure.get("length") == str(os.path.getsize(archive)), "incorrect archive length"
assert item.findtext(ns + "version") == info["CFBundleVersion"], "incorrect build number"
assert item.findtext(ns + "shortVersionString") == version, "incorrect display version"
assert item.findtext(ns + "minimumSystemVersion") == info["LSMinimumSystemVersion"], "incorrect OS requirement"
assert item.find(ns + "releaseNotesLink") is None, "release notes must be embedded"
assert enclosure.get(ns + "edSignature"), "missing archive signature"
print(enclosure.get(ns + "edSignature"))
PY
)"

# Verify with the PUBLIC key embedded in the app, catching a mismatched release secret/variable pair.
BARBACK_ARCHIVE_SIGNATURE="$signature" node - "$ARCHIVE" <<'JS'
const { createPublicKey, verify } = require("node:crypto");
const { readFileSync } = require("node:fs");
const raw = Buffer.from(process.env.BARBACK_SPARKLE_PUBLIC_KEY, "base64");
if (raw.length !== 32) throw new Error("Invalid Sparkle public key");
const key = createPublicKey({
  key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]),
  format: "der", type: "spki",
});
if (!verify(null, readFileSync(process.argv[2]), key,
  Buffer.from(process.env.BARBACK_ARCHIVE_SIGNATURE, "base64"))) {
  throw new Error("Archive signature does not match the app's public key");
}
JS
printf '%s' "$BARBACK_SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" \
  --ed-key-file - --verify "$STAGE/appcast.xml"
mv "$STAGE/appcast.xml" "$ROOT/dist/appcast.xml"
(cd "$ROOT/dist" && shasum -a 256 appcast.xml > appcast.xml.sha256)
printf 'Verified signed appcast: dist/appcast.xml\n'
