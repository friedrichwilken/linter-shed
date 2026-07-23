#!/usr/bin/env bash
# PostToolUse hook for linter-shed
# Runs shed check on edited/written files and feeds diagnostics back to Claude.

# Never fail hard -- linting is best-effort
set +e

# Read full stdin
INPUT=$(cat)

# Extract tool_name and file_path using python3
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

# Run shed check and capture JSON output
SHED_OUTPUT=$("$SHED_BIN" check "$FILE_PATH" 2>/dev/null)

# If shed produced no output (unexpected crash), exit silently
if [[ -z "$SHED_OUTPUT" ]]; then
  exit 0
fi

# Parse ok and skipped flags, build diagnostic text.
# Pipe $SHED_OUTPUT into python3 via echo so the heredoc can supply the script body.
echo "$SHED_OUTPUT" | python3 - <<'PYEOF'
import sys, json

raw = sys.stdin.read()
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

import json as _json
print(_json.dumps({"systemMessage": system_msg}))
sys.exit(2)
PYEOF

# Propagate python3's exit code
exit $?
