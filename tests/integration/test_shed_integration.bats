#!/usr/bin/env bats
# Integration tests for shed.sh -- full pipeline against real fixture files.
#
# Run from repo root:
#   bats tests/integration/test_shed_integration.bats
#
# Notes:
#   - All tests share one SHED_DIR per file (set up in setup_file).
#     Tools installed by one test are available to subsequent tests.
#   - Tests tagged "# @requires-internet" download binaries on first run.
#   - BUNDLED_REGISTRY_DIR points at the repo's own packages/ dir so
#     maybe_update_registry is a no-op (no git clone needed).

load '../helpers/common'

setup_file() {
    export SHED_REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
    export SHED="${SHED_REPO_ROOT}/shed.sh"
    export FIXTURES_DIR="${SHED_REPO_ROOT}/tests/fixtures"
    export SHED_DIR="${BATS_FILE_TMPDIR}/shed"
    export BUNDLED_REGISTRY_DIR="${SHED_REPO_ROOT}/packages"
    export SHED_QUIET=1
    mkdir -p "${SHED_DIR}"
    date +%s > "${SHED_DIR}/last-checked"
}

teardown_file() {
    rm -rf "${SHED_DIR:-/nonexistent}"
}

setup() {
    export SHED_REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
    export SHED="${SHED_REPO_ROOT}/shed.sh"
    export FIXTURES_DIR="${SHED_REPO_ROOT}/tests/fixtures"
    export BUNDLED_REGISTRY_DIR="${SHED_REPO_ROOT}/packages"
    export SHED_QUIET=1
    # Re-export SHED_DIR in case setup_file exports didn't propagate
    export SHED_DIR="${BATS_FILE_TMPDIR}/shed"
    mkdir -p "${SHED_DIR}"
    if [[ ! -f "${SHED_DIR}/last-checked" ]]; then
        date +%s > "${SHED_DIR}/last-checked"
    fi
}

teardown() {
    :
}

# ---------------------------------------------------------------------------
# shed list
# ---------------------------------------------------------------------------

@test "shed list exits 0" {
    run bash "$SHED" list
    [ "$status" -eq 0 ]
}

@test "shed list prints column headers" {
    run bash "$SHED" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "TOOL" ]]
    [[ "$output" =~ "INSTALLED" ]]
    [[ "$output" =~ "REGISTRY" ]]
    [[ "$output" =~ "STATUS" ]]
}

@test "shed list shows known tools" {
    run bash "$SHED" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "jsonlint" ]]
    [[ "$output" =~ "ruff" ]]
    [[ "$output" =~ "shellcheck" ]]
    [[ "$output" =~ "yamllint" ]]
    [[ "$output" =~ "actionlint" ]]
}

@test "shed list shows 'not installed' for fresh SHED_DIR" {
    run bash "$SHED" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "not installed" ]]
}

@test "shed list marks jsonlint as 'current' after installation" {
    # @requires-internet
    skip_if_missing npm
    bash "$SHED" install jsonlint >/dev/null 2>&1
    run bash "$SHED" list
    [ "$status" -eq 0 ]
    local jsonlint_line
    jsonlint_line="$(echo "$output" | grep 'jsonlint')"
    [[ "$jsonlint_line" =~ "current" ]]
    [[ ! "$jsonlint_line" =~ "not installed" ]]
}

# ---------------------------------------------------------------------------
# shed check: unknown extension
# ---------------------------------------------------------------------------

@test "shed check unknown extension returns ok:true with no-tool error" {
    local tmpfile
    tmpfile="$(mktemp "${BATS_TEST_TMPDIR}/unknown_XXXXXX.xyz")"
    echo "some content" > "$tmpfile"

    run bash "$SHED" check "$tmpfile"

    [ "$status" -eq 0 ]
    assert_json_ok "$output"
    assert_json_field "$output" "error" "no tool registered for this filetype"
}

# ---------------------------------------------------------------------------
# shed check: JSON (jsonlint)
# ---------------------------------------------------------------------------

