#!/usr/bin/env bash
# PostToolUse hook for linter-shed
# Runs shed check on edited/written files and feeds diagnostics back to Claude.

# Never fail hard -- linting is best-effort
set +e

# Read full stdin
INPUT=$(cat)

# Extract tool_name using python3
TOOL_NAME=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('tool_name', ''))
except Exception:
    print('')
" <<<"$INPUT" 2>/dev/null)

# Only act on Edit and Write
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('tool_input', {}).get('file_path', ''))
except Exception:
    print('')
" <<<"$INPUT" 2>/dev/null)

# Guard: file_path must be non-empty and the file must exist
if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
  exit 0
fi

# Look for shed binary
SHED_BIN="${HOME}/.linter-shed/bin/shed"
if [[ ! -x "$SHED_BIN" ]]; then
  exit 0
fi

# Run shed check, capturing stdout and stderr separately.
# When shed produces no stdout (unexpected crash), surface the stderr so
# Claude knows what went wrong rather than silently discarding it.
SHED_STDERR_FILE="$(mktemp /tmp/shed_hook_XXXXXX)"
SHED_OUTPUT=$("$SHED_BIN" check "$FILE_PATH" 2>"$SHED_STDERR_FILE")
SHED_EXIT=$?

if [[ -z "$SHED_OUTPUT" ]]; then
  SHED_STDERR_CONTENT="$(cat "$SHED_STDERR_FILE")"
  rm -f "$SHED_STDERR_FILE"
  python3 -c "
import json, sys
stderr = sys.argv[1]
file_path = sys.argv[2]
msg = 'linter-shed: shed check crashed or produced no output for ' + file_path
if stderr:
    msg += ': ' + stderr.splitlines()[0]
print(json.dumps({'systemMessage': msg}))
" "$SHED_STDERR_CONTENT" "$FILE_PATH"
  exit 2
fi
rm -f "$SHED_STDERR_FILE"

# Parse ok and diagnostics; build systemMessage if issues found.
# Write output to a temp file to avoid pipe/heredoc stdin conflict.
SHED_OUTPUT_FILE="$(mktemp /tmp/shed_hook_out_XXXXXX)"
printf '%s' "$SHED_OUTPUT" > "$SHED_OUTPUT_FILE"
python3 - "$SHED_OUTPUT_FILE" <<'PYEOF'
import sys, json

with open(sys.argv[1]) as fh:
    raw = fh.read()

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

if data.get('ok', False) or data.get('skipped', False):
    sys.exit(0)

diagnostics = data.get('diagnostics', [])
if not diagnostics:
    sys.exit(0)

file_path = diagnostics[0].get('file', '') if diagnostics else ''

lines = []
for d in diagnostics:
    severity = d.get('severity', 'error').upper()
    f = d.get('file', file_path)
    line = d.get('line', 0)
    col = d.get('col', 0)
    msg = d.get('message', '')
    lines.append(f"  {f}:{line}:{col}: [{severity}] {msg}")

diag_text = '\n'.join(lines)
count = len(diagnostics)

system_msg = (
    f"linter-shed found {count} issue(s) in {file_path}:\n"
    f"{diag_text}\n"
    "Please fix these issues."
)

print(json.dumps({"systemMessage": system_msg}))
sys.exit(2)
PYEOF

HOOK_EXIT=$?
rm -f "$SHED_OUTPUT_FILE"
exit $HOOK_EXIT
