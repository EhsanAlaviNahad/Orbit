# Security Policy

Orbit reads the accessibility tree of the focused window and, when enabled, runs on-device Vision
OCR over that window. It can also synthesise clicks and key events. That combination is worth
treating carefully, so this project takes security reports seriously.

## Data handling guarantees

- Screen content, element names, and search text stay in memory on the Mac.
- No telemetry, no analytics, no account, no network calls.
- Nothing is written to disk except your own preferences under the app's bundle identifier.

A report that shows any of these guarantees being broken is treated as a vulnerability, even if the
behaviour seems harmless.

## Reporting a vulnerability

Please use [GitHub Private Vulnerability Reporting](https://github.com/EhsanAlaviNahad/Orbit/security/advisories/new).
Do not open a public issue, and do not post reproduction steps in a discussion or pull request
before a fix exists.

If private reporting is unavailable to you, use the
[security contact form](https://github.com/EhsanAlaviNahad/Orbit/issues/new?template=security-contact.yml).
It opens an issue titled `security: contact needed` carrying only a way to reach you and a rough
severity, then wait for a maintainer to reply. Blank issues are disabled on this repository, so do
not use the bug report form as a fallback — its required fields would make you describe the flaw
before a fix exists.

## What to include

- Orbit version, from Orbit Settings or the release tag
- macOS version and hardware
- The exact steps that trigger the problem
- Which permissions Orbit had been granted
- A proof of concept, if you have one

## Response times

This is a single-maintainer project. Expect an acknowledgement within 7 days and an assessment
within 30. You will be credited in the advisory unless you ask not to be.

## Scope

Vulnerabilities in Orbit's own code are in scope. macOS Accessibility or Vision behaviour is in
scope where Orbit could have guarded against it. Reports about your own machine configuration, or
about malware that already has Accessibility permission, are out of scope.
