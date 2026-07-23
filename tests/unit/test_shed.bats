#!/usr/bin/env bats
# Unit tests for shed.sh functions
# Requires bats-core. Run from repo root: bats tests/unit/test_shed.bats

# ---------------------------------------------------------------------------
# Source shed.sh safely
# shed.sh calls `main "$@"` unconditionally at the bottom, so we patch that
# by sourcing after redefining main as a no-op, then restoring.
# ---------------------------------------------------------------------------
_source_shed() {
  # shed.sh has an unconditional `main "$@"` at the bottom which exits 1 when
  # called with no arguments.  We create a patched copy that guards main with
  # a BASH_SOURCE check so it is a no-op when sourced.
  local patched
  patched="$(mktemp "${BATS_TMPDIR}/shed_patched_XXXXXX")"
  # Replace the last line `main "$@"` with a guarded version
  grep -vF 'main "$@"' "${BATS_TEST_DIRNAME}/../../shed.sh" > "${patched}"
  printf '\nif [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi\n' >> "${patched}"
  # shellcheck disable=SC1090
  source "${patched}"
  rm -f "${patched}"
  # shed.sh sets BUNDLED_REGISTRY_DIR relative to SCRIPT_DIR at source time;
  # re-apply the value we want (set in setup()) so runtime calls use the
  # real packages directory.
  BUNDLED_REGISTRY_DIR="${BATS_TEST_DIRNAME}/../../packages"
}

setup() {
  export SHED_DIR="${BATS_TMPDIR}/shed-test-$$-${RANDOM}"
  export VERSIONS_DIR="${SHED_DIR}/versions"
  export SHED_BIN="${SHED_DIR}/bin"
  export TOOLS_DIR="${SHED_DIR}/tools"
  mkdir -p "${VERSIONS_DIR}" "${SHED_BIN}" "${TOOLS_DIR}"
  # Per-test scratch dir for temp files (macOS mktemp has no suffix support)
  export TEST_TMP="${SHED_DIR}/tmp"
  mkdir -p "${TEST_TMP}"

  # Point at the real packages directory
  export BUNDLED_REGISTRY_DIR="${BATS_TEST_DIRNAME}/../../packages"

  _source_shed
}

teardown() {
  rm -rf "${SHED_DIR}"
}

# ===========================================================================
# SECTION 1: find_tool_for_file
# ===========================================================================

@test "find_tool_for_file: json file matches jsonlint" {
  run find_tool_for_file "foo.json"
  [ "$status" -eq 0 ]
  [ "$output" = "jsonlint" ]
}

@test "find_tool_for_file: yaml file matches prettier" {
  # prettier (p) sorts before yamllint (y) in the real registry, so it wins
  run find_tool_for_file "foo.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "prettier" ]
}

@test "find_tool_for_file: yml file matches prettier" {
  run find_tool_for_file "config.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "prettier" ]
}

@test "find_tool_for_file: py file matches ruff" {
  run find_tool_for_file "main.py"
  [ "$status" -eq 0 ]
  [ "$output" = "ruff" ]
}

@test "find_tool_for_file: pyi file matches ruff" {
  run find_tool_for_file "stubs.pyi"
  [ "$status" -eq 0 ]
  [ "$output" = "ruff" ]
}

@test "find_tool_for_file: sh file matches shellcheck" {
  run find_tool_for_file "script.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "shellcheck" ]
}

@test "find_tool_for_file: bash file matches shellcheck" {
  run find_tool_for_file "helpers.bash"
  [ "$status" -eq 0 ]
  [ "$output" = "shellcheck" ]
}

@test "find_tool_for_file: bats file matches shellcheck" {
  run find_tool_for_file "test.bats"
  [ "$status" -eq 0 ]
  [ "$output" = "shellcheck" ]
}

@test "find_tool_for_file: github workflow yaml matches actionlint not prettier" {
  # actionlint (a) sorts before prettier (p), and its pattern is more specific
  # (.github/workflows/*.yaml vs *.yaml). The suffix-path logic means actionlint
  # wins for workflow files even though prettier also matches *.yaml.
  run find_tool_for_file "/home/user/project/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "actionlint" ]
}

@test "find_tool_for_file: github workflow yml matches actionlint" {
  run find_tool_for_file "/home/user/project/.github/workflows/release.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "actionlint" ]
}

