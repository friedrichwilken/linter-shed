#!/usr/bin/env bats
# Integration tests for hooks/post-edit.sh
#
# Strategy: redirect HOME to a tmpdir and place a mock shed binary at
# $HOME/.linter-shed/bin/shed (the path post-edit.sh hardcodes).
# Each test controls the mock's output to exercise specific code paths.
#
# Run from repo root:
#   bats tests/integration/test_hook.bats

load '../helpers/common'

HOOK="${SHED_REPO_ROOT}/hooks/post-edit.sh"
FIXTURES_DIR="${SHED_REPO_ROOT}/tests/fixtures"

# Saved real HOME so we can restore in teardown
_REAL_HOME="$HOME"

setup() {
    setup_test_shed_dir

    # Redirect HOME so the hook's `$HOME/.linter-shed/bin/shed` lookup hits
    # our mock, never the real ~/.linter-shed
    export HOME
    HOME="$(mktemp -d "${BATS_TEST_TMPDIR}/home_XXXXXX")"
    mkdir -p "$HOME/.linter-shed/bin"

    # Default mock: clean file (ok:true, no diagnostics)
    _write_mock_shed '{"ok": true, "diagnostics": [], "error": null}'
}

teardown() {
    export HOME="$_REAL_HOME"
    teardown_test_shed_dir
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _write_mock_shed JSON
# Writes a mock shed script that prints JSON and exits 0.
_write_mock_shed() {
    local json="$1"
    cat > "$HOME/.linter-shed/bin/shed" <<MOCKEOF
#!/usr/bin/env bash
printf '%s\n' '$json'
exit 0
MOCKEOF
    chmod +x "$HOME/.linter-shed/bin/shed"
}

# _build_input TOOL_NAME FILE_PATH
# Emits a Claude Code PostToolUse JSON payload on stdout.
_build_input() {
    local tool_name="$1"
    local file_path="$2"
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': sys.argv[1],
    'tool_input': {'file_path': sys.argv[2]},
    'tool_response': {}
}))
" "$tool_name" "$file_path"
}

# ---------------------------------------------------------------------------
# Non-Edit/Write tool names: hook must silently exit 0 with no output
# ---------------------------------------------------------------------------

@test "hook exits 0 silently for Bash tool" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.json")"
    echo '{}' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Bash" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently for Read tool" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.json")"
    echo '{}' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Read" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently for unknown tool name" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.py")"
    echo 'pass' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "SomeOtherTool" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Edit/Write tool on a clean file: hook must exit 0 with no output
# ---------------------------------------------------------------------------

@test "hook exits 0 silently when shed returns ok:true for Edit" {
    _write_mock_shed '{"ok": true, "diagnostics": [], "error": null}'
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.json")"
    echo '{}' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently when shed returns ok:true for Write" {
    _write_mock_shed '{"ok": true, "diagnostics": [], "error": null}'
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.py")"
    echo 'pass' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Write" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently for no-tool-registered response" {
    _write_mock_shed '{"ok": true, "diagnostics": [], "error": "no tool registered for this filetype"}'
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.xyz")"
    echo 'content' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Edit/Write on a bad file: hook must emit systemMessage JSON and exit 2
# ---------------------------------------------------------------------------

@test "hook emits systemMessage JSON and exits 2 for Edit with diagnostics" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.py")"
    echo 'import os' > "$tmpfile"

    # Write mock that embeds the actual file path
    cat > "$HOME/.linter-shed/bin/shed" <<MOCKEOF
#!/usr/bin/env bash
FILE_PATH="\${2:-/tmp/file.py}"
python3 -c "
import json, sys
path = sys.argv[1]
print(json.dumps({
    'ok': False,
    'diagnostics': [
        {'file': path, 'line': 1, 'col': 1,
         'severity': 'warning', 'message': 'F401 import os unused', 'rule': 'F401'}
    ],
    'error': None
}))
" "\$FILE_PATH"
MOCKEOF
    chmod +x "$HOME/.linter-shed/bin/shed"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 2 ]
    local msg
    msg="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('systemMessage',''))" "$output")"
    [ -n "$msg" ]
    [[ "$msg" =~ "linter-shed found" ]]
    [[ "$msg" =~ "Please fix" ]]
}

@test "hook emits systemMessage JSON and exits 2 for Write with diagnostics" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.json")"
    echo '{"broken":}' > "$tmpfile"

    cat > "$HOME/.linter-shed/bin/shed" <<MOCKEOF
#!/usr/bin/env bash
FILE_PATH="\${2:-/tmp/file.json}"
python3 -c "
import json, sys
path = sys.argv[1]
print(json.dumps({
    'ok': False,
    'diagnostics': [
        {'file': path, 'line': 1, 'col': 10,
         'severity': 'error', 'message': 'unexpected token', 'rule': 'syntax'}
    ],
    'error': None
}))
" "\$FILE_PATH"
MOCKEOF
    chmod +x "$HOME/.linter-shed/bin/shed"

    run bash "$HOOK" <<< "$(_build_input "Write" "$tmpfile")"
    [ "$status" -eq 2 ]
    local msg
    msg="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('systemMessage',''))" "$output")"
    [ -n "$msg" ]
    [[ "$msg" =~ "linter-shed found" ]]
}

