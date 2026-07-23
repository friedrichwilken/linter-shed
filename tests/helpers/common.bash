# tests/helpers/common.bash
# Shared helpers for linter-shed bats tests.
# Load with: load '../helpers/common'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Absolute path to the linter-shed repo root (two levels up from helpers/).
SHED_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHED_SH="${SHED_REPO_ROOT}/shed.sh"

# ---------------------------------------------------------------------------
# Test isolation: SHED_DIR
# ---------------------------------------------------------------------------

# setup_test_shed_dir: create a fresh, isolated SHED_DIR under BATS_TEST_TMPDIR
# and export both SHED_DIR and BUNDLED_REGISTRY_DIR so shed.sh picks them up.
#
# Call this from your test's setup() function:
#
#   setup() {
#     load '../helpers/common'
#     setup_test_shed_dir
#   }
#
setup_test_shed_dir() {
  export SHED_DIR="${BATS_TEST_TMPDIR}/shed"
  mkdir -p "${SHED_DIR}"
  # Point BUNDLED_REGISTRY_DIR at the real packages/ directory so unit tests
  # can read package metadata without a network call.
  export BUNDLED_REGISTRY_DIR="${SHED_REPO_ROOT}/packages"
}

# teardown_test_shed_dir: remove the test SHED_DIR.
# Call this from your test's teardown() function.
# Guard requires the path ends in /shed to prevent accidental broad rm -rf.
teardown_test_shed_dir() {
  if [[ -n "${SHED_DIR:-}" && "${SHED_DIR}" == */shed ]]; then
    rm -rf "${SHED_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# JSON assertions
# ---------------------------------------------------------------------------

# assert_json_ok: assert that OUTPUT is valid JSON with "ok": true.
#
# Usage (inside a @test):
#   run bash shed.sh check some/file.yaml
#   assert_json_ok "$output"
#
assert_json_ok() {
  local json="$1"
  local ok
  ok="$(python3 -c "import sys, json; d=json.loads(sys.argv[1]); print(d.get('ok', False))" "${json}" 2>/dev/null)" \
    || { echo "assert_json_ok: failed to parse JSON: ${json}" >&3; return 1; }
  if [[ "${ok}" != "True" ]]; then
    echo "assert_json_ok: expected ok=true, got: ${json}" >&3
    return 1
  fi
}

# assert_json_has_diagnostics: assert that OUTPUT is valid JSON and that the
# "diagnostics" array is non-empty (i.e. the linter found at least one issue).
#
assert_json_has_diagnostics() {
  local json="$1"
  local count
  count="$(python3 -c "import sys, json; d=json.loads(sys.argv[1]); print(len(d.get('diagnostics', [])))" "${json}" 2>/dev/null)" \
    || { echo "assert_json_has_diagnostics: failed to parse JSON: ${json}" >&3; return 1; }
  if [[ "${count}" -eq 0 ]]; then
    echo "assert_json_has_diagnostics: expected non-empty diagnostics, got: ${json}" >&3
    return 1
  fi
}

# assert_json_field: assert that a top-level field in JSON equals an expected
# value (string comparison after Python str()).
#
# Usage:
#   assert_json_field "$output" "error" "null"
#   assert_json_field "$output" "ok" "False"
#
assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local actual
  actual="$(python3 -c "import sys, json; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2]))" \
            "${json}" "${field}" 2>/dev/null)" \
    || { echo "assert_json_field: failed to parse JSON: ${json}" >&3; return 1; }
  if [[ "${actual}" != "${expected}" ]]; then
    echo "assert_json_field: field '${field}': expected '${expected}', got '${actual}'" >&3
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------

# mock_shed_binary: create a fake 'shed' binary in a temporary directory and
# prepend that directory to PATH. The binary prints the given JSON string and
# exits 0.
#
# Usage:
#   mock_shed_binary '{"ok":true,"diagnostics":[],"error":null}'
#
# The mock directory is stored in MOCK_BIN_DIR; callers can clean it up with
# rm -rf "${MOCK_BIN_DIR}" or simply let BATS handle temp cleanup.
#
mock_shed_binary() {
  local json_response="$1"
  MOCK_BIN_DIR="$(mktemp -d "${BATS_TEST_TMPDIR}/mock_bin_XXXXXX")"
  cat > "${MOCK_BIN_DIR}/shed" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${json_response}'
EOF
  chmod +x "${MOCK_BIN_DIR}/shed"
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

# ---------------------------------------------------------------------------
# Conditional skipping
# ---------------------------------------------------------------------------

# skip_if_missing: skip the current test if a required command is not in PATH.
#
# Usage:
#   skip_if_missing npm
#   skip_if_missing python3
#
skip_if_missing() {
  local cmd="$1"
  if ! command -v "${cmd}" &>/dev/null; then
    skip "required command not found: ${cmd}"
  fi
}