@test "find_tool_for_file: relative .github/workflows path matches actionlint" {
  run find_tool_for_file ".github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "actionlint" ]
}

@test "find_tool_for_file: root level yaml does not match actionlint" {
  # A plain yaml file should not match actionlint's .github/workflows/*.yaml pattern
  run find_tool_for_file "myfile.yaml"
  [ "$status" -eq 0 ]
  [ "$output" != "actionlint" ]
  [ -n "$output" ]
}

@test "find_tool_for_file: yaml in non-workflow subdir does not match actionlint" {
  run find_tool_for_file "/project/config/myfile.yaml"
  [ "$status" -eq 0 ]
  [ "$output" != "actionlint" ]
  [ -n "$output" ]
}

@test "find_tool_for_file: unknown extension returns empty output" {
  run find_tool_for_file "report.xyz"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find_tool_for_file: no extension returns empty output" {
  run find_tool_for_file "Makefile"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find_tool_for_file: nested path json still matches jsonlint" {
  run find_tool_for_file "/a/b/c/data.json"
  [ "$status" -eq 0 ]
  [ "$output" = "jsonlint" ]
}

# ===========================================================================
# SECTION 2: parse_package_yaml
# ===========================================================================

@test "parse_package_yaml: simple key-value fields" {
  local f
  f="$(mktemp "${TEST_TMP}/pkg_XXXXXX")"
  printf 'name: mytool\nversion: "1.2.3"\nsource: pkg:npm/foo\n' > "${f}"

  run parse_package_yaml "${f}"
  [ "$status" -eq 0 ]

  local name version src
  name="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])")"
  version="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['version'])")"
  src="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['source'])")"

  [ "$name" = "mytool" ]
  [ "$version" = "1.2.3" ]
  [ "$src" = "pkg:npm/foo" ]
}

@test "parse_package_yaml: list field filetypes" {
  local f
  f="$(mktemp "${TEST_TMP}/pkg_XXXXXX")"
  printf 'name: mytool\nfiletypes:\n  - "*.json"\n  - "*.jsonc"\n' > "${f}"

  run parse_package_yaml "${f}"
  [ "$status" -eq 0 ]

  local ft
  ft="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['filetypes']))")"
  [ "$ft" = '["*.json", "*.jsonc"]' ]
}

@test "parse_package_yaml: nested dict platforms block" {
  local f
  f="$(mktemp "${TEST_TMP}/pkg_XXXXXX")"
  printf 'name: mytool\nplatforms:\n  linux/amd64:\n    asset: foo.tar.gz\n    binary: foo/bar\n' > "${f}"

  run parse_package_yaml "${f}"
  [ "$status" -eq 0 ]

  local asset binary
  asset="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['platforms']['linux/amd64']['asset'])")"
  binary="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['platforms']['linux/amd64']['binary'])")"

  [ "$asset" = "foo.tar.gz" ]
  [ "$binary" = "foo/bar" ]
}

@test "parse_package_yaml: comments and blank lines ignored" {
  local f
  f="$(mktemp "${TEST_TMP}/pkg_XXXXXX")"
  printf '# this is a comment\nname: mytool\n\n# another comment\nversion: "2.0.0"\n' > "${f}"

  run parse_package_yaml "${f}"
  [ "$status" -eq 0 ]

  local name version
  name="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])")"
  version="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['version'])")"

  [ "$name" = "mytool" ]
  [ "$version" = "2.0.0" ]
  # comment content should not appear as a key
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert 'this is a comment' not in d" "$output"
}

@test "parse_package_yaml: double-quoted values strip quotes" {
  local f
  f="$(mktemp "${TEST_TMP}/pkg_XXXXXX")"
  printf 'name: "shellcheck"\n' > "${f}"

  run parse_package_yaml "${f}"
  [ "$status" -eq 0 ]

  local name
  name="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])")"
  [ "$name" = "shellcheck" ]
}

@test "parse_package_yaml: single-quoted values strip quotes" {
  local f
  f="$(mktemp "${TEST_TMP}/pkg_XXXXXX")"
  printf "name: 'mytool'\n" > "${f}"

  run parse_package_yaml "${f}"
  [ "$status" -eq 0 ]

  local name
  name="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])")"
  [ "$name" = "mytool" ]
}