@test "systemMessage contains file:line:col and severity label" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.sh")"
    echo '#!/bin/bash' > "$tmpfile"

    cat > "$HOME/.linter-shed/bin/shed" <<MOCKEOF
#!/usr/bin/env bash
FILE_PATH="\${2:-/tmp/bad.sh}"
python3 -c "
import json, sys
path = sys.argv[1]
print(json.dumps({
    'ok': False,
    'diagnostics': [
        {'file': path, 'line': 4, 'col': 7,
         'severity': 'warning', 'message': 'Double quote to prevent globbing', 'rule': 'SC2086'}
    ],
    'error': None
}))
" "\$FILE_PATH"
MOCKEOF
    chmod +x "$HOME/.linter-shed/bin/shed"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 2 ]
    local msg
    msg="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('systemMessage',''))" "$output")"
    [[ "$msg" =~ "4:7" ]]
    [[ "$msg" =~ "[WARNING]" ]]
}

@test "systemMessage issue count reflects multiple diagnostics" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.py")"
    echo 'pass' > "$tmpfile"

    cat > "$HOME/.linter-shed/bin/shed" <<MOCKEOF
#!/usr/bin/env bash
FILE_PATH="\${2:-/tmp/bad.py}"
python3 -c "
import json, sys
path = sys.argv[1]
print(json.dumps({
    'ok': False,
    'diagnostics': [
        {'file': path, 'line': 1, 'col': 1, 'severity': 'warning', 'message': 'unused import os',     'rule': 'F401'},
        {'file': path, 'line': 3, 'col': 1, 'severity': 'warning', 'message': 'redefinition of os',   'rule': 'F811'},
        {'file': path, 'line': 5, 'col': 2, 'severity': 'error',   'message': 'missing whitespace',   'rule': 'E225'}
    ],
    'error': None
}))
" "\$FILE_PATH"
MOCKEOF
    chmod +x "$HOME/.linter-shed/bin/shed"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 2 ]
    local msg
    msg="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('systemMessage',''))" "$output")"
    [[ "$msg" =~ "3 issue" ]]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "hook exits 0 silently when file_path is empty string" {
    local input
    input='{"tool_name": "Edit", "tool_input": {"file_path": ""}, "tool_response": {}}'
    run bash "$HOOK" <<< "$input"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently when file_path points to nonexistent file" {
    local input
    input='{"tool_name": "Edit", "tool_input": {"file_path": "/tmp/shed_nonexistent_XXXXX.py"}, "tool_response": {}}'
    run bash "$HOOK" <<< "$input"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently when shed binary is absent" {
    rm -f "$HOME/.linter-shed/bin/shed"
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.py")"
    echo 'import os' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently when shed binary exits non-zero with no output" {
    cat > "$HOME/.linter-shed/bin/shed" <<'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
    chmod +x "$HOME/.linter-shed/bin/shed"

    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.py")"
    echo 'import os' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently when ok:false but diagnostics array is empty" {
    _write_mock_shed '{"ok": false, "diagnostics": [], "error": "internal error"}'
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/file_XXXXXX.py")"
    echo 'import os' > "$tmpfile"

    run bash "$HOOK" <<< "$(_build_input "Edit" "$tmpfile")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently for malformed JSON input" {
    run bash "$HOOK" <<< "not valid json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook exits 0 silently for empty input" {
    run bash "$HOOK" <<< ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# End-to-end: hook with real shed on fixture files (requires tools installed)
# ---------------------------------------------------------------------------

@test "hook end-to-end: emits systemMessage for bad.json via real shed" {
    # @requires-internet
    skip_if_missing npm

    # For this test we restore the real HOME so the hook finds the real shed
    export HOME="$_REAL_HOME"

    # Only run if shed is actually installed in the real ~/.linter-shed
    if [[ ! -x "$HOME/.linter-shed/bin/shed" ]]; then
        skip "real shed binary not installed at $HOME/.linter-shed/bin/shed"
    fi

    run bash "$HOOK" <<< "$(_build_input "Edit" "$FIXTURES_DIR/bad.json")"
    # Should exit 2 with a systemMessage
    [ "$status" -eq 2 ]
    local msg
    msg="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('systemMessage',''))" "$output")"
    [ -n "$msg" ]
    [[ "$msg" =~ "linter-shed found" ]]
}

@test "hook end-to-end: silent for good.json via real shed" {
    # @requires-internet
    skip_if_missing npm

    export HOME="$_REAL_HOME"
    if [[ ! -x "$HOME/.linter-shed/bin/shed" ]]; then
        skip "real shed binary not installed at $HOME/.linter-shed/bin/shed"
    fi

    run bash "$HOOK" <<< "$(_build_input "Edit" "$FIXTURES_DIR/good.json")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
