# Release signing

## Status

Local Developer ID signing, notarization, stapling and quarantine-preserving verification work. The `release` GitHub environment is configured for **tags matching `v*` only**, with the five environment secrets below.

**Hosted CI credential import is blocked pending a secret-handling decision.** The current policy forbids signing secrets in environment variables, process arguments and temporary scripts. The conventional GitHub Actions import path uses step environment variables and password arguments to Apple's keychain commands. No exception has been approved. The release workflow therefore stops explicitly before building or publishing a new release; it does not fall back to ad-hoc signing. Do not remove that gate until an approved import path and unconditional credential cleanup are implemented.

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

## Local release candidate

```sh
BARBACK_SIGN_IDENTITY=4D0C57D986621BEE056A7F16FC4F3B3BAE39A13E \
BARBACK_NOTARY_PROFILE=glint-notary \
Scripts/package_release.sh --version X.Y.Z --formats zip,dmg --require-universal --notarize
```

Only public identity/profile names are passed through the environment. The packaging script verifies the Developer ID chain, team and bundle identifier, hardened runtime and secure timestamps before uploading. It requires Apple's `Accepted` response, staples the app before archiving, and verifies a plain-unzip extraction with quarantine present. It signs, notarizes and staples a requested DMG separately. Final checksums are generated after verification.

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

Before a future hosted release, complete the approved credential import, use a temporary keychain and protected runner key file, restore any modified keychain search list, and delete imported credentials with `if: always()` even after failure. Obtain separate approval before pushing a version tag, publishing a release or updating the Homebrew tap. Never replace published release assets.