@test "parse_package_yaml: real shellcheck package.yaml parses correctly" {
  run parse_package_yaml "${BUNDLED_REGISTRY_DIR}/shellcheck/package.yaml"
  [ "$status" -eq 0 ]

  local name version asset binary
  name="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])")"
  version="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['version'])")"
  asset="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['platforms']['linux/amd64']['asset'])")"
  binary="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['platforms']['linux/amd64']['binary'])")"

  [ "$name" = "shellcheck" ]
  [ "$version" = "0.11.0" ]
  [ "$asset" = "shellcheck-v0.11.0.linux.x86_64.tar.gz" ]
  [ "$binary" = "shellcheck-v0.11.0/shellcheck" ]
}

@test "parse_package_yaml: real actionlint package.yaml darwin arm64 platform" {
  run parse_package_yaml "${BUNDLED_REGISTRY_DIR}/actionlint/package.yaml"
  [ "$status" -eq 0 ]

  local asset
  asset="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['platforms']['darwin/arm64']['asset'])")"
  [ "$asset" = "actionlint_1.7.12_darwin_arm64.tar.gz" ]
}

@test "parse_package_yaml: missing key returns null or absent" {
  local f
  f="$(mktemp "${TEST_TMP}/pkg_XXXXXX")"
  printf 'name: notool\nsource: pkg:npm/notool\n' > "${f}"

  run parse_package_yaml "${f}"
  [ "$status" -eq 0 ]

  # version key should be absent (null) since it was not specified
  local version_val
  version_val="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version', 'ABSENT'))")"
  [ "$version_val" = "ABSENT" ]
}

# ===========================================================================
# SECTION 3: parse_jsonlint
# ===========================================================================

@test "parse_jsonlint: valid JSON exit 0 produces ok true" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_jsonlint "foo.json" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok diag_count
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"
  [ "$ok" = "True" ]
  [ "$diag_count" = "0" ]
}

@test "parse_jsonlint: invalid JSON exit 1 extracts line and col" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'Error: Parse error on line 3, column 5: unexpected token\n' > "${stderr_f}"

  run parse_jsonlint "foo.json" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local ok line col rule
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  line="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['line'])")"
  col="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['col'])")"
  rule="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['rule'])")"

  [ "$ok" = "False" ]
  [ "$line" = "3" ]
  [ "$col" = "5" ]
  [ "$rule" = "syntax" ]
}

@test "parse_jsonlint: error message without column defaults col to 0" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'Error: something bad at line 7\n' > "${stderr_f}"

  run parse_jsonlint "foo.json" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local line col
  line="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['line'])")"
  col="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['col'])")"

  [ "$line" = "7" ]
  [ "$col" = "0" ]
}

@test "parse_jsonlint: error with no line number defaults both to 0" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'Error: bad JSON\n' > "${stderr_f}"

  run parse_jsonlint "foo.json" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local line col
  line="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['line'])")"
  col="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['col'])")"

  [ "$line" = "0" ]
  [ "$col" = "0" ]
}

@test "parse_jsonlint: stderr preferred over stdout for message" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf 'some stdout text\n' > "${stdout_f}"
  printf 'Error: real error at line 2 column 1\n' > "${stderr_f}"

  run parse_jsonlint "foo.json" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local message
  message="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['message'])")"
  [[ "$message" == *"real error"* ]]
  [[ "$message" != *"some stdout"* ]]
}

@test "parse_jsonlint: exit 0 with nonempty stdout still ok" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf 'OK\n' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_jsonlint "foo.json" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  [ "$ok" = "True" ]
}

# ===========================================================================
# SECTION 4: parse_yamllint
# ===========================================================================

@test "parse_yamllint: clean file exit 0" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_yamllint "foo.yaml" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok diag_count
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"
  [ "$ok" = "True" ]
  [ "$diag_count" = "0" ]
}

@test "parse_yamllint: single error finding" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf 'foo.yaml:3:2: [error] wrong indentation (indentation)\n' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_yamllint "foo.yaml" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local ok line col severity rule message
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  line="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['line'])")"
  col="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['col'])")"
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['severity'])")"
  message="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['message'])")"
  rule="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['rule'])")"

  [ "$ok" = "False" ]
  [ "$line" = "3" ]
  [ "$col" = "2" ]
  [ "$severity" = "error" ]
  [ "$message" = "wrong indentation" ]
  [ "$rule" = "indentation" ]
}

