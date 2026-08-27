# Eclick

Eclick is a local macOS menu bar utility for clicking visible controls without leaving the keyboard. Press **Command-E**, then search by element name or visible home-row hint and press Enter.

Eclick scans only the focused window. It uses macOS Accessibility for native controls and optionally fills sparse or incomplete scans with on-device Vision OCR. No data leaves the Mac.

## Requirements

- Apple silicon Mac running macOS 27
- Swift 6.2 or newer command-line tools
- Accessibility permission
- Screen Recording permission for optional OCR fallback

## Build and run

Build a release app bundle:

```sh
./Scripts/build-app.sh
open .build/Eclick.app
```

To install it for the current user:

```sh
./Scripts/install-app.sh
open ~/Applications/Eclick.app
```

Eclick appears only in the menu bar. On the first use, open Eclick Settings and grant Accessibility. Grant Screen Recording if OCR fallback is wanted. macOS may require Eclick to be restarted after either permission changes.

Always grant permissions to the installed copy at `~/Applications/Eclick.app`. Builds use a stable local designated requirement so subsequent replacements keep the same macOS identity. Older builds from before version 0.2 used a changing code hash; remove that stale Eclick row once, add the installed app again, enable it, then relaunch Eclick.

## Use

1. Focus the window containing the control.
2. Press **Command-E**.
3. Type part of the control name. Search ignores case, accents, and punctuation; for example, `settings` or `set-` matches “Settings.”
4. Press Enter to click the highlighted element or run the highlighted window command. Option-Enter double-clicks elements; Shift-Enter right-clicks them. Use Tab, Shift-Tab, Up, or Down to select another match. Option-Up and Option-Down gently scroll the focused page or app while hints remain open.
5. Every target keeps a visible home-row hint. Type either an element name or its hint, then press Enter. No modifier key is needed.
6. Press Escape or Command-E again to cancel. Backspace edits the unified search.

### Keyboard controls

| Keys | Action |
| --- | --- |
| Enter | Left-click the selected target |
| Option-Enter | Double-click the selected target |
| Shift-Enter | Right-click the selected target |
| Tab / Shift-Tab / Up / Down | Select the next / previous match |
| Option-Up / Option-Down | Scroll the focused app while hints stay open |
| Escape / Command-E | Cancel hint mode |

Option-Arrow scrolling uses a small wheel event at the center of the active window; it has no settings slider.

Accessibility controls use their semantic action when possible. Other targets receive a left click at their center, which moves the pointer. OCR text is only added where it does not overlap an Accessibility target; some detected text may not actually be clickable.

Visible Dock items also receive hints. Activating one uses its Accessibility action to open or switch to the application.

Window arrangement lives in the same search box. Search for `left`, `right`, `top`, `bottom`, `center`, `fill`, `maximize`, or `full screen`, then press Enter. Eclick invokes the matching macOS Window menu command when available, preserving system tiling gaps, Stage Manager behavior, the menu bar, and the Dock; direct Accessibility resizing remains a fallback.

Exact system commands are also available: `restart`, `shutdown`, and `sleep`. Matching ignores surrounding whitespace and letter case but never uses fuzzy search, so text such as `restart now` remains an ordinary search. Each command requires two complete Enter presses. Restart and shutdown then open the native macOS confirmation dialog; changing the query, pressing Escape, or closing the overlay cancels Eclick's pending confirmation.

The Settings window can change the global shortcut, hint-label size and color, show permission status, and enable launch at login. Hint labels include built-in appearances plus a persistent custom color with automatic readable text. A shortcut must contain Command, Control, or Option. If another utility already owns it, Eclick keeps the previous working shortcut.

Search reads direct keyboard events so the overlay can remain non-activating. Standard keyboard layouts work; IME and dead-key composition are not supported in the search overlay.

## Test

The installed command-line toolchain does not include a usable XCTest runtime, so the core tests compile and run as a standalone Swift executable:

```sh
./Scripts/test-core.sh
```

The tests cover home-row code boundaries, prefix safety, search normalization and ranking, Option-Arrow scroll classification and wheel-event construction, exact system-command parsing and confirmation, mock-only system execution, hint color validation and contrast selection, geometry validation, Accessibility/OCR merging, and window arrangement geometry.

## Update or uninstall

Run `./Scripts/install-app.sh` again to replace the installed bundle. Version 0.2 and later preserve a stable local identity across rebuilds.

To uninstall, quit Eclick and move `~/Applications/Eclick.app` to Trash. Disable “Launch at login” first if it was enabled.
