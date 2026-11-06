# Contributing to Orbit

Thanks for taking an interest. Orbit is a small, focused menu bar app, and most contributions are
bug fixes or refinements to scanning, hinting, and window arrangement.

## Before you start

- Read the [README](README.md) and try the app first: `curl -fsSL https://raw.githubusercontent.com/EhsanAlaviNahad/Orbit/main/Scripts/install.sh | bash`
- For anything beyond a small fix, open an issue first and wait for agreement. A rejected feature
  costs you a review cycle and costs the project a maintenance burden forever.
- Check existing [issues](https://github.com/EhsanAlaviNahad/Orbit/issues) and
  [discussions](https://github.com/EhsanAlaviNahad/Orbit/discussions) to avoid duplicating work.

## Requirements

- Apple silicon Mac, macOS 27 or newer
- Swift 6.2 or newer command line tools (`xcode-select --install`)

Orbit targets `.macOS("27.0")` in `Package.swift`, so the app itself cannot be built on older
operating systems or on GitHub-hosted runners that lack the macOS 27 SDK. The core logic tests do
not need the app bundle and run anywhere with a Swift 6 toolchain.

## Getting set up

```sh
git clone https://github.com/EhsanAlaviNahad/Orbit.git
cd Orbit
./Scripts/build-app.sh          # produces .build/Orbit.app
./Scripts/test-core.sh          # core logic tests, no app bundle needed
```

## Making a change

1. Branch from `main`: `git checkout -b my-change`
2. Keep the change scoped to one thing. Unrelated drive-by edits make reviews slower for everyone.
3. Update tests when you change behaviour. `Tests/CoreSelfTests/main.swift` is a plain Swift
   executable, not XCTest, so a new test is a new function plus a call to it.
4. Run `./Scripts/test-core.sh` and `./Scripts/build-app.sh`. Both must pass.
5. If you touched scanning, hinting, or the overlay, also run the app and check the behaviour by
   hand. Those paths depend on live Accessibility data and cannot be covered by unit tests.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `refactor:`,
`docs:`, `test:`, `chore:`. The subject says what changed; add a body only when the reason is not
obvious from the diff.

## Pull requests

- One logical change per PR.
- Explain the problem, then the approach, then how you verified it.
- Attach a screenshot or recording for any visual change to the overlay or hint labels.
- CI must be green before you ask for a review.

## Code style

- Match the surrounding file. Swift's default formatting is used with 2-space indentation.
- Prefer small types with a single responsibility, as in `Core.swift` and `Scanner.swift`.
- Do not add a dependency without discussing it. Orbit deliberately has none.
- Never log, store, or transmit window or screen content. On-device only is a product guarantee,
  not a preference.

## Reporting bugs

Use the [bug template](.github/ISSUE_TEMPLATE/bug-report.yml). Include your macOS version, the app
you were targeting, whether OCR fallback was enabled, and the exact keys you pressed.

## Security issues

Do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## Licence

By contributing you confirm the change is yours to submit under the project's MIT licence.
