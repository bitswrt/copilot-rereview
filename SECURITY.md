# Security Policy

## Reporting a Vulnerability

If you discover a security issue, please **do not open a public issue**. Instead, report it privately via GitHub's security advisory system:

**[Report a vulnerability](https://github.com/bitswrt/copilot-rereview/security/advisories/new)**

We will acknowledge your report within 5 business days and aim to provide a fix or mitigation within 30 days for confirmed issues.

## Threat Model

This action is a **composite GitHub Action** that runs inside a caller's workflow. The relevant attack surface:

### What this action does

1. Reads PR metadata via `gh pr view` (authenticated with the caller-provided `github-token`)
2. Invokes the GraphQL `requestReviewsByLogin` mutation to add bot reviewers
3. Writes a markdown summary to `$GITHUB_STEP_SUMMARY`

### What this action does NOT do

- ❌ Make outbound network calls beyond `api.github.com`
- ❌ Execute caller-controlled code (no `eval`, no piping untrusted input to a shell)
- ❌ Read or write files outside `$GITHUB_STEP_SUMMARY` and `$GITHUB_OUTPUT`
- ❌ Forward `github-token` to any third party
- ❌ Persist any state across runs

### Token handling

The `github-token` input is:

- Passed only as an env var (`GH_TOKEN`) to the `gh` CLI subprocess
- Never echoed to stdout/stderr (GitHub Actions auto-masks secret values, but we also avoid passing it to commands that would print it)
- Never written to `$GITHUB_STEP_SUMMARY` or `$GITHUB_OUTPUT`

## Recommendations for callers

1. **Use a fine-grained PAT** scoped to the minimum required permission (`Pull requests: read+write`). Do not use a classic PAT or a token with broader scopes.
2. **Trigger with `pull_request_target`, not `pull_request`** when using a privileged token — `pull_request` runs the workflow YAML from the PR head branch, allowing PR authors to modify the workflow and exfiltrate the token.
3. **Pin to a specific tag or SHA** (`@v1.0.0` or `@<commit-sha>`) for supply-chain protection. The floating `@v1` tag follows compatible updates but is mutable; pin to immutable refs in security-sensitive contexts.
4. **Restrict the workflow with `if:` guards** — e.g. skip fork PRs (`github.event.pull_request.head.repo.full_name == github.repository`) to ensure the token is only used in trusted contexts.
5. **Use `permissions: {}`** at the workflow level — the action does not need `GITHUB_TOKEN` permissions; all API calls use the `github-token` input.

## Supply Chain

This action is **shell-based** (composite, no Node.js/npm dependencies). The only runtime dependencies are:

- `bash` (preinstalled on all GitHub-hosted runners)
- `gh` CLI (preinstalled on `ubuntu-latest`, `macos-latest`, `windows-latest`)
- `jq` (preinstalled on `ubuntu-latest`)
- `sed`, `tr`, `awk` (POSIX, preinstalled)

No npm/pip/cargo dependencies, no Docker images, no third-party actions invoked.
