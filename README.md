<p align="center"><img src="docs/assets/icon-1024.png" width="128" alt="Barback app icon: a glass chevron under a menu bar strip"></p>

# Barback

**A fast, lightweight, open-source menu bar item hider for macOS.** Tuck the menu bar icons you rarely use behind a chevron, and bring them back with one click or a hotkey. Barback is a minimal alternative to Bartender: it does one job, instantly, without asking for Screen Recording permission (and Accessibility is only ever optional).

Barback is an independent project, released under the MIT license. It is not affiliated with or endorsed by the makers of Bartender.

**[Website](https://mrashrhodes.github.io/barback/)** · **[Releases](https://github.com/MrAshRhodes/barback/releases/latest)** · **[Changelog](CHANGELOG.md)** · **[Contributing](CONTRIBUTING.md)**

<p align="center">
  <img src="docs/assets/screenshot-general.png" width="390" alt="Barback Settings, General tab: launch at login, auto-rehide delay, show on hover, always-hidden section and keyboard shortcut">
  <img src="docs/assets/screenshot-items.png" width="390" alt="Barback Settings, Items tab: a list of menu bar items with their section (Visible, Hidden) and position">
</p>
<p align="center">
  <img src="docs/assets/screenshot-menu.png" width="260" alt="Barback's right-click menu: About Barback, Show Hidden Items (⌃⌥⌘B), Show Always-Hidden Items, Settings… (⌘,), Quit Barback">
</p>

## Why Barback

- **Fast.** Showing and hiding is a single layout change of Barback's own status items: no screen capturing, no animation polling, no background loops. It's instant, and idle CPU stays at ~0%.
- **No special permissions.** Hiding, showing, the hotkey and hover never need Screen Recording or Accessibility access. The global hotkey uses the Carbon hotkey API, and the item list reads window metadata only. Accessibility is optional and used for three things: showing app names in the Settings › Items list on macOS 26, opening a hidden item from the drop-down panel if you choose it, and the opt-in notch overflow bar (see below). Screen Recording is never used.
- **No telemetry.** No analytics or system profiling. Update checks are off by default; Barback contacts GitHub only when you check manually or choose a schedule.
- **Small and auditable.** One SwiftPM package with [Sparkle](https://sparkle-project.org/) for verified updates, MIT-licensed.
- **Feels native.** Built to the macOS Human Interface Guidelines (see [Design](#design)).

## Install

```sh
brew install --cask mrashrhodes/tap/barback
```

Requires macOS 14 Sonoma or later (Apple silicon or Intel).

Or download `Barback-<version>.zip` and `Barback-<version>.zip.sha256` from [Releases](https://github.com/MrAshRhodes/barback/releases) into the same folder and verify the download first:

```sh
cd ~/Downloads
shasum -a 256 -c "Barback-<version>.zip.sha256"   # must print "Barback-<version>.zip: OK"
```

Then extract the zip and move `Barback.app` to `/Applications`. The new release pipeline requires Developer ID signing and Apple notarization, with a stapled ticket for offline verification. Versions through **0.2.1** were ad-hoc signed; they do not gain notarization retroactively. Check the release notes for the version you download. Do not remove quarantine or disable Gatekeeper to work around a rejected download.

Prefer a disk image? Download the `.dmg` and `.dmg.sha256` pair instead, verify it with `shasum -a 256 -c "Barback-<version>.dmg.sha256"`, then open the image and drag `Barback.app` to Applications. The DMG is separately signed, notarized and stapled.

**First upgrade from an ad-hoc build:** quit Barback and replace the app. If you use Accessibility for item identification or the drop-down panel, remove the old Barback entry in **System Settings → Privacy & Security → Accessibility**, add `/Applications/Barback.app` again and enable it, then reopen Barback. The signing identity changes once during this migration; future releases keep the same bundle identifier and Developer ID team.

### Updates

**Homebrew installs:** run `brew update && brew upgrade --cask barback`. Barback detects the Homebrew-managed copy and never updates it itself; **Check for Updates…** shows the command instead.

**Direct downloads:** choose **Check for Updates…** from the menu, **Check Now** in Settings › General › Updates, or the update button in About. Automatic checks start at **Never**. You can opt into **Daily**, **Weekly**, or **Monthly** (every 30 days); the schedule is saved on this Mac. Choosing a schedule can check immediately if you have never checked or the last check is overdue. Returning to Never stops future scheduled checks, not a check already in progress.

Sparkle verifies the signed release feed and archive before installation and asks before downloading or installing an update. Checks use the latest stable GitHub release, not prereleases. They send normal HTTP metadata, including your IP address and a User-Agent identifying the app and Sparkle versions; no analytics, system profile or settings are uploaded. Sparkle includes installer helpers inside the app, used when updating, not a separate always-running service.

Versions released before this updater must be replaced manually once using the download instructions above. Source builds without an update signing key cannot self-update and link to Releases instead. You can always quit Barback and replace it manually; your settings and menu bar positions are kept.

## Usage

Barback adds a **chevron** to your menu bar and a thin **separator** to its left.

1. **Choose what to hide.** Hold **⌘ Command** and drag any menu bar item to the **left of the separator**. macOS remembers the positions.
2. **Show or hide.** Click the chevron, or press **⌃⌥⌘B** from anywhere. Items left of the separator slide out of view or back in.
3. **Always-hidden items.** Enable the second (always-hidden) separator in Settings and ⌘-drag items to its left. **Option-click** the chevron to reveal them too.
4. **Menu.** Right-click the chevron for Show/Hide, Show Always-Hidden, Settings… (⌘,), About, Check for Updates…, Getting Started and Quit.
5. **Make it yours.** In Settings › Appearance, pick a style or choose the icon (chevron, eye, wine glass, mug, Carlos’ Marañon and more), its weight, separator styles (line, dashed, dot, double line, chevron or invisible) and up to three extra dividers for grouping items.
6. **Optional drop-down panels.** In Settings › Panel, click **Add Panel**, give it a name, and choose its items. This sets **Click Barback to** *Open my panels*. Clicking the chevron (or pressing the hotkey) then opens your panels under the icon. See below.

The first time Barback starts, a short tip under the chevron explains the basics; open it again with **Getting Started** in the menu.

Hidden items re-hide automatically after 10 seconds (configurable, or never), but not while the pointer is over the menu bar or a menu is open. Optionally, Barback can also reveal hidden items when the pointer rests on the right-hand (status) side of the menu bar; items revealed this way hide again 0.4 seconds after the pointer leaves the menu bar. You can also have them hide as soon as you switch to another app.

**Settings**

- **General**: launch at login, auto-rehide delay, show on hover, hide when switching apps, always-hidden section, global hotkey, Export…/Import… of your settings (see below), and update checks.
- **Appearance**: a live preview plus styles (Classic, Minimal, Cocktail, Eye, Arrows), the toggle icon and its weight, an optional accent tint while hidden items are showing, separator styles for each section, and extra dividers. These change only Barback's own items. An invisible separator still leaves a narrow gap you can ⌘-drag.
- **Items**: a read-only list of every menu bar item, the process that owns its window, its section and whether it is currently on screen. It is scanned only when you open the tab or click Refresh (⌘R), off the main thread. On a Mac with a notch, items that would sit behind the notch are flagged so you can hide something else to make room, and once the strip is revealed and the list refreshed, a warning counts the observed items that do not fit beside the notch on each notched display (it appears here, in Barback's tooltip and right-click menu, and is announced to VoiceOver). The **Menu Bar Tools** buttons open the space planner, missing-item doctor and usage review (see below). On macOS 26 Tahoe, Control Center hosts most items' windows, so their source app can't be read from window metadata and they're listed as *Unidentified Item*; if you choose to allow Accessibility access, Barback matches them to app names. Identifiable items also get a shortcut recorder and a **Copy Link** button (see *Item shortcuts and links* below); an **Item Shortcuts** list shows every saved shortcut, including ones for items that aren't in the menu bar right now.
- **Panel**: what clicking Barback does (show the items in the menu bar, the default, or open your panels), and a complete editor for up to 12 panels: select their items, rename, choose an icon and list/grid layout, and reorder panels or their items.
- **Profiles**: optional named profiles that switch Barback's section visibility and which configured items appear in your panels, chosen by hand or by app and display rules (see below).
- **About**: version, license and links.

> **Tip:** if the separator ends up to the right of the chevron, Barback won't expand it (that would hide the chevron too) and shows a hint. ⌘-drag the separator back to the left of the chevron.

### Drop-down panel (optional)

With **Click Barback to** set to *Open my panels* (Settings › Panel; the default is still to show the items in the menu bar), a normal left-click on Barback opens your panels directly beneath it, like the ones in Control Center. The same click works even when menu bar items are already revealed. The global hotkey follows the click action; Option-click still reveals everything in the menu bar, including always-hidden items.

- **Configure first.** Click **Add Panel** in Settings › Panel, enter a name, select a symbol and layout, then use **Add Items** to choose what it contains. Use the arrows to order panels and their items. Both list and grid layouts show item names. The gear and panel edit buttons take you back to Settings.
- **Only your selections.** There is no automatic *Other* box. Identifiable items from any section can be selected; always-hidden items are available when that section is enabled. Each item belongs to one panel. Removing a panel or selection does not move or hide its original menu bar icon. Existing saved groups are kept as panels.
- **Honest identification.** Unidentified or ambiguous items are not offered as interchangeable generic icons. On macOS 26, allow Accessibility to identify items hosted by Control Center, then refresh. Known system Accessibility identifiers produce stable names and keys (such as `com.apple.controlcenter/Wi-Fi`), independent of state and system language. System items with missing or unrecognized identifiers stay excluded; changing descriptions are not identities. Window and Accessibility frames must match unambiguously, including hidden items. Saved selections that are not running or cannot be identified remain saved and are marked unavailable, rather than being reassigned to another icon.
- **Quick Search.** With the panel open, just type to filter your panel items by name or app name, across all panels. Matching ignores case and accents and finds word starts (`fi` finds *Wi-Fi*). Use ↑/↓ to choose a result, Return to open it, Delete to edit the query, and Esc to clear the search (press Esc again to close). Only items you have added to a panel are searched; nothing is captured from the screen.
- **Open an item.** Accessibility permission is required to press an item's menu. Until it is allowed, item buttons are disabled and the panel provides an explicit **Show in Menu Bar** fallback. With permission, Barback reveals the selected item's section only when needed and opens its menu. Failures are reported instead of silently doing nothing; uncertain presses are not automatically repeated.
- **Look and behavior.** The panel is a borderless window whose right edge lines up with the Barback icon, a few points below it, kept inside the screen. On macOS 26 Tahoe it is made of Liquid Glass; on macOS 14 and 15 it uses a system material instead. It closes when you click elsewhere, press Esc, click the icon again, switch Space or app, or the screen layout changes. Reduce Transparency gives it a solid background, Increase Contrast adds an outline and Reduce Motion drops the slide. The items are reachable with the keyboard and VoiceOver.

### Context profiles (optional)

Settings › Profiles lets you save up to 24 named profiles. A profile sets whether Barback's hidden sections are hidden, shown, or all shown, and can leave chosen items out of your panels. It never moves, hides or reorders individual icons in the physical menu bar: arrange those yourself with ⌘-drag. Your panel configuration is kept intact, and excluded items still open with their shortcuts and links.

- **Manual.** Pick a profile from **Active profile**. It stays active until the next display change or switch to another app, then the rules decide again.
- **Automatic.** Turn on *Switch automatically* and add a frontmost-app bundle identifier (such as `com.apple.Keynote`), a display condition (built-in only, external connected, external only) and/or an exact display count. All conditions of a profile must match. Rules that name an app win over display-only rules; among equals, the profile higher in the list wins. With no match, Barback returns to the **Base section visibility**.
- **Event-driven and private.** Rules are evaluated only when the frontmost app or the display setup changes. There is no polling, and profiles need no extra permissions. Without profiles, Barback behaves exactly as before. Auto-rehide still applies after a profile shows sections.

### Menu bar tools (optional)

Settings › Items › **Menu Bar Tools** opens three helpers. Measurements come from on-demand snapshots: no polling, no background scans, no new permissions, and nothing is moved, hidden or removed automatically. They describe what Barback could measure, not the whole menu bar, and a missing or unidentified item is never assumed to be gone. Usage recording stays off until you consent.

- **Plan menu bar space.** An on-demand, read-only snapshot of each display's status items, measured in logical points. A notched display is split into the regions left and right of the camera housing, which are never combined. The largest items are ranked per display, and checking an item's exclusion box shows a hypothetical before/after (dashed outlines, not moved icons); **Reset preview** clears it. Barback cannot measure the application menus, so usable capacity stays *unknown*, and a smaller total is not promised free space. A failed refresh, an empty scan and a snapshot made stale by a display or frontmost-app change are labeled instead of passing old numbers off as current.
- **Find a missing item.** Pick a saved, known or previously seen item to see timestamped evidence: whether the current scan found it, the latest earlier observation (up to 256 items for 30 days, kept in memory and forgotten when you quit), its measured position relative to display edges and the notch, and its app's running state. A failed or incomplete scan is reported as that, never as proof the item is gone. You can rescan, reveal Barback's own hidden section, or open the identified app, each only when you ask. It never repairs, restarts, rearranges or resets anything.
- **Review usage.** Off until you review and agree to it. While recording, Barback keeps local daily totals of *confirmed, successful* item openings made through Barback (panels and Quick Search, the notch overflow bar, item shortcuts and `barback://open` links) for today and the previous 29 UTC dates, plus each item's latest on-demand width and display/foreground context. There is no click timeline, no telemetry and no export; settings backups leave it out. Direct clicks in the menu bar, failed or uncertain attempts and app activity are not counted, and a count never measures importance (a VPN or battery indicator can matter with zero openings). Items that cannot be identified uniquely are left out rather than merged. **Stop Recording** keeps what was collected; **Clear Review Data…** stops recording and deletes the counts, measurements and recorded intervals.

### Notch overflow bar (optional)

On a Mac with a notched display, Settings › Items › Camera Housing has **Enable notch overflow bar**. It is off by default and requires Accessibility permission to open items. Denying permission leaves it off with an explanation; Screen Recording is never requested. Restoring an enabled setting does not authorize a new permission prompt.

When enabled, revealing the hidden strip can also open a bar below the menu bar, to the right of the notch. The right-click menu has **Open Notch Bar** and **Close Notch Bar**. It shows safely identified items for that display using their application icons, not captured menu bar images. Selecting an item reveals its section if necessary and presses its own menu through Accessibility. Unidentified or unavailable items stay unavailable: macOS may not expose an item obscured by the notch, in which case open the app directly or try your configured drop-down panel.

Use horizontal scrolling, **Previous**/**Next**, Left/Right Arrow, or Page Up/Page Down to browse; Escape closes the bar. Controls have VoiceOver labels, and paging respects Reduce Motion. The bar closes on outside clicks, Space or app switches, and display-layout changes. Automatic rehide waits while the bar is open or an item is opening.

Notch-fit warnings count only observed, drawn items on each notched display. Reveal the strip and refresh Items to update the warning in Settings, the tooltip and the right-click menu; new warnings are also announced to VoiceOver. A stale or missing snapshot reports that fit is unknown rather than claiming everything fits. Warning-only mode does not start scans.

### Back up or move your settings

**Settings › General › Backup** has **Export…** and **Import…**. Export saves a pretty-printed, sorted JSON file you can read, diff or keep in a dotfiles repo; Import loads one and the change takes effect immediately. Nothing is uploaded: the file is only written where you choose.

```json
{
  "app" : "Barback",
  "appVersion" : "0.3.0",
  "formatVersion" : 1,
  "settings" : { "autoRehideSeconds" : 10, "showOnHover" : false, "groups" : [ … ], … }
}
```

- The file holds hiding options, the hotkey (`null` when turned off), per-item shortcuts, appearance, click action, panel layout, your panels with their items, profiles (`activeProfileID` is `null` for the base configuration), and the notch overflow preference. It leaves out usage-review data and consent, menu bar icon positions, the first-launch tip, Launch at Login (a system setting), and Sparkle's update schedule and last-check date.
- Settings missing from a file keep their current values (objects like `appearance` are merged key by key; `groups` is replaced as a whole), and keys Barback doesn't know are ignored.
- Out-of-range values are fixed the same way as saved settings (for example the rehide delay is capped at an hour and invalid group names or symbols are repaired). Wrong types, unknown choices, malformed JSON or a file from a newer, unsupported `formatVersion` are rejected with an explanation, and your settings are left exactly as they were.

### Automation

Barback handles `barback://` URLs, so Shortcuts (*Open URLs*), scripts, Raycast, Alfred or a Stream Deck can drive it. Use `open -g` so the current app keeps focus:

```sh
open -g barback://toggle      # show or hide hidden items
open -g barback://show        # show hidden items
open -g barback://hide        # hide them again
open -g barback://show-all    # also show always-hidden items
open -g barback://toggle-all  # like Option-clicking the chevron
open barback://settings       # open Settings
```

URLs can only show, hide, open Settings or open an item's menu; they can't change settings. With VoiceOver on, the hotkey and URL commands announce the result.

#### Item shortcuts and links

`barback://open` opens one menu bar item's own menu, as if you had clicked it, revealing it first if it's hidden:

```sh
open -g "barback://open?item=com.apple.controlcenter/Wi-Fi"   # by stable item key
open -g "barback://open?name=Wi-Fi"                           # by app or item name
```

- **Copy Link** in Settings › Items copies an item's `?item=` link. The key is the owning app's bundle identifier, plus `/` and the item's own name when the app has several items. Percent-encode values (`%20` for a space; `+` is a literal plus).
- `?name=` matches the item's title, its app's name, its own name or "App — item", ignoring case, accents and width. If no item or more than one item matches, Barback opens nothing and logs why (Console, subsystem `io.github.mrashrhodes.barback`, category `items`) rather than guessing; use the `?item=` link instead.
- In Settings › Items you can also record a global shortcut for an item. A shortcut already used by the main hotkey or another item is refused with a message. Pressing a shortcut whose item isn't in the menu bar does nothing (and is logged).
- Opening an item uses Accessibility (the same press the drop-down panel uses, no synthetic clicks), so it needs Accessibility access.

## How it works

Barback uses the same well-known technique as Hidden Bar, Dozer and Ice: it owns ordinary `NSStatusItem`s. To hide, it sets the separator's length to a very large value, which pushes every item to its left off the edge of the screen; to show, it collapses the separator back to its normal width. Positions persist through `autosaveName`, so macOS keeps your arrangement across launches. Nothing is captured, moved by synthetic events or polled.

## Design

Barback follows the macOS Human Interface Guidelines:

- **Status items** use SF Symbols as template images, so they adapt to light and dark menu bars, accent tinting and Increase Contrast.
- **Settings** (**⌘,**) is a single window with standard toolbar tabs (General, Appearance, Items, Panel, Profiles, About), each a SwiftUI grouped form (`.formStyle(.grouped)`), like System Settings-era apps.
- **Accessibility**: status items and controls carry VoiceOver labels; only system colors, fonts and controls are used, so light/dark appearance, Increase Contrast and Reduce Transparency are honored automatically (separators become fully opaque with Increase Contrast). Showing and hiding is instant, with no motion to reduce, and the getting-started popover doesn't animate when Reduce Motion is on. Every toggle icon changes shape with its state, so the optional accent tint is never the only cue. The optional drop-down panel is a labeled dialog that Esc closes, with every item and button reachable by keyboard and VoiceOver.
- **Liquid Glass**: on macOS 26 Tahoe, Barback's menus, toolbar and controls pick up the system's Liquid Glass design because they are standard AppKit/SwiftUI components built against the current SDK, and Settings' buttons explicitly use the `.glass` / `.glassProminent` button styles (behind `#available(macOS 26, *)`, falling back to `.bordered` / `.borderedProminent` on macOS 14 and 15). Menu items get leading SF Symbols on macOS 26 only, as that release's HIG recommends. The drop-down panel is an `NSGlassEffectView` with rounded corners holding SwiftUI `glassEffect` tiles in a `GlassEffectContainer` (also behind `#available(macOS 26, *)`, falling back to an `NSVisualEffectView` popover material with `.thinMaterial` tiles on macOS 14 and 15).
- **App icon** follows the macOS 26 icon grid (824 × 824 continuous-corner body on a 1024 × 1024 canvas) with soft, layered lighting and a single motif, rendered at every size from 16 to 1024 px.

## Barback vs Bartender 6

Barback was inspired by studying how Bartender behaves. It is deliberately much smaller in scope. A neutral summary, as of Bartender 6:

| | Barback | Bartender 6 |
| --- | --- | --- |
| Price / license | Free, open source (MIT) | Paid, proprietary (free trial) |
| Hide/show menu bar items | ✅ chevron, hotkey, optional hover | ✅ plus many more triggers |
| Always-hidden section | ✅ | ✅ |
| Auto-rehide | ✅ | ✅ |
| Rearrange items without ⌘-drag | ❌ (use ⌘-drag) | ✅ |
| Custom icon, separator styles and dividers | ✅ (Barback's own items) | ✅ |
| Automation | ✅ `barback://` URL scheme | ✅ AppleScript, URL scheme, Shortcuts |
| Item groups | ✅ named groups in an optional drop-down panel | ✅ |
| Quick search | ✅ type to filter your panel items | ✅ |
| Profiles | ✅ section visibility and panel membership, chosen by hand or by app and display rules (never rearranges icons) | ✅ presets and triggers |
| Triggers, menu bar styling | ❌ | ✅ |
| Screen Recording permission | Not needed | Requested for its item images and layout features |
| Accessibility permission | Optional (app names in the Items list, opening items from the drop-down panel or the notch overflow bar) | Requested to move and click items |
| How hiding works | Expands its own separator status item | The same separator technique, plus automatic rearranging of other apps' items |
| Background activity when idle | Event-driven; update checks only if scheduled | Varies with enabled features |
| Minimum macOS | 14 Sonoma | See vendor's site |

If you rely on Bartender's advanced features, keep using it; if you only want a fast, permission-free hider, Barback is for you.

### How it compares to Bartender: what we learned

Before writing Barback we studied Bartender 6 (6.6.2 on macOS 26) from the outside: its public documentation and release notes, open-source peers (Hidden Bar, Ice, Dozer), and a static look at the installed app's bundle, linked frameworks and imported APIs. In summary:

- **Hiding itself is cheap.** Bartender hides items the same way Hidden Bar, Ice and Barback do: by widening one of its own separator status items. That needs no permission and no background work, so Barback copies it.
- **The heavy parts are the extras.** Automatic rearranging works by posting synthetic ⌘-drag mouse events while briefly intercepting the user's clicks; the Bartender Bar, search and item identification on Tahoe rely on capturing images of menu bar items (Screen Recording); app names come from Accessibility queries to every menu-bar app; and optional menu bar styling redraws on a timer. Bartender's own support pages and release notes acknowledge mouse movement, CPU and WindowServer load from these paths, and many releases tune them.
- **What Barback does differently.** Hiding is event-driven: one-shot timers handle auto-rehide, hover dwell and the 0.4 s hover exit delay, with no polling loops, screen capture, event taps, synthetic events or private APIs. You arrange items yourself with ⌘-drag, which macOS remembers. The optional Sparkle updater is separate from hiding: its network checks start off, and its installer helpers run only when updating.
- **What Barback leaves out** on purpose: automatic arranging, the secondary bar, image-based search (Barback's Quick Search only matches the names of items you put in a panel), triggers, spacing changes, menu bar styling (Barback only restyles its own icons) and widgets. Context profiles only change Barback's own sections and panel membership, never other apps' icons. These all need the permissions and machinery above.
- **macOS 26 caveat.** On Tahoe, Control Center owns the windows of most menu bar items, so any tool reading window metadata sees "Control Center" rather than the real app. Bartender works around this with image hashing and an Accessibility helper; Barback labels such items honestly and only uses Accessibility if you opt in.

## Build from source

Requires Swift 5.9+ (full Xcode or just the Command Line Tools).

```sh
make app        # build and ad-hoc sign dist/Barback.app
make run        # build, then open it
make test       # run the test suite
make updater-test # exercise appcast signing with Sparkle's tools and public test keys
make zip        # universal build -> dist/Barback-<version>.zip (+ .sha256, dist/barback.rb)
make tap        # render the Homebrew cask to dist/barback.rb from the local zip
make help       # every target
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout, Command Line Tools notes and the release process.

## Credits

Barback stands on the shoulders of earlier open-source menu bar managers that pioneered the separator technique: [Hidden Bar](https://github.com/dwarvesf/hidden), [Ice](https://github.com/jordanbaird/Ice) and [Dozer](https://github.com/Mortennn/Dozer). Thank you to their authors. Bartender is a trademark of its respective owner.

Updates use [Sparkle](https://sparkle-project.org/), distributed under its [permissive license and bundled third-party notices](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE), retained in the embedded framework.

## License

MIT © 2026 Ashley Rhodes. See [LICENSE](LICENSE).
