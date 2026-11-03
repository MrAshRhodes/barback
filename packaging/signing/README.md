# Release signing

## Status

Local and hosted release packaging require Developer ID signing, notarization, stapling and quarantine-preserving verification. The `release` GitHub environment is configured for **tags matching `v*` only**, with the five Apple secrets below. Releases also sign update feeds with a separate Sparkle key, configured in the same environment; see [Sparkle update signing](#sparkle-update-signing-one-time-owner-setup).

The hosted workflow follows Glint's approved approach on an ephemeral macOS runner. Signing secrets are scoped to the import step's environment; `Scripts/import_signing_identity.sh` creates a temporary keychain with a random password, imports the existing PKCS#12 identity and selects a valid Developer ID Application certificate for team `TB3Z5R7SY8`. Apple's `security` commands receive the required passwords as arguments, with shell tracing disabled. The decoded PKCS#12 file is removed immediately after import.

The notary API key is decoded into a runner-temporary file with `umask 077`, then checked before building. Packaging receives only the key path, key ID and issuer ID. Two `if: always()` steps remove the notary key and signing keychain and restore the keychain search list before publication, including after failure. Failed import, notarization, verification or cleanup blocks publication; there is no ad-hoc fallback. Never print secrets or enable shell tracing in these steps.

PR CI runs credential-free signing tests and ad-hoc development builds. It never references the `release` environment or signing secrets.

## Identity and existing backups

Reuse the existing team-wide identity and notary key. Do not create a replacement certificate merely for a new app.

| Property | Value |
| --- | --- |
| Identity | Developer ID Application: Ashley Rhodes (TB3Z5R7SY8) |
| Certificate SHA-1 | `4D0C57D986621BEE056A7F16FC4F3B3BAE39A13E` |
| Certificate expiry | 29 November 2027, 14:23:44 UTC |
| Team | `TB3Z5R7SY8` |
| Bundle identifier | `io.github.mrashrhodes.barback` |
| Notary key ID | `3PURPVR57Z` |
| Notary issuer ID | `c32fa693-3989-460f-8e63-0993e1c8c46e` |
| Existing local Keychain profile | `glint-notary` |

Existing backups in **my.1password.com / Personal** are reused unchanged:

- `Glint Developer ID - .p12 (macOS code signing)` (Document)
- `Glint Developer ID - .p12 password` (Password)
- `Glint Developer ID - notary API key (.p8)` (Document)

No Barback-specific private-key copy is needed locally. The login Keychain holds the signing identity and the existing profile authenticates notarization. Never modify or delete the Glint items as part of Barback maintenance.

The GitHub `release` environment contains:

- `BARBACK_SIGNING_P12_BASE64`
- `BARBACK_SIGNING_P12_PASSWORD`
- `BARBACK_NOTARY_KEY_P8_BASE64`
- `BARBACK_NOTARY_KEY_ID`
- `BARBACK_NOTARY_ISSUER_ID`

The private values were transferred directly from the Personal vault through pipes to `gh secret set --repo MrAshRhodes/barback --env release`; no local plaintext export was made. Secret listings confirm names, not values. GitHub does not expose stored plaintext for a read-back comparison.

## Sparkle update signing (one-time owner setup)

Direct-download copies of Barback update through Sparkle. Each shipped app embeds an Ed25519 public key and accepts only an appcast and ZIP signed by the matching private key. This key is separate from the Apple Developer ID identity, and Homebrew installs never use it.

Installed copies trust only the public key they shipped with. If the private key leaks, anyone who can serve the feed can sign an update. If it is lost, direct-download users must reinstall manually to receive a new key. Never commit or print it, and read Sparkle's key-rotation guidance before replacing it.

The key was created on 3 November 2026 and is stored in three places:

| Copy | Location |
| --- | --- |
| Public key (`SUPublicEDKey`) | `O32xAcnFJCixmDj+cQ95DM6R89ACkPsd8vDALNDg+qs=` |
| Working copy | Owner's login Keychain, Sparkle account `barback` |
| Backup | **my.1password.com / Personal**: `Barback Sparkle EdDSA private key` (Document) |
| CI | `release` environment secret `BARBACK_SPARKLE_PRIVATE_KEY` and variable `BARBACK_SPARKLE_PUBLIC_KEY` |

Before storing it, the exported key was checked to derive the public key above and to produce a Sparkle signature that verifies with it. The backup was read back and checked the same way. GitHub cannot return the secret, so restore from 1Password, never by recreating the key.

Run `make build` first so SwiftPM downloads Sparkle's tools. Do **not** run `generate_keys` without `-p`, `-x` or `-f` on a Mac that lacks the key: that silently creates a different key that existing installs reject.

- **Restore on another Mac.** Download the 1Password document into a private temporary folder, import it, then delete the folder:

  ```sh
  SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
  umask 077
  key_dir="$(mktemp -d)"
  op document get "Barback Sparkle EdDSA private key" --vault Personal --account my.1password.com \
    --out-file "$key_dir/sparkle-private-key"
  "$SPARKLE_BIN/generate_keys" --account barback -f "$key_dir/sparkle-private-key"
  rm -rf "$key_dir"
  "$SPARKLE_BIN/generate_keys" --account barback -p   # must print the public key above
  ```

- **Reset the CI secret** (for example, after deleting the environment). Pipe the backup without a trailing newline, then confirm both names with `gh secret list` and `gh variable list` for `--env release`:

  ```sh
  op document get "Barback Sparkle EdDSA private key" --vault Personal --account my.1password.com \
    | tr -d '\r\n' | gh secret set BARBACK_SPARKLE_PRIVATE_KEY --repo MrAshRhodes/barback --env release
  gh variable set BARBACK_SPARKLE_PUBLIC_KEY --repo MrAshRhodes/barback --env release \
    --body 'O32xAcnFJCixmDj+cQ95DM6R89ACkPsd8vDALNDg+qs='
  ```

The release workflow requires both values before testing or building. Developer ID builds refuse to embed a missing or malformed public key, so a release cannot ship with a disabled updater. After the ZIP is notarized and final, `Scripts/generate_appcast.sh` signs it and writes a one-entry `appcast.xml` with embedded release notes. It then checks the archive's public key, signed-feed settings, version, build number, download URL, size and both signatures before publication.

Apps read `https://github.com/MrAshRhodes/barback/releases/latest/download/appcast.xml`, so only the newest stable release is offered; prereleases are never "latest". Sparkle compares `CFBundleVersion`, which hosted releases set from the workflow run number so it always increases. Publish only workflow-built artifacts: a local candidate's build number and signatures do not belong in the public feed.

## Local release candidate

```sh
BARBACK_SIGN_IDENTITY=4D0C57D986621BEE056A7F16FC4F3B3BAE39A13E \
BARBACK_NOTARY_PROFILE=glint-notary \
BARBACK_SPARKLE_PUBLIC_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account barback -p)" \
Scripts/package_release.sh --version X.Y.Z --formats zip,dmg --require-universal --notarize
```

Only public identity/profile names and the public update key are passed through the environment. Local candidates do not generate an appcast, so the private update key never leaves the Keychain. The packaging script verifies the Developer ID chain, team and bundle identifier, hardened runtime and secure timestamps before uploading. It requires Apple's `Accepted` response, staples the app before archiving, and verifies a plain-unzip extraction with quarantine present. It signs, notarizes and staples a requested DMG separately. Final checksums are generated after verification.

```sh
Scripts/verify_signature.sh dist/Barback.app --require-notarized
Scripts/verify_signature.sh dist/Barback-X.Y.Z.dmg --require-notarized
make signing-test
```

The production policies are `designated-requirement.txt` for the app and `developer-id-requirement.txt` for a DMG. They allow certificate renewal within the same team without pinning a specific certificate hash. Do not change the bundle identifier or team for routine updates. Never sign with `--deep`; sign future nested executables inside-out.

If notarization fails or times out, the script retrieves submission diagnostics when an ID is available and exits nonzero. A missing ticket, wrong signing identity, failed signature verification or rejected Gatekeeper assessment also blocks packaging. Do not distribute files left by a failed run.

## Migration and verification evidence

Versions through 0.2.1 were ad-hoc signed. On the first Developer ID upgrade, users who enabled Accessibility should remove the old Barback entry in System Settings, add the replacement app in `/Applications`, enable it and reopen Barback. Core hiding and hotkeys remain permission-free. Stable signing supports subsequent grant continuity, but that behavior has not been tested across two installed production updates.

Local candidate `0.2.2-notary.1` was built on 30 October 2026 for arm64 and x86_64:

- App notarization accepted: `1e5f1f9b-2519-4304-8570-561728a2c020`.
- DMG notarization accepted: `965d4f11-abe4-44e4-9c5e-fadccbd05095`.
- App, extracted ZIP app and DMG pass signature and stapled-ticket validation.
- The extracted app passes Gatekeeper as `Notarized Developer ID` with `com.apple.quarantine` still present; the DMG passes the primary-signature open assessment.
- ZIP SHA-256: `f20e01b2a0b2864f30902e091789a1b0917ae429a0c3e83ded3043c27476676c`.

These are local artifacts, not a published release. Actual disconnected/offline first launch and macOS privacy-grant continuity are separate manual checks; a valid stapled ticket alone does not demonstrate those UI behaviors.

The final-version `0.2.2` artifacts (build 9) were also signed, notarized and verified on 30 October 2026:

- App notarization accepted: `ce8043df-acc4-4c52-8d55-e8a46c4af147`.
- DMG notarization accepted: `f02357f3-e006-4a18-b753-dd90283eb6b5`.
- App, quarantined ZIP extraction and DMG pass signature, stapled-ticket and Gatekeeper verification.
- ZIP SHA-256: `b38901997edf2dd6d3588332731cf96ffdd5645036f6acc01cf419720776e61c`.
- The generated Homebrew cask pins that exact ZIP and does not remove quarantine.

For a hosted release, commit the version and changelog, then push the matching `v*` tag after release approval. The workflow publishes both universal ZIP and DMG assets, `appcast.xml` and their checksums only after verification and credential cleanup. The separate tap job pins the published ZIP without removing quarantine. Never replace published release assets; Sparkle signatures and the cask checksum cover their exact bytes. Cut a new version instead.

## Updater rollout and outstanding checks

Versions before the first updater-enabled release have no updater. Direct-download users install that release manually once; Homebrew users run `brew update && brew upgrade --cask barback` as before.

Automated tests exercise the real Sparkle engine against a local signed feed, including rejection of unsigned, tampered and wrong-key feeds, but they never download or install an update. The production key is configured, but no installed copy has updated itself yet. After the first two updater-enabled releases are published, verify on a real Mac:

1. Install the older release from its DMG into `/Applications`, open it and grant Accessibility.
2. Choose **Check for Updates…**. Confirm Sparkle offers the newer release, then install it.
3. Confirm Barback relaunches with the new version, keeps its settings and update schedule, and keeps the Accessibility grant.
4. On a copy installed with Homebrew, confirm **Check for Updates…** shows the `brew upgrade` command and makes no network request.

Record the result here. Until then, treat Accessibility grant continuity across Sparkle updates as untested.
