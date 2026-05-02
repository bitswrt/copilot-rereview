# Re-request Copilot Review

[![Marketplace](https://img.shields.io/badge/Marketplace-Re--request%20Copilot%20Review-blue?logo=github)](https://github.com/marketplace/actions/re-request-copilot-review)
[![Test](https://github.com/bitswrt/copilot-rereview/actions/workflows/test.yml/badge.svg)](https://github.com/bitswrt/copilot-rereview/actions/workflows/test.yml)

Re-request **GitHub Copilot code review** on a pull request via the GraphQL `requestReviewsByLogin` mutation.

Workaround for the GitHub product gap where the org-level Ruleset's "Review new pushes" rule does **not** auto-trigger Copilot re-review on subsequent commits to the same PR (only the first push triggers; re-review must be manually requested via the UI). See community discussion threads [#186152](https://github.com/orgs/community/discussions/186152), [#185376](https://github.com/orgs/community/discussions/185376), [#160286](https://github.com/orgs/community/discussions/160286).

## Why GraphQL `requestReviewsByLogin`?

`gh pr edit --add-reviewer "@copilot"` (gh CLI 2.91+) is the documented way, but the runner's preinstalled `gh` is often older — and **older `gh` silently succeeds without actually re-requesting** (exit 0, no-op), making the workflow look healthy while doing nothing. This action calls the GraphQL mutation directly (the same one `gh` 2.91 invokes internally — confirmed via `GH_DEBUG=api` capture), bypassing the CLI version dependency entirely.

## Usage

### Auto-trigger on PR push + draft → ready

```yaml
# .github/workflows/copilot-rereview.yml
name: Re-request Copilot review
on:
  pull_request_target:
    types: [synchronize, ready_for_review]
  workflow_dispatch:
    inputs:
      pr_number:
        description: 'PR number (digits only)'
        required: true

permissions: {}

concurrency:
  group: copilot-rereview-pr-${{ github.event.pull_request.number || github.event.inputs.pr_number }}
  cancel-in-progress: true

jobs:
  rerequest:
    runs-on: ubuntu-latest
    if: >-
      github.event_name == 'workflow_dispatch' ||
      github.event.pull_request.head.repo.full_name == github.repository
    steps:
      - uses: bitswrt/copilot-rereview@v1
        with:
          pr-number: ${{ github.event.pull_request.number || github.event.inputs.pr_number }}
          github-token: ${{ secrets.GH_ORG_TOKEN }}
```

### Multi-bot support

```yaml
- uses: bitswrt/copilot-rereview@v1
  with:
    pr-number: ${{ github.event.pull_request.number }}
    github-token: ${{ secrets.GH_ORG_TOKEN }}
    bot-logins: 'copilot-pull-request-reviewer[bot],coderabbitai[bot],gemini-code-assist[bot]'
```

### Why `pull_request_target` (not `pull_request`)?

This action requires a high-privilege PAT (`github-token`). Triggering with `pull_request` runs the workflow YAML from the **PR head branch**, meaning a malicious PR can modify the workflow to exfiltrate the token. `pull_request_target` always runs the workflow from the **base branch**, neutralizing that attack vector.

Trade-off: workflow YAML changes can't self-test inside their own PR — they must be merged to the base branch first.

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `pr-number` | ✅ | — | PR number to re-request review on (pure digits, no `#`) |
| `github-token` | ✅ | — | PAT with **Pull requests: read+write**. Default `GITHUB_TOKEN` may not be able to add `@copilot` as reviewer under some org policies — use a fine-grained PAT |
| `repository` | | `${{ github.repository }}` | Target repo in `owner/name` format |
| `bot-logins` | | `copilot-pull-request-reviewer[bot]` | Comma-separated bot logins (each WITH `[bot]` suffix) |

## Outputs

| Name | Description |
|---|---|
| `review-requested` | `"true"` if mutation succeeded, `"false"` otherwise |
| `pr-node-id` | GraphQL node ID of the PR (useful for chaining with other actions) |

## Token requirements

The action requires a **fine-grained Personal Access Token** with:

- **Repository permissions**: `Pull requests: Read and write`

Default `GITHUB_TOKEN` may work in some orgs but **fails** if the org has:

- "Restrict token permissions" enabled, or
- Custom permission policies blocking bot reviewer assignment

For Copilot specifically, the org also needs **Copilot review** enabled in Rulesets/policies; this action only re-requests, it doesn't enable Copilot itself.

## Failure modes

The action writes a detailed Step Summary on every run. Common failures:

| Symptom | Cause | Fix |
|---|---|---|
| `github-token missing` | Token input empty | Configure `secrets.GH_ORG_TOKEN`, see Token requirements above |
| `pr-number invalid` | Manual dispatch with `#103` / `PR-103` etc | Pass digits only (`103`) |
| `Failed to fetch PR metadata` | Token lacks scope, or PR doesn't exist | Verify token permissions; verify PR number |
| `GraphQL response contained errors field` | API rejected mutation (rare) | Check Step Summary for the GraphQL error message |
| Mutation succeeds but Copilot doesn't review | PR author's Copilot quota exhausted | Org admin: enable `Settings → Copilot → Policies → Premium request paid usage`, or wait for quota reset |

## Local dry-run

The script can run outside GitHub Actions for local testing:

```bash
GH_TOKEN=$(gh auth token) \
PR=123 \
REPO=owner/repo \
BOT_LOGINS='copilot-pull-request-reviewer[bot]' \
TRIGGER=local \
ACTOR=$USER \
bash scripts/rerequest.sh
```

Summary markdown prints to stderr; `GITHUB_STEP_SUMMARY`, `GITHUB_OUTPUT`, etc. fall back to safe defaults when unset.

## Security

This action does not make outbound network calls beyond `api.github.com`. The `github-token` is passed only as an env var to the `gh` CLI subprocess and is masked in logs (per GitHub Actions secret-masking).

Report security issues via the repo's **Security** tab → "Report a vulnerability". See [SECURITY.md](SECURITY.md).

## How it works

1. Trim and validate `pr-number` (rejects `#103`, `PR-103`, mid-string spaces — refuses to silent-fix typos)
2. `gh pr view` fetches PR node ID + metadata (stderr captured separately so JSON parsing stays clean)
3. `gh api graphql` invokes the `requestReviewsByLogin` mutation with `botLogins` (login strings, not node IDs) and `union: true` (preserve existing reviewers)
4. Defensively scan the response for an `"errors"` field — even when HTTP is 200, GraphQL can carry per-field errors that some `gh` versions don't propagate as exit codes
5. Render a comprehensive Step Summary (PR metadata table + command + output + failure causes if any)

## License

[MIT](LICENSE)
