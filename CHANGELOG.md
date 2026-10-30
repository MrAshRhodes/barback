# Changelog

All notable changes to Barback are documented here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
See [GitHub Releases](https://github.com/MrAshRhodes/barback/releases) for downloads.

## [Unreleased]

## [0.2.1] - 2026-10-30

### Fixed

- Replace empty-group management with a complete panel editor: choose real menu bar items, name and style each panel, set its list/grid layout, and reorder panels and selections. Adding a panel enables normal left-click opening.
- Always open the configured dropdown on a primary click or hotkey in panel mode, even while hidden icons are already revealed. Option-click and the traditional strip mode keep their existing behavior.
- Show only explicitly selected, safely identified items, with names in both layouts. Remove the automatic wall of generic icons and the implicit Other group. Preserve existing groups and unavailable selections without guessing new identities.
- Make Accessibility requirements visible and disable item opening without permission, with an explicit Show in Menu Bar fallback. Report opening failures and prevent obsolete scans or uncertain presses from triggering repeated actions.
- Refresh item identification after permission changes and deduplicate items mirrored across displays.

## [0.2.0] - 2026-10-30

### Added

- Carlos’ Marañon toggle icon: a hand-drawn cashew apple with its nut, selectable last in the Settings › Appearance icon picker. It is outlined while items are hidden and filled while they are revealed, follows the icon weight setting, and is drawn as a template image so it adapts to light and dark menu bars.
- Optional drop-down panel: in Settings › Panel, set **Click Barback to** *Open a drop-down panel* to open a borderless panel under the Barback icon instead of revealing items in the menu bar. It is made of Liquid Glass on macOS 26 and a system material on macOS 14 and 15, and honors Reduce Transparency, Increase Contrast and Reduce Motion. The default is unchanged (reveal the items in the menu bar).
- The panel lists hidden items as a list or a grid, and the global hotkey opens it when it is the click action. Option-click still reveals everything, including always-hidden items.
- Item groups: sort hidden items into up to 12 named groups (right-click an item › **Move to Group**), shown as boxes in the panel followed by *Other*. Groups are edited in Settings › Panel.
- Click an item in the panel to open its menu through Accessibility (optional permission). Without it, clicking reveals the items in the menu bar and the panel hints at the permission.

## [0.1.0] - 2026-10-30

First public release.

### Added

- Menu bar item hiding with Barback's own status items: a chevron that is always visible, a **hidden** separator, and an optional **always-hidden** separator. ⌘-drag any menu bar item to the left of a separator to hide it.
- Instant show/hide: click the chevron to toggle the hidden section; Option-click (or **Show Always-Hidden** in the menu) also reveals always-hidden items. No animation polling, no screen capture.
- Auto-rehide after a configurable delay (default 10 seconds, 0 = never). Hidden items stay visible while the pointer is over the menu bar.
- Global hotkey to toggle hidden items, ⌃⌥⌘B by default, registered without Accessibility permission.
- Optional "show on hover" for the menu bar (off by default). Items revealed by hovering hide again 0.4 seconds after the pointer leaves the menu bar (or, if a menu is open then, once it closes).
- Settings window (⌘,) with General, Appearance, Items and About tabs: launch at login, auto-rehide delay, hotkey, hover; a read-only list of the current menu bar items and whether each is hidden (worked out per display, so items on other displays aren't mislabelled), scanned on demand off the main thread; tips for Macs with a notch. On macOS 26, items hosted by Control Center are listed as "Unidentified Item" unless you optionally allow Accessibility access to show app names.
- Right-click menu on the chevron: Show/Hide, Show Always-Hidden, Settings…, About Barback, Getting Started, Quit.
- Appearance settings with a live preview: one-click styles (Classic, Minimal, Cocktail, Eye, Arrows); nine toggle icons (chevron, chevron in circle, triangle, eye, ellipsis, lines, wine glass, mug, dot) in four weights, each changing shape with the state; an optional accent tint while hidden items are showing; separator styles per section (line, dashed, dot, double line, chevron or invisible). Only Barback's own items are restyled.
- Up to three extra dividers that can be ⌘-dragged anywhere to group menu bar items. They don't hide anything, and their positions are kept when you remove and re-add them.
- `barback://` URL scheme for Shortcuts, scripts and launchers: `toggle`, `show`, `hide`, `show-all`, `toggle-all` and `settings` (e.g. `open -g barback://toggle`). URLs can't change settings. The hotkey and URL commands post a VoiceOver announcement of the result.
- Optional "Hide items again when switching apps" (off by default): revealed items hide as soon as another app becomes active, unless the pointer is in the menu bar or a menu is open. Uses a workspace notification, no polling.
- A one-time getting-started popover under the chevron on first launch (also available from the menu); it respects Reduce Motion.
- Guard against misordered separators: Barback will not expand a separator that sits to the right of the chevron and explains how to fix the order.
- Follows the macOS Human Interface Guidelines: SF Symbols template status items, a Settings window with toolbar tabs and grouped SwiftUI forms, VoiceOver labels, system colors and controls in light and dark mode, and the Liquid Glass design on macOS 26 (including `.glass` / `.glassProminent` buttons in Settings, with bordered fallbacks on macOS 14–15). The app icon follows the macOS 26 icon grid.
- Event-driven design with near-zero idle CPU: only one-shot timers, no polling, screen capture, event taps, synthetic events, private APIs or network access. Core features need no privacy permissions (no Screen Recording; Accessibility is optional and only used for item names). Show/hide and the Items scan are marked with signposts for Instruments (Points of Interest).
- Universal (Apple silicon + Intel) app for macOS 14 Sonoma or later, distributed as a zip and a Homebrew cask (`brew install --cask mrashrhodes/tap/barback`).


[Unreleased]: https://github.com/MrAshRhodes/barback/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/MrAshRhodes/barback/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/MrAshRhodes/barback/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/MrAshRhodes/barback/releases/tag/v0.1.0
