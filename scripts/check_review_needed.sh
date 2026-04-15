#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
PR_NUMBER="${PR_NUMBER:-}"
COMMENT_MARKER="${COMMENT_MARKER:-<!-- ai-pr-reviewer -->}"
SKIP_IF_DIFF_UNCHANGED="${SKIP_IF_DIFF_UNCHANGED:-true}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"

if [[ -z "$REPO" || -z "$PR_NUMBER" ]]; then
  echo "Missing REPO or PR_NUMBER for review precheck" >&2
  exit 1
fi

current_fingerprint="$(gh pr diff "$PR_NUMBER" --repo "$REPO" | git patch-id --stable | awk 'NR == 1 { print $1 }')"
if [[ -z "$current_fingerprint" ]]; then
  current_fingerprint="empty-diff"
fi

last_comment_body="$({
  gh api "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" | \
    jq -r --arg marker "$COMMENT_MARKER" '
      [ .[] | select((.body // "") | contains($marker)) ]
      | sort_by(.updated_at // .created_at)
      | last
      | .body // empty
    '
} || true)"

last_fingerprint="$(printf '%s\n' "$last_comment_body" | sed -n 's/^<!-- ai-pr-review-fingerprint:\([^>]*\) -->$/\1/p' | tail -n 1)"

should_review=true
skip_reason=""

if [[ "$SKIP_IF_DIFF_UNCHANGED" == "true" && -n "$last_fingerprint" && "$last_fingerprint" == "$current_fingerprint" ]]; then
  should_review=false
  skip_reason="diff-unchanged"
fi

echo "diff_fingerprint=$current_fingerprint" >> "$OUTPUT_FILE"
echo "should_review=$should_review" >> "$OUTPUT_FILE"
echo "skip_reason=$skip_reason" >> "$OUTPUT_FILE"
