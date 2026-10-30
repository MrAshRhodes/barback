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

Barback is signed ad-hoc and not notarized, so macOS may block the first launch of a manual download. If you trust this release and verified the download, clear the quarantine flag, then open the app:

```sh
xattr -dr com.apple.quarantine /Applications/Barback.app
```

Barback needs **no** Screen Recording or Accessibility permission. To hide an item, hold ⌘ and drag it to the left of Barback's separator; click the chevron or press ⌃⌥⌘B to show or hide it.

## Update an existing installation

Quit Barback first. **Homebrew:** `brew update && brew upgrade --cask barback`. **Manual:** repeat the download and verification steps above and replace Barback.app. Your settings and item positions are kept.

[Changelog](https://github.com/MrAshRhodes/barback/blob/v@VERSION@/CHANGELOG.md) · [README](https://github.com/MrAshRhodes/barback#readme)