@test "parse_yamllint: single warning finding" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf 'foo.yaml:5:1: [warning] missing document start (document-start)\n' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_yamllint "foo.yaml" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local severity rule
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['severity'])")"
  rule="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['rule'])")"

  [ "$severity" = "warning" ]
  [ "$rule" = "document-start" ]
}

@test "parse_yamllint: multiple findings" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf 'foo.yaml:3:2: [error] wrong indentation (indentation)\nfoo.yaml:5:1: [warning] missing document start (document-start)\n' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_yamllint "foo.yaml" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local diag_count
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"
  [ "$diag_count" = "2" ]
}

@test "parse_yamllint: exit 2 sets error field" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'internal error: config file not found\n' > "${stderr_f}"

  run parse_yamllint "foo.yaml" "${stdout_f}" "${stderr_f}" "2"
  [ "$status" -eq 0 ]

  local ok error diag_count
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  error="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['error'])")"
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"

  [ "$ok" = "False" ]
  [ "$diag_count" = "0" ]
  [[ "$error" != "None" ]]
  [[ "$error" != "" ]]
}

@test "parse_yamllint: stderr used for exit 2 error message" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'config error: invalid option\n' > "${stderr_f}"

  run parse_yamllint "foo.yaml" "${stdout_f}" "${stderr_f}" "2"
  [ "$status" -eq 0 ]

  local error
  error="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['error'])")"
  [[ "$error" == *"config error"* ]]
}

# ===========================================================================
# SECTION 5: parse_shellcheck_json
# ===========================================================================

_shellcheck_fixture() {
  cat <<'EOF'
[
  {"file":"script.sh","line":10,"column":5,"level":"error","message":"var is undefined","code":2154},
  {"file":"script.sh","line":20,"column":1,"level":"info","message":"tip: use quotes","code":2086},
  {"file":"script.sh","line":30,"column":3,"level":"warning","message":"prefer local","code":2034}
]
EOF
}

@test "parse_shellcheck_json: no findings exit 0" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '[]' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok diag_count
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"
  [ "$ok" = "True" ]
  [ "$diag_count" = "0" ]
}

@test "parse_shellcheck_json: error level maps to error severity" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _shellcheck_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local severity
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['severity'])")"
  [ "$severity" = "error" ]
}

@test "parse_shellcheck_json: info level maps to warning severity" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _shellcheck_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local severity
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][1]['severity'])")"
  [ "$severity" = "warning" ]
}

@test "parse_shellcheck_json: warning level stays warning" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _shellcheck_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local severity
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][2]['severity'])")"
  [ "$severity" = "warning" ]
}

@test "parse_shellcheck_json: rule is SC-prefixed code" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _shellcheck_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local rule
  rule="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['rule'])")"
  [ "$rule" = "SC2154" ]
}

@test "parse_shellcheck_json: exit 2 is error" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'shellcheck: internal error\n' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "2"
  [ "$status" -eq 0 ]

  local ok error
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  error="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['error'])")"
  [ "$ok" = "False" ]
  [[ "$error" != "None" ]]
}

@test "parse_shellcheck_json: malformed JSON stdout" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf 'not json\n' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local ok
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  [ "$ok" = "False" ]
}

@test "parse_shellcheck_json: empty stdout treated as empty array" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_shellcheck_json "script.sh" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok diag_count
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"
  [ "$ok" = "True" ]
  [ "$diag_count" = "0" ]
}

# ===========================================================================
# SECTION 6: parse_ruff_json
# ===========================================================================

_ruff_fixture() {
  cat <<'EOF'
[
  {"filename":"main.py","location":{"row":5,"column":3},"message":"undefined name 'foo'","code":"F821","fix":null},
  {"filename":"main.py","location":{"row":8,"column":1},"message":"line too long","code":"E501","fix":{"message":"shorten"}}
]
EOF
}

@test "parse_ruff_json: no findings" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '[]' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_ruff_json "main.py" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  [ "$ok" = "True" ]
}

@test "parse_ruff_json: fix null maps to severity error" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _ruff_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_ruff_json "main.py" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local severity
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['severity'])")"
  [ "$severity" = "error" ]
}

@test "parse_ruff_json: fix present maps to severity warning" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _ruff_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_ruff_json "main.py" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local severity
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][1]['severity'])")"
  [ "$severity" = "warning" ]
}

