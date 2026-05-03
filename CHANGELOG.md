# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.2] — 2026-05-03

### Changed

- Step Summary: replace `### Command` (which displayed a pseudo-shell-command misleading users into thinking they could re-run it in a terminal) with structured `### GraphQL mutation` (field table) + `### Response` (status + JSON, ` ```json ` fence only when output is parseable JSON) + folded `Reproduce locally` (a real, copy-pastable `gh api graphql -F ... -f ...` command). Workflow log line also rewritten from `$ <pseudo-command>` to `[gh api graphql] mutation: ...` to drop the misleading `$` shell prompt. Behaviour-preserving display change only — the underlying mutation call is unchanged. (#4, fixes #3)
- Internal: rename GitHub org references `bitswrt-devs` → `bitswrt` across own README, CHANGELOG, SECURITY, and scripts to align with the bitswrt company main-org rename. Old refs continue to work via GitHub's permanent owner redirect; this is a documentation/onboarding cleanup. (#2)

## [1.0.1] — 2026-05-03

### Changed

- Bump `actions/checkout` from 4 to 6 in CI workflows (dependabot). (#1)

## [1.0.0] — 2026-05-03

### Added

- Initial release.
- Composite action that re-requests GitHub Copilot code review on a PR via the GraphQL `requestReviewsByLogin` mutation.
- Inputs: `pr-number`, `github-token`, `repository` (defaults to caller), `bot-logins` (defaults to Copilot, supports comma-separated multi-bot list).
- Outputs: `review-requested`, `pr-node-id`.
- Comprehensive Step Summary with PR metadata table, command, GraphQL response, and failure-cause hints.
- Defensive guards: `pr-number` digit-only validation, GraphQL `errors` field detection (defends against gh-CLI silent-succeed edge cases), graceful fallback for `$GITHUB_STEP_SUMMARY` etc. when running locally.
- Local dry-run support — script can run outside GitHub Actions with sensible env defaults.

[Unreleased]: https://github.com/bitswrt/copilot-rereview/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/bitswrt/copilot-rereview/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/bitswrt/copilot-rereview/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/bitswrt/copilot-rereview/releases/tag/v1.0.0
