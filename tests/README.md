# linter-shed tests

## Requirements

- [bats-core](https://github.com/bats-core/bats-core) -- test runner (`npm install -g bats`)
- `python3` -- required by shed itself
- `npm` -- required for integration tests (jsonlint, prettier, markdownlint-cli2)

### Install bats-core

macOS:
```sh
npm install -g bats
# or: brew install bats-core
```

Ubuntu / Debian:
```sh
npm install -g bats
# or: apt install bats
```

From source (any platform):
```sh
git clone https://github.com/bats-core/bats-core.git
cd bats-core && ./install.sh /usr/local
```

## Running tests

### All unit tests

```sh
bats tests/unit/
```

### All integration tests

```sh
bats tests/integration/
```

Integration tests install real linter tools into `SHED_DIR` on first run, so
they require internet access and take longer. Tools requiring internet are
tagged `# @requires-internet` and are skipped automatically when the required
package manager (npm, python3) is not found.

### A single test file

```sh
bats tests/unit/test_shed.bats
```

### A single test by name

```sh
bats --filter "parse_yamllint: clean file" tests/unit/test_shed.bats
```

## Isolating tests from your real installation

By default shed uses `~/.linter-shed`. Set `SHED_DIR` to a temporary path to
avoid touching your real installation:

```sh
SHED_DIR=/tmp/shed-test bats tests/unit/
```

The `setup_test_shed_dir` helper in `tests/helpers/common.bash` does this
automatically for every test that calls it: it creates a fresh directory under
`$BATS_TEST_TMPDIR` and exports `SHED_DIR` for the duration of the test.
The `teardown_test_shed_dir` helper removes the directory on test exit; it
guards against accidental broad `rm -rf` by requiring the path ends in `/shed`.

## Directory layout

```
tests/
  README.md               this file
  helpers/
    common.bash           shared setup/teardown helpers and assertions
  unit/                   fast tests -- no network, no real tool installs
    test_shed.bats        72 tests covering shed.sh functions
  integration/            slow tests -- installs real tools, needs npm/python3
    test_shed_integration.bats  end-to-end shed check/install/update/list
    test_hook.bats              post-edit.sh hook behavior
  fixtures/               sample files used as linter inputs
    bad.json              invalid JSON (syntax error line 4)
    good.json             valid JSON
    bad.yaml              indentation + duplicate key errors (yamllint)
    good.yaml             clean YAML
    bad.sh                SC2086 unquoted variables (shellcheck)
    good.sh               clean bash, all expansions quoted
    bad.py                F811/F401/E225 violations (ruff)
    good.py               clean Python module
    .github/workflows/
      bad.yml             actionlint injection + type errors
      good.yml            minimal valid workflow
```
