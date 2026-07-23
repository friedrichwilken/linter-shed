#!/usr/bin/env bash
# hooks/post-edit.sh — Claude Code PostToolUse hook for linter-shed
#
# Install by adding to ~/.claude/settings.json hooks:
#   "PostToolUse": [{
#     "matcher": "Edit|Write",
#     "hooks": [{"type": "command", "command": "~/.linter-shed/bin/hooks/post-edit.sh", "async": true}]
#   }]

set -euo pipefail

SHED_BIN="${LINTER_SHED_DIR:-$HOME/.linter-shed}/bin"
SHED="$SHED_BIN/shed"

[[ -x "$SHED" ]] || exit 0

# Claude Code passes tool input as JSON on stdin
input=$(cat)
tool_name=$(echo "$input" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || true)

# Only act on Edit and Write
[[ "$tool_name" == "Edit" || "$tool_name" == "Write" ]] || exit 0

file=$(echo "$input" | python3 -c "
import json, sys
d = json.load(sys.stdin)
inp = d.get('tool_input', {})
print(inp.get('file_path', inp.get('path', '')))
" 2>/dev/null || true)

[[ -n "$file" && -f "$file" ]] || exit 0

result=$("$SHED" check "$file" 2>/dev/null)
ok=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', True))" 2>/dev/null || echo "true")
skipped=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('skipped', False))" 2>/dev/null || echo "false")

[[ "$skipped" == "True" ]] && exit 0
[[ "$ok" == "True" ]] && exit 0

# Emit diagnostics as a hook feedback message so Claude sees them
echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
diags = data.get('diagnostics', [])
if not diags:
    sys.exit(0)
print('linter-shed found issues:')
for d in diags:
    sev = d.get('severity', 'error').upper()
    print(f\"  {d['file']}:{d['line']}:{d['col']}: [{sev}] {d['message']}\")
"