@test "parse_ruff_json: rule field is code" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _ruff_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_ruff_json "main.py" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local rule
  rule="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['rule'])")"
  [ "$rule" = "F821" ]
}

@test "parse_ruff_json: line and col from location.row and column" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _ruff_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_ruff_json "main.py" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local line col
  line="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['line'])")"
  col="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['col'])")"
  [ "$line" = "5" ]
  [ "$col" = "3" ]
}

@test "parse_ruff_json: exit 2 is error" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'ruff: fatal error\n' > "${stderr_f}"

  run parse_ruff_json "main.py" "${stdout_f}" "${stderr_f}" "2"
  [ "$status" -eq 0 ]

  local ok error
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  error="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['error'])")"
  [ "$ok" = "False" ]
  [[ "$error" != "None" ]]
}

@test "parse_ruff_json: malformed JSON" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '{bad}\n' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_ruff_json "main.py" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local ok
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  [ "$ok" = "False" ]
}

# ===========================================================================
# SECTION 7: parse_actionlint_json
# ===========================================================================

_actionlint_fixture() {
  cat <<'EOF'
[
  {"filepath":".github/workflows/ci.yaml","line":12,"column":5,"message":"'runs-on' is required","kind":"syntax-check"},
  {"filepath":".github/workflows/ci.yaml","line":25,"column":1,"message":"unknown action","kind":"action"}
]
EOF
}

@test "parse_actionlint_json: empty array exit 0" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '[]' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_actionlint_json ".github/workflows/ci.yaml" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok diag_count
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"
  [ "$ok" = "True" ]
  [ "$diag_count" = "0" ]
}

@test "parse_actionlint_json: findings parsed correctly" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _actionlint_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_actionlint_json ".github/workflows/ci.yaml" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local line col severity rule
  line="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['line'])")"
  col="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['col'])")"
  severity="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['severity'])")"
  rule="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['rule'])")"

  [ "$line" = "12" ]
  [ "$col" = "5" ]
  [ "$severity" = "error" ]
  [ "$rule" = "syntax-check" ]
}

@test "parse_actionlint_json: file field from filepath" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _actionlint_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_actionlint_json ".github/workflows/ci.yaml" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local file_field
  file_field="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['diagnostics'][0]['file'])")"
  [ "$file_field" = ".github/workflows/ci.yaml" ]
}

@test "parse_actionlint_json: multiple findings" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  _actionlint_fixture > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_actionlint_json ".github/workflows/ci.yaml" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local diag_count
  diag_count="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['diagnostics']))")"
  [ "$diag_count" = "2" ]
}

@test "parse_actionlint_json: exit 2 is error" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf 'actionlint: cannot open file\n' > "${stderr_f}"

  run parse_actionlint_json ".github/workflows/ci.yaml" "${stdout_f}" "${stderr_f}" "2"
  [ "$status" -eq 0 ]

  local ok error
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  error="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['error'])")"
  [ "$ok" = "False" ]
  [[ "$error" != "None" ]]
}

@test "parse_actionlint_json: malformed JSON" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf 'not json\n' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_actionlint_json ".github/workflows/ci.yaml" "${stdout_f}" "${stderr_f}" "1"
  [ "$status" -eq 0 ]

  local ok
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  [ "$ok" = "False" ]
}

@test "parse_actionlint_json: empty stdout treated as no findings" {
  local stdout_f stderr_f
  stdout_f="$(mktemp "${TEST_TMP}/stdout_XXXXXX")"
  stderr_f="$(mktemp "${TEST_TMP}/stderr_XXXXXX")"
  printf '' > "${stdout_f}"
  printf '' > "${stderr_f}"

  run parse_actionlint_json ".github/workflows/ci.yaml" "${stdout_f}" "${stderr_f}" "0"
  [ "$status" -eq 0 ]

  local ok
  ok="$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ok'])")"
  [ "$ok" = "True" ]
}

# ===========================================================================
# SECTION 8: version helpers
# ===========================================================================

@test "version helpers: write then read round-trips version" {
  write_installed_version "mytool" "1.2.3"
  run read_installed_version "mytool"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3" ]
}

