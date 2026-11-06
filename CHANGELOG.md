# Changelog

All notable changes to Orbit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions before 0.4.0 shipped under the name **Eclick**. The rebrand kept the same bundle
identifier, `com.ehsanalavinahad.eclick`, so preferences and macOS permissions carry forward.

## [0.4.1] - 2026-11-03

### Fixed

- Restored hint scanning and overlay repaint performance on macOS 27.2, which had regressed after
  the 27.2 update (`795fb61`).
- Orbit now starts windowless on every launch path, including login items, instead of flashing a
  window it should never show (`7f5841d`).

### Changed

- Removed a redundant `macOS 26` availability gate now that the deployment floor is 27.0 (`36494ef`).

## [0.4.0] - 2026-08-28

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

The first commit in this repository is tagged version 0.3.0, build 1. Earlier Eclick builds
existed privately and are not documented here, because there is no record of them in this history.

### Added

- Initial public release as Eclick: Command-E to scan the focused window, search visible controls by
  name or home-row hint, and click without the mouse (`0b67c09`).
- Keyboard mouse actions: click, double-click, and right-click the selected target (`75057b1`).
- Faster, more reliable hint activation (`f0e04db`).
- Stable local app identity so rebuilds keep macOS permissions.

[Unreleased]: https://github.com/EhsanAlaviNahad/Orbit/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/EhsanAlaviNahad/Orbit/releases/tag/v0.4.1
[0.4.0]: https://github.com/EhsanAlaviNahad/Orbit/releases/tag/v0.4.0
[0.3.4]: https://github.com/EhsanAlaviNahad/Orbit/releases/tag/v0.3.4
[0.3.0]: https://github.com/EhsanAlaviNahad/Orbit/releases/tag/v0.3.0
