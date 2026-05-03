#!/usr/bin/env bash
# Re-request Copilot review action — business logic.
# Invoked by action.yml composite step.
#
# Required env (passed by action.yml from inputs):
#   GH_TOKEN     PAT for gh authentication
#   PR           target PR number
#   REPO         owner/name
#   BOT_LOGINS   comma-separated bot logins, each with [bot] suffix
#   TRIGGER      github.event_name
#   ACTOR        github.actor
#
# Optional env (auto-injected by GH Actions, defaults provided for local dry-run):
#   GITHUB_STEP_SUMMARY   summary markdown output (defaults to /dev/stderr)
#   GITHUB_OUTPUT         action outputs (defaults to /dev/null)
#   GITHUB_SERVER_URL     defaults to https://github.com
#   GITHUB_RUN_ID         defaults to 0
#
# Local dry-run example:
#   GH_TOKEN=$(gh auth token) PR=123 REPO=owner/repo \
#   BOT_LOGINS='copilot-pull-request-reviewer[bot]' \
#   TRIGGER=local ACTOR=$USER \
#   bash scripts/rerequest.sh

# -e: any failure exits; -u: unset variable exits; -o pipefail: any pipe stage failure propagates.
set -euo pipefail

# Local-dry-run friendly: GH Actions auto-injected vars get sensible defaults
# so set -u doesn't crash on fail-fast branches that write $GITHUB_STEP_SUMMARY.
: "${GITHUB_STEP_SUMMARY:=/dev/stderr}"
: "${GITHUB_OUTPUT:=/dev/null}"
: "${GITHUB_SERVER_URL:=https://github.com}"
: "${GITHUB_RUN_ID:=0}"

# Default outputs to "false" / empty; success path overrides.
{
  echo "review-requested=false"
  echo "pr-node-id="
} >> "$GITHUB_OUTPUT"

# ---- 0. Pre-flight validation -------------------------------------------