@test "version helpers: read missing tool returns empty string" {
  run read_installed_version "nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "version helpers: write creates versions dir if missing" {
  rm -rf "${VERSIONS_DIR}"
  write_installed_version "mytool" "1.0.0"
  [ -f "${VERSIONS_DIR}/mytool" ]
  run read_installed_version "mytool"
  [ "$output" = "1.0.0" ]
}

@test "version helpers: write overwrites existing version" {
  write_installed_version "mytool" "1.0"
  write_installed_version "mytool" "2.0"
  run read_installed_version "mytool"
  [ "$status" -eq 0 ]
  [ "$output" = "2.0" ]
}

@test "version helpers: version file contains trailing newline" {
  write_installed_version "mytool" "1.2.3"
  local raw
  raw="$(cat "${VERSIONS_DIR}/mytool")"
  # cat strips the newline, but the file itself must have ended with one
  # Verify by checking the raw byte count includes a newline
  local bytecount
  bytecount="$(wc -c < "${VERSIONS_DIR}/mytool" | tr -d ' ')"
  # "1.2.3\n" = 6 bytes
  [ "$bytecount" = "6" ]
}

@test "version helpers: version with special chars round-trips" {
  write_installed_version "mytool" "0.11.0-rc1"
  run read_installed_version "mytool"
  [ "$status" -eq 0 ]
  [ "$output" = "0.11.0-rc1" ]
}

# ===========================================================================
# SECTION 9: cmd_list
# ===========================================================================

@test "cmd_list: header row present" {
  run cmd_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOOL"* ]]
  [[ "$output" == *"INSTALLED"* ]]
  [[ "$output" == *"REGISTRY"* ]]
  [[ "$output" == *"STATUS"* ]]
}

@test "cmd_list: separator row present" {
  run cmd_list
  [ "$status" -eq 0 ]
  local second_line
  second_line="$(echo "$output" | sed -n '2p')"
  [[ "$second_line" == *"----"* ]]
}

@test "cmd_list: not installed shows dash and status not installed" {
  # Ensure no version file for jsonlint
  rm -f "${VERSIONS_DIR}/jsonlint"
  run cmd_list
  [ "$status" -eq 0 ]
  local jsonlint_line
  jsonlint_line="$(echo "$output" | grep '^jsonlint')"
  [[ "$jsonlint_line" == *"-"* ]]
  [[ "$jsonlint_line" == *"not installed"* ]]
}

@test "cmd_list: current version shows current status" {
  local registry_ver
  registry_ver="$(parse_package_yaml "${BUNDLED_REGISTRY_DIR}/yamllint/package.yaml" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['version'])")"
  write_installed_version "yamllint" "${registry_ver}"

  run cmd_list
  [ "$status" -eq 0 ]
  local yamllint_line
  yamllint_line="$(echo "$output" | grep '^yamllint')"
  [[ "$yamllint_line" == *"current"* ]]
}

@test "cmd_list: outdated version shows outdated status" {
  write_installed_version "ruff" "0.0.1"
  run cmd_list
  [ "$status" -eq 0 ]
  local ruff_line
  ruff_line="$(echo "$output" | grep '^ruff')"
  [[ "$ruff_line" == *"outdated"* ]]
}

@test "cmd_list: all registered tools appear" {
  run cmd_list
  [ "$status" -eq 0 ]
  # Count data rows: total lines minus 2 header lines
  local data_rows
  data_rows="$(echo "$output" | tail -n +3 | grep -c '.')"
  # We have 11 packages in the real packages dir
  local pkg_count
  pkg_count="$(find "${BUNDLED_REGISTRY_DIR}" -name "package.yaml" | wc -l | tr -d ' ')"
  [ "$data_rows" = "$pkg_count" ]
}

@test "cmd_list: tool name column is fixed width 22 chars" {
  run cmd_list
  [ "$status" -eq 0 ]
  # Format: printf '%-22s %-14s %-14s %s\n'
  # Positions 1-22: tool name (left-justified, space-padded to 22)
  # Position 23: literal space separator between columns
  # Position 24+: INSTALLED value
  local ruff_line
  ruff_line="$(echo "$output" | grep '^ruff')"
  # chars 1-22 should be "ruff" padded to 22 chars
  local name_field
  name_field="$(echo "$ruff_line" | cut -c1-22)"
  [ "$name_field" = "ruff                  " ]
  # char 23 is the inter-column space
  local char23
  char23="$(echo "$ruff_line" | cut -c23)"
  [ "$char23" = " " ]
}