@test "shed check bad.json returns ok:false with syntax diagnostic" {
    # @requires-internet
    skip_if_missing npm

    run bash "$SHED" check "$FIXTURES_DIR/bad.json"
    [ "$status" -eq 0 ]
    assert_json_has_diagnostics "$output"
    assert_json_field "$output" "ok" "False"
    # Rule must be 'syntax'
    python3 -c "
import sys, json
d = json.loads(sys.argv[1])
assert d['diagnostics'][0]['rule'] == 'syntax', 'expected rule=syntax, got: ' + str(d['diagnostics'][0].get('rule'))
assert d['diagnostics'][0]['line'] > 0, 'line must be > 0'
assert d['diagnostics'][0]['severity'] == 'error'
" "$output"
}

@test "shed check good.json returns ok:true with empty diagnostics" {
    # @requires-internet
    skip_if_missing npm

    run bash "$SHED" check "$FIXTURES_DIR/good.json"
    [ "$status" -eq 0 ]
    assert_json_ok "$output"
    python3 -c "
import sys, json
d = json.loads(sys.argv[1])
assert len(d['diagnostics']) == 0
assert d['error'] is None
" "$output"
}

# ---------------------------------------------------------------------------
# shed check: YAML (yamllint)
# ---------------------------------------------------------------------------

@test "shed check bad.yaml returns ok:false with yamllint diagnostics" {
    # @requires-internet (installs yamllint via pip)
    skip_if_missing python3

    run bash "$SHED" check "$FIXTURES_DIR/bad.yaml"
    [ "$status" -eq 0 ]
    assert_json_field "$output" "ok" "False"
    assert_json_has_diagnostics "$output"
    python3 -c "
import sys, json
d = json.loads(sys.argv[1])
for item in d['diagnostics']:
    assert item['severity'] in ('error', 'warning'), 'unexpected severity: ' + item['severity']
    assert item['line'] > 0, 'line must be > 0'
    assert item['col'] > 0, 'col must be > 0'
    for key in ('file', 'line', 'col', 'severity', 'message', 'rule'):
        assert key in item, 'missing key: ' + key
" "$output"
}

@test "shed check good.yaml returns ok:true" {
    # @requires-internet
    skip_if_missing python3

    run bash "$SHED" check "$FIXTURES_DIR/good.yaml"
    [ "$status" -eq 0 ]
    assert_json_ok "$output"
    python3 -c "
import sys, json
d = json.loads(sys.argv[1])
assert len(d['diagnostics']) == 0
" "$output"
}

# ---------------------------------------------------------------------------
# shed check: shell (shellcheck)
# ---------------------------------------------------------------------------

@test "shed check bad.sh returns shellcheck diagnostics including SC2086" {
    # @requires-internet (downloads shellcheck binary)
    run bash "$SHED" check "$FIXTURES_DIR/bad.sh"
    [ "$status" -eq 0 ]
    assert_json_field "$output" "ok" "False"
    assert_json_has_diagnostics "$output"
    python3 -c "
import sys, json, os
d = json.loads(sys.argv[1])
rules = [item.get('rule', '') for item in d['diagnostics']]
assert any('SC2086' in r for r in rules), 'SC2086 not found in: ' + str(rules)
for item in d['diagnostics']:
    assert os.path.basename(item['file']) == 'bad.sh', 'unexpected file: ' + item['file']
    for key in ('file', 'line', 'col', 'severity', 'message', 'rule'):
        assert key in item, 'missing key: ' + key
" "$output"
}

# ---------------------------------------------------------------------------
# shed check: Python (ruff)
# ---------------------------------------------------------------------------

@test "shed check bad.py returns ruff diagnostics with F or E-code rules" {
    # @requires-internet (downloads ruff binary)
    run bash "$SHED" check "$FIXTURES_DIR/bad.py"
    [ "$status" -eq 0 ]
    assert_json_field "$output" "ok" "False"
    assert_json_has_diagnostics "$output"
    python3 -c "
import sys, json
d = json.loads(sys.argv[1])
rules = [item.get('rule', '') for item in d['diagnostics']]
assert any(r.startswith('F') or r.startswith('E') for r in rules), \
    'expected at least one F/E rule, got: ' + str(rules)
for item in d['diagnostics']:
    for key in ('file', 'line', 'col', 'severity', 'message', 'rule'):
        assert key in item, 'missing key: ' + key
" "$output"
}

