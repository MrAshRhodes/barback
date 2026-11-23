## Install

**macOS 27 and later — known issue:** one-click hide/reveal is not supported for now. An assessment-mode workaround we investigated also hid unrelated menu bar icons. Do not rely on Barback's hiding controls there; manually open **System Settings → Menu Bar → Allow in the Menu Bar** to choose which apps appear. Configured drop-down panels still work. Hiding on macOS 14–26 is unchanged. This is compatibility guidance, not a new hiding backend.

```sh
brew install --cask mrashrhodes/tap/barback
```

Or download `Barback-@VERSION@.zip` and its matching `Barback-@VERSION@.zip.sha256` below into the same folder, then verify the download before opening it:

```sh
cd ~/Downloads
shasum -a 256 -c "Barback-@VERSION@.zip.sha256"
```

Continue only if the command reports `Barback-@VERSION@.zip: OK`. If verification fails, stop and download the pair again from this release. Then extract the zip and move **Barback.app** to your Applications folder. A matching checksum confirms the download matches the published file; it is not notarization.

This release is Developer ID signed and notarized by Apple, with the ticket stapled to the app. Leave quarantine enabled; no Gatekeeper bypass is needed. If macOS rejects the download, stop and report the error rather than disabling its protections.

Alternatively, download `Barback-@VERSION@.dmg` and `Barback-@VERSION@.dmg.sha256`, verify with `shasum -a 256 -c "Barback-@VERSION@.dmg.sha256"`, then open the disk image and drag Barback to Applications. The DMG is also signed, notarized and stapled.

On macOS 14–26, hiding needs **no** Screen Recording or Accessibility permission. To hide an item on those versions, hold ⌘ and drag it to the left of Barback's separator; click the chevron or press ⌃⌥⌘B to show or hide it. The optional drop-down panel requires Accessibility to open an item's menu, including on macOS 27 and later. Opening System Settings needs no additional permission.

## Update an existing installation

**Homebrew:** quit Barback, then run `brew update && brew upgrade --cask barback`. Barback never self-updates a Homebrew-managed copy.

**Direct download:** if your installed copy has **Check for Updates…**, use it to download a verified update and confirm installation. Otherwise, quit Barback and repeat the download and verification steps above to replace Barback.app once. Your settings and item positions are kept.

Automatic checks are off by default. In **Settings → General → Updates**, choose Never, Daily, Weekly or Monthly (30 days). Enabling a schedule may check immediately when overdue. Updates always need your confirmation; no telemetry or system profile is sent. Checks contact GitHub with normal request metadata such as your IP address and app/Sparkle versions.

When upgrading from an ad-hoc build (including 0.2.1), grant Accessibility again if you use it: remove the old Barback entry in **System Settings → Privacy & Security → Accessibility**, add `/Applications/Barback.app` again, enable it, and reopen Barback. Later releases retain the same bundle identifier and signing team.

[Changelog](https://github.com/MrAshRhodes/barback/blob/v@VERSION@/CHANGELOG.md) · [README](https://github.com/MrAshRhodes/barback#readme)
