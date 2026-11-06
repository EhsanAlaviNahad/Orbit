# Changelog

All notable changes to Orbit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions before 0.4.0 shipped under the name **Eclick**. The rebrand kept the same bundle
identifier, `com.ehsanalavinahad.eclick`, so preferences and macOS permissions carry forward.

## [Unreleased]

### Added

- The live demo page carries Open Graph and Twitter card metadata, so sharing the demo link renders
  a preview card. GitHub's repository social preview only covers the repository URL itself.

### Fixed

- The live demo ran a substring filter while describing itself as Orbit's search. It now uses the
  real normalisation, ranking tiers, aliases, and exact-only system-command rules from
  `Core.swift`, checked against the Swift implementation (`018d1ec`, `7164c66`).
- Security reports had no working fallback: SECURITY.md asked for a blank issue, but blank issues
  are disabled and every form here demands details. A security contact form now carries only a
  reply address and a severity.
- The one-command installer deletes files, and the README did not say so: it replaces
  `~/Applications/Orbit.app` and removes `~/Applications/Eclick.app` when that bundle carries
  Orbit's old identifier. Both are now disclosed next to the command, in the README and on the live
  demo page, and readers are pointed at `Scripts/install-app.sh`, the file that actually contains
  the deletions.
- The live demo page listed six words for window arrangement while the README and `Core.swift` carry
  eight: `top` and `bottom`, which are real aliases for `Tile Window Top` and `Tile Window Bottom`,
  were missing from the page.
- The privacy guarantee in SECURITY.md said the app writes nothing to disk but preferences. Enabling
  "Launch at login" also registers a login item with macOS, so the guarantee now names that record
  and states that it identifies the app rather than your windows.
- Documentation corrections, none of which change the app: CI no longer described as running;
  contributing guide states the actual 4-space indentation and the real reason the tests avoid
  XCTest; window-arrangement, Dock, and scroll-step text matched to what the code does.

## [0.4.1] - 2026-11-06

### Fixed

- Restored hint scanning and overlay repaint performance on macOS 27.2, which had regressed after
  the 27.2 update (`795fb61`).
- Orbit now starts windowless on every launch path, including login items, instead of flashing a
  window it should never show (`7f5841d`).

### Changed

- Removed a redundant `macOS 26` availability gate now that the deployment floor is 27.0 (`36494ef`).

Note that the documentation *inside this tag* is stale in several ways the `main` branch no longer
is: the README and contributing guide there still describe CI as running, the contributing guide
still claims 2-space indentation and that the tests run on any Swift 6 toolchain, the README still
gives a wrong reason for avoiding XCTest and still overstates the window-arrangement and Dock
behaviour, and the demo page still filtered by substring instead of Orbit's search rules. Run
`git show v0.4.1:README.md` to see the stale text; the branch holds the corrected version. No file
under `Sources/` or `Resources/` differs between the tag and `main`.

## [0.4.0] - 2026-08-28

Only one commit carried version 0.4.0 (`2805f13`); the version moved to 0.4.1 the same day. No
release was published for it.

### Changed

- Eclick is now **Orbit**. Product name, menu bar icon, settings window, and documentation were
  rebranded (`2805f13`, `118ec41`).
- Bundle identifier and local designated requirement were kept stable across the rename so existing
  Accessibility and Screen Recording grants and saved preferences survive the upgrade.

### Added

- Adjustable launch and branding behaviour for the menu bar app (`118ec41`).

## [0.3.4] - 2026-08-27

Builds between 0.3.0 and 0.3.4 kept the version at 0.3.4 from `f0e04db` onward, so the features
landed in that window are grouped here.

### Added

- Window arrangement commands — `left`, `right`, `top`, `bottom`, `center`, `fill`, `maximize`,
  `full screen` — routed through the native macOS Window menu with Accessibility resizing as a
  fallback (`698f07b`).
- Exact `restart`, `shutdown`, and `sleep` system commands behind a two-Enter confirmation, with
  mock-only execution in tests (`698f07b`).
- Scroll Speed slider, persisted, from 0.5× to 3× (`cd712ae`).
- Extended keyboard hint controls: Option-Enter double-clicks and Shift-Enter right-clicks the
  selected target (`8c55de7`).
- Custom menu bar icon (`807d4a0`).
- Search HUD accessibility refinements so VoiceOver and hint mode coexist (`c455012`).

### Fixed

- Scrolling now uses Option-Arrow rather than a conflicting modifier (`2c060fc`).
- Hint activation latency reduced (`f0e04db`).

### Removed

- The keep-awake experiment was reverted; it did not earn its power-management complexity
  (`db221ed`, after `d7a0984`).

## [0.3.0] - 2026-08-11

The first commit in this repository carries version 0.3.0, build 1, in `Resources/Info.plist`; no git
tag was ever made for it. Earlier Eclick builds existed privately and are not documented here,
because there is no record of them in this history.

### Added

- Initial public release as Eclick: Command-E to scan the focused window, search visible controls by
  name or home-row hint, and click without the mouse (`0b67c09`).
- Keyboard mouse actions: click, double-click, and right-click the selected target (`75057b1`).
- Stable local app identity so rebuilds keep macOS permissions.

[Unreleased]: https://github.com/EhsanAlaviNahad/Orbit/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/EhsanAlaviNahad/Orbit/releases/tag/v0.4.1
[0.4.0]: https://github.com/EhsanAlaviNahad/Orbit/commit/2805f13
[0.3.4]: https://github.com/EhsanAlaviNahad/Orbit/commit/f0e04db
[0.3.0]: https://github.com/EhsanAlaviNahad/Orbit/commit/0b67c09
