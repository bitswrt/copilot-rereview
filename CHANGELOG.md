# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-05-03

### Added

- Initial release.
- Composite action that re-requests GitHub Copilot code review on a PR via the GraphQL `requestReviewsByLogin` mutation.
- Inputs: `pr-number`, `github-token`, `repository` (defaults to caller), `bot-logins` (defaults to Copilot, supports comma-separated multi-bot list).
- Outputs: `review-requested`, `pr-node-id`.
- Comprehensive Step Summary with PR metadata table, command, GraphQL response, and failure-cause hints.
- Defensive guards: `pr-number` digit-only validation, GraphQL `errors` field detection (defends against gh-CLI silent-succeed edge cases), graceful fallback for `$GITHUB_STEP_SUMMARY` etc. when running locally.
- Local dry-run support — script can run outside GitHub Actions with sensible env defaults.

[Unreleased]: https://github.com/bitswrt-devs/copilot-rereview/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/bitswrt-devs/copilot-rereview/releases/tag/v1.0.0
