# Copilot instructions for Barback

Barback is a fast, lightweight macOS 14+ menu bar item hider written in Swift. It is a SwiftPM package with no Xcode project and no third-party dependencies. Every public version ships as a universal, Developer ID signed, notarized and stapled app through GitHub Releases and the `MrAshRhodes/homebrew-tap` Homebrew cask. Human-facing detail lives in `CONTRIBUTING.md` and `packaging/signing/README.md`; keep them consistent with this file.

## Release non-negotiables

- Production artifacts come only from `.github/workflows/release.yml`, triggered by pushing a `vX.Y.Z` tag. Its job runs in the protected `release` environment (tags `v*` only), which holds the signing and notarization secrets. Never sign, notarize or publish a production build from a local machine, and never upload ad-hoc `make app`, `make zip` or `make dmg` output.
- Published assets are immutable: the cask pins the ZIP's SHA-256. Never replace release assets, delete or move a published tag, or rebuild a published version. Fix forward by cutting the next version.
- Keep the signing identity stable: bundle identifier `io.github.mrashrhodes.barback`, team `TB3Z5R7SY8`, and the requirements in `packaging/signing/designated-requirement.txt` and `packaging/signing/developer-id-requirement.txt`. Keep hardened runtime and secure timestamps, never use `codesign --deep`, and never strip quarantine or add an ad-hoc fallback.
- Secrets stay as environment variables of the release steps that need them. Never reference them from `.github/workflows/ci.yml` or pull request workflows, print them, enable shell tracing near them, or write them anywhere except runner-temporary files that `if: always()` steps remove before publishing. Never modify the shared Glint 1Password items or Apple credentials.
- Never commit signing material or release artifacts, and never `git add -f` them. `.gitignore` blocks certificates and keys (`*.p12`, `*.p8`, `*.pem`, `*.cer`, ...), keychains, provisioning profiles, base64 secret copies, `.env*`, `dist/`, `*.app/`, `*.dmg`, `*.pkg` and `Barback-*.zip`. `Tests/SigningTests/repository.test.cjs` fails if those protections are weakened.

## Build, test and lint

Always run SwiftPM through `Scripts/swiftw.sh`, which adds the flags a Command Line Tools-only Mac needs; the Makefile already does. `make help` lists every target.

- `make build` / `make release`: debug / optimized build of every target.
- `make test`: Swift Testing (`import Testing`) suites in `Tests/BarbackCoreTests` and `Tests/BarbackTests`. Run a subset with `Scripts/swiftw.sh test --filter <SuiteOrTestName>`.
- `make signing-test`: credential-free Node.js 20+ `node:test` suites in `Tests/SigningTests` covering signing, notarization, the temporary keychain, the release workflow and repository hygiene. Run one file with `node --test Tests/SigningTests/signing.test.cjs`.
- `make lint`: `bash -n` plus `shellcheck` (when installed) on `Scripts/*.sh`, and `plutil -lint` on the plists.
- `make changelog-check`: validates `CHANGELOG.md` and the notes for `VERSION`.
- `make app` / `make run`: ad-hoc signed `dist/Barback.app` for local development only.

Before opening a pull request run `make lint signing-test changelog-check test`. CI (`.github/workflows/ci.yml`) runs the same checks, then `make app` and a cask render.

## Releasing a version

1. On a branch, run `make prepare-release VERSION=X.Y.Z`. It writes `VERSION` and moves the `## [Unreleased]` entries of `CHANGELOG.md` into a dated section. Commit, open a pull request and merge it to `main` once CI is green.
2. After the maintainer approves the release, tag the merged `main` commit and push only that tag: `git tag -a vX.Y.Z -m "Barback X.Y.Z"` then `git push origin vX.Y.Z`. The tag must match `VERSION`. A tag such as `vX.Y.Z-beta.1` publishes a prerelease and skips the tap.
3. Watch the Release run with `gh run watch`. It tests without credentials, imports the Developer ID identity into a temporary keychain with `Scripts/import_signing_identity.sh`, checks the notary key with `Scripts/notarize.sh --check-credentials`, then runs `Scripts/package_release.sh --formats zip,dmg --require-universal --notarize`. It removes the notary key and keychain before publishing `Barback-X.Y.Z.zip`, `Barback-X.Y.Z.dmg` and both `.sha256` files, and, when the `TAP_GITHUB_TOKEN` secret is set, a second job updates `Casks/barback.rb` in the tap. Otherwise publish the cask with `Scripts/update_tap.sh --version X.Y.Z --from-release` (preview with `--dry-run` first).
4. Verify the published assets: `shasum -a 256 -c` on both checksum files, `Scripts/verify_signature.sh <extracted Barback.app or DMG> --require-notarized`, `lipo -archs` reports `x86_64 arm64`, and `spctl --assess` reports `Notarized Developer ID` while the quarantine attribute is still present. Confirm the cask pins the published ZIP checksum.
5. If the run fails before publishing, nothing was released: re-run it for a transient failure, otherwise fix the cause on `main` and release the next version.

GitHub operations for this repository and the tap use the `MrAshRhodes` account.

## Architecture

- `Package.swift`: `BarbackCore` library, `Barback` executable and the two Swift test targets.
- `Sources/BarbackCore`: pure, testable logic such as settings, section layout, rehide policy, menu bar item parsing, hotkeys, notch geometry and drop-down placement. Put new testable logic here.
- `Sources/Barback`: the AppKit and SwiftUI app shell, including `AppDelegate`, status items, global hotkey, hover monitor, Settings and the drop-down panel.
- `Resources/`: `Info.plist` template, `Barback.entitlements` and `AppIcon.icns`. `Scripts/build_app.sh` assembles the bundle; there is no `xcodebuild`, `ibtool` or `actool` step.
- `Scripts/`: build, package, sign, notarize, verify, changelog and Homebrew tap scripts. `packaging/homebrew/barback.rb.tmpl` is the cask template.
- `site/`: static GitHub Pages site deployed by `.github/workflows/pages.yml`.

## Conventions

- Stay fast: no polling loops or repeating timers. Prefer notifications, event monitors and one-shot timers, and keep hover handling cheap.
- Hiding, showing and hotkeys must stay permission-free. Accessibility is only for optional item identification and panel opening.
- Follow the macOS Human Interface Guidelines: SF Symbols as template images, system colors and fonts, VoiceOver labels on every control, and support for Reduce Motion and Increase Contrast. Gate macOS 26 APIs with `if #available(macOS 26, *)` and keep a macOS 14 fallback.
- Log through `os.Logger` with subsystem `io.github.mrashrhodes.barback`.
- Tests that touch settings use isolated `UserDefaults` suites, never the real domain.
- Add user-visible changes under `## [Unreleased]` in `CHANGELOG.md`.
- Shell scripts use `set -euo pipefail`, fail closed with a clear `error:` message, and are covered by `make lint`. Signing and release behavior changes need a matching credential-free test in `Tests/SigningTests`.