# GH_TOKEN missing yields opaque 401 from gh; fail-fast with config hint.
if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::github-token input is empty"
  {
    echo "## ❌ github-token missing"
    echo ""
    echo "This action requires a \`github-token\` input. Configure a fine-grained PAT with:"
    echo ""
    echo "- Repository permission: **Pull requests: read+write**"
    echo ""
    echo "Pass it via \`with.github-token\`, e.g.:"
    echo ""
    echo '```yaml'
    echo "    - uses: bitswrt/copilot-rereview@v1"
    echo "      with:"
    echo "        pr-number: \${{ github.event.pull_request.number }}"
    echo "        github-token: \${{ secrets.GH_ORG_TOKEN }}"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
  exit 1
fi

if [ -z "${PR:-}" ]; then
  echo "::error::pr-number input is empty"
  exit 1
fi

if [ -z "${REPO:-}" ]; then
  echo "::error::repository input resolved to empty"
  exit 1
fi

if [ -z "${BOT_LOGINS:-}" ]; then
  echo "::error::bot-logins input is empty"
  exit 1
fi

# Trim head/tail whitespace + pure-digit check.
# Mid-string whitespace (e.g. "10 3") still rejected — refuse to silent-fix typos.
PR_TRIMMED=$(printf '%s' "$PR" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
case "$PR_TRIMMED" in
  '' | *[!0-9]*)
    echo "::error::pr-number invalid: '$PR' (trimmed: '$PR_TRIMMED'); expected pure digits"
    {
      echo "## ❌ pr-number invalid"
      echo ""
      echo "Input: \`$PR\` → trimmed: \`$PR_TRIMMED\`"
      echo ""
      echo "Must be pure digits (\`123\`, not \`#123\` / \`PR-123\` / \`pull/123\`)."
    } >> "$GITHUB_STEP_SUMMARY"
    exit 1
    ;;
esac
PR=$PR_TRIMMED

TS=$(date -u +'%Y-%m-%d %H:%M:%S UTC')
PR_URL="$GITHUB_SERVER_URL/$REPO/pull/$PR"
RUN_URL="$GITHUB_SERVER_URL/$REPO/actions/runs/$GITHUB_RUN_ID"

# Markdown table cell escape: PR titles with | or newlines break summary rendering.
md_escape() {
  printf '%s' "$1" | tr '\n\r' '  ' | sed 's/|/\\|/g'
}

# ---- 1. Fetch PR metadata ----------------------------------------------
# Capture stdout separately (clean JSON for jq); stderr to a file (don't pollute).
PR_ERR_FILE=$(mktemp)
set +e
PR_INFO=$(gh pr view "$PR" --repo "$REPO" \
  --json id,number,title,headRefOid,headRefName,baseRefName,state,isDraft,author \
  2> "$PR_ERR_FILE")
PR_VIEW_STATUS=$?
set -e
PR_ERR=$(cat "$PR_ERR_FILE")
rm -f "$PR_ERR_FILE"

if [ "$PR_VIEW_STATUS" -ne 0 ]; then
  {
    echo "## ❌ Failed to fetch PR metadata"
    echo ""
    echo "| Field | Value |"
    echo "| --- | --- |"
    echo "| Repository | \`$REPO\` |"
    echo "| PR | [#$PR]($PR_URL) |"
    echo "| Trigger | \`$TRIGGER\` by @$ACTOR |"
    echo "| Run | [$GITHUB_RUN_ID]($RUN_URL) |"
    echo "| Timestamp | $TS |"
    echo ""
    echo "### \`gh pr view\` stderr"
    echo ""
    echo '```'
    printf '%s\n' "$PR_ERR"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
  echo "$PR_ERR" >&2
  exit 1
fi

PR_NODE_ID=$(printf '%s' "$PR_INFO" | jq -r '.id')
PR_TITLE=$(printf '%s' "$PR_INFO" | jq -r '.title')
PR_HEAD_SHA=$(printf '%s' "$PR_INFO" | jq -r '.headRefOid')
PR_HEAD_REF=$(printf '%s' "$PR_INFO" | jq -r '.headRefName')
PR_BASE_REF=$(printf '%s' "$PR_INFO" | jq -r '.baseRefName')
PR_STATE=$(printf '%s' "$PR_INFO" | jq -r '.state')
PR_DRAFT=$(printf '%s' "$PR_INFO" | jq -r '.isDraft')
PR_AUTHOR=$(printf '%s' "$PR_INFO" | jq -r '.author.login')
PR_HEAD_SHORT=${PR_HEAD_SHA:0:7}
PR_TITLE_MD=$(md_escape "$PR_TITLE")

# Emit pr-node-id output regardless of mutation success — useful for downstream.
echo "pr-node-id=$PR_NODE_ID" >> "$GITHUB_OUTPUT"

# ---- 2. Build botLogins arg list and invoke mutation --------------------
# Calls GraphQL requestReviewsByLogin (the same mutation gh 2.91+
# 'pr edit --add-reviewer @copilot' invokes internally — confirmed via
# GH_DEBUG=api capture). Uses gh api graphql to bypass gh CLI version
# requirement: older gh versions silent-succeed (exit 0 but no-op) on
# 'pr edit --add-reviewer @copilot', which is harder to debug than failing.
# botLogins values MUST include the [bot] suffix per the schema's
# RequestReviewsByLoginInput documentation.
# union:true means add to the reviewer set (don't replace) — preserves
# existing user/team reviewers.

# Build -F arguments from comma-separated BOT_LOGINS.
GH_API_ARGS=(-F prId="$PR_NODE_ID")
IFS=',' read -ra BOT_LOGINS_ARR <<< "$BOT_LOGINS"
BOT_LOGINS_DISPLAY=""   # comma-joined plain (e.g. `a, b`) — used in workflow log + Bots cell
BOT_LOGINS_QUOTED=""    # comma-joined quoted (e.g. `"a", "b"`) — used in GraphQL [String!] cell so the rendered value is a syntactically valid list literal
for raw in "${BOT_LOGINS_ARR[@]}"; do
  # Trim each login.
  bot=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$bot" ] && continue
  GH_API_ARGS+=(-f "botLogins[]=$bot")
  BOT_LOGINS_DISPLAY="${BOT_LOGINS_DISPLAY:+$BOT_LOGINS_DISPLAY, }$bot"
  BOT_LOGINS_QUOTED="${BOT_LOGINS_QUOTED:+$BOT_LOGINS_QUOTED, }\"$bot\""
done

GH_VERSION=$(gh --version | head -1 | awk '{print $3}')
# Workflow log line — explicitly NOT a shell command (no $ prompt) to avoid
# users copy-pasting the pseudo-syntax into a terminal expecting it to run.
echo "[gh api graphql] mutation: requestReviewsByLogin(pullRequestId=$PR_NODE_ID, botLogins=[$BOT_LOGINS_DISPLAY], union=true)"
set +e
# shellcheck disable=SC2016 # $prId/$botLogins are GraphQL variable refs, must NOT shell-expand
EDIT_OUT=$(gh api graphql "${GH_API_ARGS[@]}" \
  -f query='
    mutation($prId: ID!, $botLogins: [String!]) {
      requestReviewsByLogin(input: {
        pullRequestId: $prId,
        botLogins: $botLogins,
        union: true
      }) { clientMutationId }
    }' 2>&1)
STATUS=$?
set -e
printf '%s\n' "$EDIT_OUT"

# Defensive silent-succeed guard: gh api may return exit 0 even when
# GraphQL response contains "errors" field. Detect explicitly.
if [ "$STATUS" -eq 0 ] && printf '%s' "$EDIT_OUT" | grep -q '"errors"'; then
  STATUS=2
  echo "::warning::GraphQL response contained errors field; treating as failure"
fi

if [ "$STATUS" -eq 0 ]; then
  ICON="✅"
  VERDICT="Re-requested review"
  echo "review-requested=true" >> "$GITHUB_OUTPUT"
else
  ICON="❌"
  VERDICT="Failed to re-request review (exit $STATUS)"
fi

# ---- 3. Write Step Summary ---------------------------------------------
{
  echo "## $ICON $VERDICT"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Repository | \`$REPO\` |"
  echo "| PR | [#$PR]($PR_URL) — $PR_TITLE_MD |"
  echo "| Author | @$PR_AUTHOR |"
  echo "| State | $PR_STATE (draft: $PR_DRAFT) |"
  echo "| Head | \`$PR_HEAD_REF\` @ \`$PR_HEAD_SHORT\` |"
  echo "| Base | \`$PR_BASE_REF\` |"
  echo "| Bots | $BOT_LOGINS_DISPLAY |"
  echo "| Trigger | \`$TRIGGER\` by @$ACTOR |"
  echo "| Run | [$GITHUB_RUN_ID]($RUN_URL) |"
  echo "| Timestamp | $TS |"
  echo "| gh CLI | \`$GH_VERSION\` |"
  echo ""
  echo "### GraphQL mutation"
  echo ""
  # "Field" header (not "Variable") — Mutation row + 3 input fields below. The
  # actual GraphQL variables are $prId/$botLogins (see Reproduce locally
  # block); pullRequestId/botLogins/union are input-object fields.
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Mutation | \`requestReviewsByLogin\` |"
  echo "| \`pullRequestId\` | \`\"$PR_NODE_ID\"\` |"
  echo "| \`botLogins\` | \`[$BOT_LOGINS_QUOTED]\` |"
  echo "| \`union\` | \`true\` |"
  echo ""
  echo "### Response"
  echo ""
  if [ "$STATUS" -eq 0 ]; then
    echo "✅ Success — no \`errors\` field in response."
  else
    echo "❌ Failed (exit \`$STATUS\`)."
  fi
  echo ""
  echo '```json'
  if [ -z "$EDIT_OUT" ]; then
    echo "(no output — gh api returned silently with exit $STATUS)"
  else
    printf '%s\n' "$EDIT_OUT"
  fi
  echo '```'
  echo ""
  echo "<details><summary>Reproduce locally</summary>"
  echo ""
  echo '```bash'
  echo "gh api graphql \\"
  echo "  -F prId='$PR_NODE_ID' \\"
  for raw in "${BOT_LOGINS_ARR[@]}"; do
    bot=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$bot" ] && continue
    echo "  -f 'botLogins[]=$bot' \\"
  done
  echo "  -f query='mutation(\$prId: ID!, \$botLogins: [String!]) {"
  echo "    requestReviewsByLogin(input: {"
  echo "      pullRequestId: \$prId,"
  echo "      botLogins: \$botLogins,"
  echo "      union: true"
  echo "    }) { clientMutationId }"
  echo "  }'"
  echo '```'
  echo "</details>"

  if [ "$STATUS" -ne 0 ]; then
    echo ""
    echo "### Possible causes"
    echo ""
    echo "- PR author's Copilot premium request quota exhausted, and the org has not enabled \`Settings → Copilot → Policies → Premium request paid usage\`"
    echo "- \`github-token\` lacks scope (needs Pull requests: read+write)"
    echo "- Copilot code review service temporarily unavailable — wait a few minutes and re-check the PR page"
    echo "- Repository has not enabled Copilot review (Org/Repo Settings → Rulesets → Copilot review)"
    echo "- One of the bot logins doesn't exist or isn't a recognized review bot"
  fi
} >> "$GITHUB_STEP_SUMMARY"

exit "$STATUS"
