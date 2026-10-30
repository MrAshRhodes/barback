## Install

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

Core hiding needs **no** Screen Recording or Accessibility permission. The optional drop-down panel requires Accessibility to open an item's menu. To hide an item, hold ⌘ and drag it to the left of Barback's separator; click the chevron or press ⌃⌥⌘B to show or hide it.

## Update an existing installation

Quit Barback first. **Homebrew:** `brew update && brew upgrade --cask barback`. **Manual:** repeat the download and verification steps above and replace Barback.app. Your settings and item positions are kept.

When upgrading from an ad-hoc build (including 0.2.1), grant Accessibility again if you use it: remove the old Barback entry in **System Settings → Privacy & Security → Accessibility**, add `/Applications/Barback.app` again, enable it, and reopen Barback. Later releases retain the same bundle identifier and signing team.

[Changelog](https://github.com/MrAshRhodes/barback/blob/v@VERSION@/CHANGELOG.md) · [README](https://github.com/MrAshRhodes/barback#readme)
