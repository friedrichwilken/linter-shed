# linter-shed

[![version](https://img.shields.io/badge/version-0.1.0-blue)](https://github.com/friedrichwilken/linter-shed/releases)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A tool manager and linter runner for Claude Code projects.

## What it does

linter-shed installs and manages linters as isolated binaries -- no global
npm, pip, or brew dependencies required. It tracks which tools are
configured for your project, runs the right linter for each file type, and
integrates with Claude Code so linting happens automatically after edits.

Rather than running `ruff check src/` or `shellcheck scripts/*.sh`
directly, you run `shed check <file>` and shed dispatches to every
applicable linter, collects results, and hands them back in a unified
format Claude can act on.

## Install

### Step 1 -- install the `shed` CLI

```bash
curl -fsSL https://raw.githubusercontent.com/friedrichwilken/linter-shed/main/install.sh | sh
```

Binaries are placed in `~/.linter-shed/bin/`. Add to PATH:

```bash
export PATH="$HOME/.linter-shed/bin:$PATH"
```

### Step 2 -- add the Claude Code plugin

Add linter-shed as a marketplace and install the plugin:

```
/plugin marketplace add https://github.com/friedrichwilken/linter-shed.git
/plugin install linter-shed@linter-shed
```

This adds the `/shed` slash command and installs a post-edit hook that
runs `shed check` automatically whenever Claude edits a file.

## Usage -- `/shed`

| Subcommand | What it does | Example |
|---|---|---|
| `list` | Show installed tools and versions | `/shed list` |
| `install <tool>` | Install a linter by name | `/shed install ruff` |
| `update` | Update all installed tools to latest | `/shed update` |
| `check <file>` | Run applicable linters on a file | `/shed check src/main.py` |

`shed check` is also triggered automatically via hook after each file edit.
You can invoke it manually to re-check a file without making changes.

## Supported tools

| Tool | Language / type | What it checks |
|---|---|---|
| `ruff` | Python | Linting and formatting (replaces flake8, isort, black) |
| `shellcheck` | Shell scripts | Correctness, portability, best practices |
| `actionlint` | GitHub Actions | Workflow syntax, expression types, shellcheck integration |
| `golangci-lint` | Go | Aggregates 100+ Go linters in a single fast pass |
| `hadolint` | Dockerfile | Best practices, base image pinning, shell warnings |
| `yamllint` | YAML | Syntax, indentation, line length, duplicate keys |
| `jsonlint` | JSON | Syntax and well-formedness |
| `taplo` | TOML | Formatting, schema validation |
| `markdownlint-cli2` | Markdown / MDX | Style, heading structure, link validity |
| `prettier` | JS, TS, CSS, HTML, JSON, YAML, Markdown | Formatting |
| `luacheck` | Lua | Static analysis, undefined globals, unused variables |

Tool selection is automatic: shed reads the file extension and dispatches
to the best matching tool. When multiple tools match (e.g. both `prettier`
and `yamllint` handle `*.yaml`), the most specific pattern wins; ties go
to the tool that sorts last alphabetically.

**Note:** `prettier` wins for `*.json`, `*.yaml`, `*.yml`, `*.md`, `*.ts`,
`*.js` -- it checks formatting correctness. `yamllint` handles `*.yaml`
when prettier is not installed. `actionlint` always wins for
`.github/workflows/*.yaml` regardless of prettier.

## How it works

1. Claude edits a file.
2. The post-edit hook runs `shed check <file>`.
3. shed looks up the file extension against each installed package's
   `filetypes` list and runs the matching tools.
4. Failures are returned to Claude as structured output.
5. Claude proposes fixes; you approve and the cycle repeats until clean.

## Adding tools

Package definitions live in `packages/<name>/package.yaml`. To add a new
linter, create a package file following the same schema:

```yaml
name: my-linter
description: What it checks
source: pkg:github/owner/repo   # or pkg:npm/name or pkg:pypi/name
version: "1.2.3"
filetypes:
  - "*.ext"
bin:
  my-linter: my-linter
platforms:
  linux/amd64:
    asset: my-linter_linux_amd64.tar.gz
    binary: my-linter
  darwin/arm64:
    asset: my-linter_darwin_arm64.tar.gz
    binary: my-linter
```

Then open a PR. No code changes required for tools distributed as
pre-built binaries.

## Configuration

By default shed stores tools in `~/.linter-shed/`. Override with:

```bash
export LINTER_SHED_DIR=/path/to/custom/dir
```

Per-project configuration lives in `.shed.toml` at the repo root:

```toml
[tools]
# Pin specific versions per project
ruff = "0.11.13"
shellcheck = "0.11.0"

[check]
# Extra args passed to a tool when shed check runs it
ruff = ["--select", "ALL", "--ignore", "D"]
```

If `.shed.toml` is absent, shed uses the versions pinned in each
`packages/<name>/package.yaml` and the tool's default configuration.

## Updating the plugin

When a new version of linter-shed is released, update the marketplace
cache and reinstall:

```
/plugin marketplace update linter-shed
```

This pulls the latest `marketplace.json` and `plugin.json`, then upgrades
the `/shed` skill and any hooks in place.

## Development

```bash
git clone https://github.com/friedrichwilken/linter-shed.git
cd linter-shed

# Test locally by pointing Claude Code at your working copy
/plugin marketplace add /path/to/linter-shed
/plugin install linter-shed@linter-shed

# Bump version before opening a PR
# -- update .claude-plugin/plugin.json  (version field)
# -- update .claude-plugin/marketplace.json  (plugins[0].version field)
# Both must stay in sync.
```

Open a pull request against `main`. CI runs `shed check` on the repo
itself -- all tools must pass before merge.

## License

MIT -- see [LICENSE](LICENSE).
