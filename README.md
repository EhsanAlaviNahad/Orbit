# Eclick

Eclick is a local macOS menu bar utility for clicking visible controls without leaving the keyboard. Press **Command-E**, then search by element name or visible home-row hint and press Enter.

Eclick scans only the focused window. It uses macOS Accessibility for native controls and optionally fills accessibility gaps with on-device Vision OCR. No data leaves the Mac.

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
4. Press Enter to click the highlighted result, Enter twice to double-click it, or Shift-Enter to right-click it. Use Tab, Shift-Tab, Up, or Down to select another match.
5. Every target keeps a visible home-row hint. Type either an element name or its hint, then press Enter. No modifier key is needed.
6. Press Escape or Command-E again to cancel. Backspace edits the unified search.

Accessibility controls use their semantic action when possible. Other targets receive a left click at their center, which moves the pointer. OCR text is only added where it does not overlap an Accessibility target; some detected text may not actually be clickable.

The Settings window can change the global shortcut, show permission status, and enable launch at login. A shortcut must contain Command, Control, or Option. If another utility already owns it, Eclick keeps the previous working shortcut.

Search reads direct keyboard events so the overlay can remain non-activating. Standard keyboard layouts work; IME and dead-key composition are not supported in the search overlay.

## Test

The installed command-line toolchain does not include a usable XCTest runtime, so the core tests compile and run as a standalone Swift executable:

```sh
./Scripts/test-core.sh
```

The tests cover home-row code boundaries, prefix safety, search normalization and ranking, geometry validation, and Accessibility/OCR merging.

## Update or uninstall

Run `./Scripts/install-app.sh` again to replace the installed bundle. Version 0.2 and later preserve a stable local identity across rebuilds.

To uninstall, quit Eclick and move `~/Applications/Eclick.app` to Trash. Disable “Launch at login” first if it was enabled.
