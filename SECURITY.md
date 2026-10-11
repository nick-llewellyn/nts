# Security Policy

## Supported Versions

Security fixes ship in a new release of the latest major version.
Earlier major versions do not receive backports, so upgrade to the
latest 10.x release to get them.

| Version | Supported          |
| ------- | ------------------ |
| 10.x    | :white_check_mark: |
| < 10.0  | :x:                |

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, report security issues either:

- By email: `nllewelln@gmail.com`, or
- Via GitHub's [Private Vulnerability Reporting](https://github.com/nick-llewellyn/nts/security/advisories/new).

You can expect an **initial response within 48 hours**. Further updates will be provided as the issue is triaged and addressed.

## Dependencies

Published advisories against dependencies are tracked automatically:
`cargo audit` checks the Rust lockfile daily and on every change to
it, pull requests fail on moderate-or-higher advisories in Dart or
Rust dependencies, and Dependabot security updates are enabled.
Fixes ship in the next release and are listed in `CHANGELOG.md`.
