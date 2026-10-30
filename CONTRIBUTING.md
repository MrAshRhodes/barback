# Contributing to Barback

Thanks for helping to make Barback better. This guide covers building, testing, how the code is organized, and how releases are made.

## Requirements

- macOS 14 (Sonoma) or later, Apple silicon or Intel.
- A Swift 5.9+ toolchain: either full Xcode or only the Command Line Tools (`xcode-select --install`). See [Command Line Tools only](#command-line-tools-only).
- There is no Xcode project and the app has no third-party dependencies. Signing-script tests use Node.js 20+; notarization additionally uses `jq` and Apple's `notarytool` and `stapler`.

## Build, run, test

| Target | What it does |
| --- | --- |
| `make build` / `make release` | Debug / optimized build of every target. |
| `make test` | Runs the core and native panel interface suites (`Tests/BarbackCoreTests`, `Tests/BarbackTests`). |
| `make signing-test` | Runs signing/notarization failure-gate tests without credentials or network access. |
| `make app` | Assembles `dist/Barback.app` for this Mac and signs it ad-hoc (`CONFIG=debug` for a debug build). |
| `make universal` | Same, with arm64 and x86_64 slices merged by `lipo`. |
| `make run` | `make app`, then opens the app. It is a menu bar app (no Dock icon): look for the chevron in the menu bar. |
| `make install` | Builds and copies `Barback.app` to `INSTALL_DIR` (default `/Applications`; quit a running Barback first). |
| `make zip` | Universal release build packaged as `dist/Barback-<version>.zip` + `.sha256`, plus `dist/barback.rb`. |
| `make dmg` | Optional disk image `dist/Barback-<version>.dmg` + `.sha256`. |
| `make tap` | Renders the Homebrew cask to `dist/barback.rb` from the local zip. |
| `make tap-dry-run` / `make publish-tap` | Render the cask for the **published** release zip and diff it against / push it to the tap. |
| `make changelog-check` | Validates `CHANGELOG.md`. |
| `make prepare-release VERSION=X.Y.Z` | Writes `VERSION` and moves the changelog's Unreleased entries into a dated `X.Y.Z` section. |
| `make icon` | Redraws `Resources/AppIcon.icns` and `docs/assets/icon-1024.png`. |
| `make lint` | `bash -n` (and `shellcheck`, when installed) on the scripts, `plutil -lint` on the plists. |
| `make clean` | Removes `.build` and `dist`. |

Every SwiftPM call goes through `Scripts/swiftw.sh`. With Xcode installed it is plain `swift`; on a Command Line Tools-only Mac it adds the flags described next.

## Command Line Tools only

- SwiftPM's default build engine needs Xcode, so builds use `--build-system native`. `Scripts/swiftw.sh` adds it for you.
- Swift Testing ships inside the Command Line Tools but is not on the default search paths; `make test` passes the extra `-F`/`-rpath` flags.
- There is no `xcodebuild`, `ibtool` or `actool`. That is why the UI is built in code, the app bundle is assembled by `Scripts/build_app.sh`, and the app icon is drawn by `Scripts/make_icon.swift` rather than compiled from an asset catalog or Icon Composer file.

`Scripts/swiftw.sh` reads `SWIFTW_MODE` (`auto`, `xcode` or `clt`), `SWIFTW_BUILD_SYSTEM` (always pass `--build-system <value>`) and `SWIFTW_VERBOSE=1` (print the final command).

## Project layout

```
Package.swift              BarbackCore (library), Barback (executable), both test targets
Sources/BarbackCore        Pure, testable logic: settings, section layout, rehide policy,
                           menu bar item parsing, hotkeys, notch geometry, item groups,
                           drop-down panel placement
Sources/Barback            App shell: AppDelegate, status items, hotkey, hover monitor, Settings UI,
                           drop-down panel (DropDownPanelWindow/-Controller/-View)
Tests/BarbackCoreTests     Unit tests for BarbackCore
Tests/BarbackTests         Native panel controls and settings persistence, using isolated defaults
Tests/SigningTests        Credential-free signing, notarization, temporary-keychain and
                           repository hygiene (.gitignore) tests
Resources/                 Info.plist template, Barback.entitlements, AppIcon.icns
Scripts/                   build_app.sh, package_release.sh, render_cask.sh, update_tap.sh,
                           import_signing_identity.sh, notarize.sh, verify_signature.sh,
                           changelog.sh, swiftw.sh, make_icon.swift
packaging/homebrew/        barback.rb.tmpl (the Homebrew cask template)
packaging/signing/         Developer ID requirements and release credential references
.github/workflows/         ci.yml (build + test), release.yml (tag -> GitHub release + tap)
.github/                   copilot-instructions.md (agent guidance and release runbook), templates
```

## Guidelines

- **Stay fast.** No polling loops or repeating timers; the only timer is the one-shot auto-rehide. Prefer notifications and event monitors, and keep hover handling cheap.
- **Keep core hiding permission-free.** Hiding, showing and hotkeys must not require Screen Recording, Accessibility or Input Monitoring. Optional item identification and panel opening use explicit Accessibility permission.
- **Follow the HIG.** SF Symbols as template images for status items, system colors and fonts, grouped `Form`s in Settings, VoiceOver labels for every control, and respect Reduce Motion / Increase Contrast. Gate Liquid Glass APIs with `if #available(macOS 26, *)` and keep a macOS 14 fallback.
- Put logic that can be tested in `BarbackCore` and cover it with tests.
- Log through `os.Logger` with subsystem `io.github.mrashrhodes.barback`.
- Add user-visible changes to `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

## Releasing

See [Release signing](packaging/signing/README.md) for credential references, verification evidence and hosted-CI setup. The tag-only `release` environment supplies credentials to the hosted workflow using the same temporary-keychain approach as Glint; missing or invalid credentials stop publication.

Local `make app`, `make zip` and `make dmg` remain ad-hoc development builds by default; do not distribute them as production releases. Production packaging requires the existing Developer ID Application identity and a notarytool Keychain profile:

```sh
BARBACK_SIGN_IDENTITY="<Developer ID Application identity>" \
BARBACK_NOTARY_PROFILE="<existing Keychain profile>" \
Scripts/package_release.sh --version X.Y.Z --formats zip,dmg --require-universal --notarize
```

These local variables contain an identity and profile name, not private keys or passwords. Keep local credentials in Keychain and never commit or log them. Alternatively, notarization accepts `BARBACK_NOTARY_KEY_PATH`, `BARBACK_NOTARY_KEY_ID` and `BARBACK_NOTARY_ISSUER_ID`; the path points to a protected `.p8` file, not its contents.

The app must satisfy `packaging/signing/designated-requirement.txt`: bundle identifier `io.github.mrashrhodes.barback`, Apple Developer ID trust chain and team `TB3Z5R7SY8`. Keep that identity stable across releases. The current bundle has one executable; any future nested executable must be signed inside-out before the app. Signing must retain hardened runtime and secure timestamps in every architecture.

Packaging submits the app, requires Apple's `Accepted` result, staples it, then creates the final ZIP. It checks the signature, ticket and Gatekeeper assessment after plain ZIP extraction. A requested DMG is separately signed, notarized and stapled. Checksums are written only after verification; do not re-sign, modify or rebuild an artifact after generating its checksum. `Scripts/verify_signature.sh dist/Barback.app --require-notarized` performs the production checks independently.

The first upgrade from an ad-hoc build requires a new Accessibility grant. A stable production designated requirement supports continuity on later updates, but does not guarantee that macOS never asks again. Do not reset the user's privacy database or silently remove quarantine.

1. `make prepare-release VERSION=X.Y.Z`, review the diff, commit and push to `main`.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. The **Release** workflow tests without credentials, imports the existing Developer ID identity into a temporary keychain, and builds, signs and notarizes the universal app and DMG. It removes credentials before publishing `Barback-X.Y.Z.zip`, `Barback-X.Y.Z.dmg` and both `.sha256` files with the changelog section as notes. If the `TAP_GITHUB_TOKEN` secret is set, it then updates `Casks/barback.rb` in [MrAshRhodes/homebrew-tap](https://github.com/MrAshRhodes/homebrew-tap).
4. Without that secret, publish the cask yourself once the release exists: `Scripts/update_tap.sh --version X.Y.Z --from-release` (add `--dry-run` first to preview).

Published release assets are never replaced: the cask pins the zip's SHA-256, so cut a new version instead.

[`.github/copilot-instructions.md`](.github/copilot-instructions.md) carries the same release runbook for coding agents; keep the two in sync. `.gitignore` keeps signing material (certificates, keys, keychains, provisioning profiles, base64 secret copies, `.env*`) and release artifacts out of git, and `Tests/SigningTests/repository.test.cjs` fails `make signing-test` if those protections are weakened.