@test "shed check good.py returns ok:true" {
    # @requires-internet
    run bash "$SHED" check "$FIXTURES_DIR/good.py"
    [ "$status" -eq 0 ]
    assert_json_ok "$output"
    python3 -c "
import sys, json
d = json.loads(sys.argv[1])
assert len(d['diagnostics']) == 0
" "$output"
}

# ---------------------------------------------------------------------------
# shed check: GitHub Actions workflow (actionlint, not yamllint)
# ---------------------------------------------------------------------------

@test "shed check .github/workflows/bad.yml dispatches to actionlint not yamllint" {
    # @requires-internet (downloads actionlint binary)
    run bash "$SHED" check "$FIXTURES_DIR/.github/workflows/bad.yml"
    [ "$status" -eq 0 ]
    assert_json_field "$output" "ok" "False"
    assert_json_has_diagnostics "$output"
    python3 -c "
import sys, json
d = json.loads(sys.argv[1])
# actionlint always sets severity=error
for item in d['diagnostics']:
    assert item['severity'] == 'error', 'expected error, got: ' + item['severity']
# actionlint rules are kind strings; yamllint uses rule names like wrong-indentation
yamllint_rules = {'wrong-indentation', 'key-duplicates', 'new-line-at-end-of-file',
                  'trailing-spaces', 'document-start', 'line-length', 'comments'}
rules = {item.get('rule', '') for item in d['diagnostics']}
overlap = rules & yamllint_rules
assert not overlap, 'got yamllint rules -- wrong tool dispatched: ' + str(overlap)
" "$output"
}

# ---------------------------------------------------------------------------
# shed install
# ---------------------------------------------------------------------------

@test "shed install jsonlint creates binary and version file" {
    # @requires-internet
    skip_if_missing npm

    run bash "$SHED" install jsonlint
    [ "$status" -eq 0 ]

    [ -e "$SHED_DIR/bin/jsonlint" ]
    local target
    target="$(python3 -c "import os,sys; p=sys.argv[1]; print(os.path.realpath(p))" "$SHED_DIR/bin/jsonlint")"
    [ -x "$target" ]

    [ -f "$SHED_DIR/versions/jsonlint" ]
    [ -s "$SHED_DIR/versions/jsonlint" ]
    grep -q "1.6.3" "$SHED_DIR/versions/jsonlint"
}

@test "shed install jsonlint is idempotent" {
    # @requires-internet
    skip_if_missing npm

    bash "$SHED" install jsonlint >/dev/null 2>&1
    run bash "$SHED" install jsonlint 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "already up to date" ]]
}

# ---------------------------------------------------------------------------
# shed update
# ---------------------------------------------------------------------------

@test "shed update skips uninstalled tools and exits 0" {
    run bash "$SHED" update
    [ "$status" -eq 0 ]
    [[ "$output" =~ "not installed (skipped)" ]]
}

@test "shed update marks jsonlint as already current when version matches" {
    # @requires-internet
    skip_if_missing npm

    bash "$SHED" install jsonlint >/dev/null 2>&1
    local before
    before="$(cat "$SHED_DIR/versions/jsonlint")"

    run bash "$SHED" update
    [ "$status" -eq 0 ]
    [[ "$output" =~ "already current" ]]
    local after
    after="$(cat "$SHED_DIR/versions/jsonlint")"
    [ "$before" = "$after" ]
}

@test "shed update reinstalls jsonlint when version file is stale" {
    # @requires-internet
    skip_if_missing npm

    bash "$SHED" install jsonlint >/dev/null 2>&1
    echo "1.0.0" > "$SHED_DIR/versions/jsonlint"

    run bash "$SHED" update
    [ "$status" -eq 0 ]
    [[ "$output" =~ "updating" ]]
    ! grep -q "^1\.0\.0$" "$SHED_DIR/versions/jsonlint"
    grep -q "1.6.3" "$SHED_DIR/versions/jsonlint"
}
