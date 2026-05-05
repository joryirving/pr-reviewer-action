#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v jq >/dev/null; then
  echo "jq is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "python3 is required" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

python3 "$SCRIPT_DIR/mock_openai_server.py" &
SERVER_PID=$!
sleep 1

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"; cleanup' EXIT

PASS=0
FAIL=0

check() {
  local desc="$1" result="$2" expected="$3"
  if [[ "$result" == "$expected" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (got '$result', expected '$expected')"
    FAIL=$((FAIL + 1))
  fi
}

# Shared Python code for parse_and_validate (same as run_review.sh)
PARSE_PY='
import sys, json
from pathlib import Path

response = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"))
content = ((response.get("choices") or [{}])[0].get("message") or {}).get("content")

if isinstance(content, str):
    text = content.strip()
elif isinstance(content, list):
    parts = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif isinstance(item, dict):
            item_type = item.get("type")
            if item_type in (None, "text"):
                text_part = item.get("text")
                if isinstance(text_part, str):
                    parts.append(text_part)
    text = "".join(parts).strip()
elif content is None:
    text = ""
else:
    text = str(content).strip()

if text.startswith("```"):
    lines = text.splitlines()
    if lines:
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    text = "\n".join(lines).strip()

decoder = json.JSONDecoder()
parsed = None

for start in range(len(text)):
    if text[start] not in "[{":
        continue
    try:
        candidate, end = decoder.raw_decode(text[start:])
        parsed = candidate
        break
    except json.JSONDecodeError:
        continue

if parsed is None:
    raise SystemExit("Could not extract JSON object from model response")

if isinstance(parsed, list) and len(parsed) == 1 and isinstance(parsed[0], dict):
    parsed = parsed[0]

if not isinstance(parsed, dict):
    raise SystemExit(f"Expected JSON object but got {type(parsed).__name__}")

print(json.dumps(parsed))
'

run_parse() {
  python3 - "$1" > "$TMPDIR/out.json" <<PYEOF
$PARSE_PY
PYEOF
}

echo "=== parse_and_validate: standard object response ==="
cat > "$TMPDIR/resp-object.json" <<'EOF'
{"id":"chatcmpl-test","choices":[{"message":{"content":"{\"verdict\":\"approve\",\"review_markdown\":\"Looks good.\"}"}}]}
EOF
run_parse "$TMPDIR/resp-object.json"
check "verdict=approve" "$(jq -r '.verdict' "$TMPDIR/out.json")" "approve"
check "review_markdown present" "$(jq -r 'if .review_markdown and (.review_markdown | length > 0) then "yes" else "no" end' "$TMPDIR/out.json")" "yes"

echo ""
echo "=== parse_and_validate: array response (MiniMax-style) ==="
cat > "$TMPDIR/resp-array.json" <<'EOF'
{"id":"chatcmpl-test","choices":[{"message":{"content":"[{\"verdict\":\"request_changes\",\"review_markdown\":\"Needs work.\"}]"}}]}
EOF
run_parse "$TMPDIR/resp-array.json"
check "verdict=request_changes" "$(jq -r '.verdict' "$TMPDIR/out.json")" "request_changes"
check "review_markdown present" "$(jq -r 'if .review_markdown and (.review_markdown | length > 0) then "yes" else "no" end' "$TMPDIR/out.json")" "yes"

echo ""
echo "=== parse_and_validate: markdown code block ==="
cat > "$TMPDIR/resp-block.json" <<'EOF'
{"id":"chatcmpl-test","choices":[{"message":{"content":"```json\n{\"verdict\":\"approve\",\"review_markdown\":\"Clean.\"}\n```"}}]}
EOF
run_parse "$TMPDIR/resp-block.json"
check "verdict=approve" "$(jq -r '.verdict' "$TMPDIR/out.json")" "approve"

echo ""
echo "=== parse_and_validate: rejects bare numeric list ==="
cat > "$TMPDIR/resp-bare-list.json" <<'EOF'
{"id":"chatcmpl-test","choices":[{"message":{"content":"[1,2,3]"}}]}
EOF
if run_parse "$TMPDIR/resp-bare-list.json"; then
  check "rejects bare numeric list" "no" "yes"
else
  check "rejects bare numeric list" "yes" "yes"
fi

echo ""
echo "=== parse_and_validate: rejects empty array ==="
cat > "$TMPDIR/resp-empty-array.json" <<'EOF'
{"id":"chatcmpl-test","choices":[{"message":{"content":"[]"}}]}
EOF
if run_parse "$TMPDIR/resp-empty-array.json"; then
  check "rejects empty array" "no" "yes"
else
  check "rejects empty array" "yes" "yes"
fi

echo ""
echo "=== Evidence provider execution ==="
cat > "$TMPDIR/provider-smoke.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"severity":"info","findings":[{"severity":"info","message":"smoke provider executed"}]}
JSON
EOF
chmod +x "$TMPDIR/provider-smoke.sh"

OUTPUT=$(bash "$TMPDIR/provider-smoke.sh" 2>&1)
check "provider outputs JSON" "$(echo "$OUTPUT" | jq -r '.findings[0].message' 2>/dev/null)" "smoke provider executed"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
