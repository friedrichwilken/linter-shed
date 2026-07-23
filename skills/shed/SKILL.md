---
name: shed
description: >
  Run linter-shed commands: list installed tools, install a linter, update
  all tools, or check a file. Trigger phrases: "shed list", "shed install",
  "shed update", "shed check", "run linters", "run shed".
argument-hint: "list | install <tool> | update | check <file>"
user-invocable: true
allowed-tools:
  - Bash(~/.linter-shed/bin/shed *)
  - Bash(which shed)
---

# shed

Dispatch the user's `shed` subcommand, show output clearly, and surface any
errors with actionable remediation advice.

## Input

The user invokes `/shed` with an optional subcommand and arguments:

- `/shed list` -- list all installed tools and their versions
- `/shed install <tool>` -- install a named linter/tool
- `/shed update` -- update all installed tools to their latest versions
- `/shed check <file>` -- run all applicable linters against a specific file
- `/shed` with no arguments -- show usage

`shed check` is also invoked automatically via hook after file edits.

## Validation

1. Check that `shed` is available:

```bash
which shed
```

If not found, print:

```
shed is not installed or not on PATH.
Install it from: https://github.com/friedrichwilken/linter-shed
Then re-invoke this skill.
```

Do not proceed further.

2. For `install`, require exactly one `<tool>` argument. If missing, print:

```
Usage: /shed install <tool>
Example: /shed install ruff

Available tools: actionlint, golangci-lint, hadolint, jsonlint, luacheck, markdownlint-cli2, prettier, ruff, shellcheck, taplo, yamllint
```

3. For `check`, require exactly one `<file>` argument. If missing, print:

```
Usage: /shed check <file>
Example: /shed check src/main.py
```

## Execution

Run the appropriate command:

- `list` -- `~/.linter-shed/bin/shed list`
- `install <tool>` -- `~/.linter-shed/bin/shed install <tool>`
- `update` -- `~/.linter-shed/bin/shed update`
- `check <file>` -- `~/.linter-shed/bin/shed check <file>`
- no args or unrecognized -- `~/.linter-shed/bin/shed --help`

## Output handling

Print the raw output from `shed` verbatim in a fenced `text` block.

If the exit code is non-zero:
- Extract and highlight the error message.
- Suggest the most likely fix: missing config file, unknown tool name,
  unsupported file type, network error during install, etc.

If `shed update` reports tools that changed, summarize: tool name,
previous version, new version.

If `shed check` reports lint failures, present a compact table:

| Tool | File | Line | Message |
|------|------|------|---------|

Do not attempt to auto-fix unless the user explicitly asks. When the user
does ask to fix, apply the fixes with the Edit tool and re-run `shed check`
on the affected files to confirm clean output.
