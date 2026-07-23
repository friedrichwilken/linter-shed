#!/usr/bin/env bash
# shed.sh — linter-shed dispatcher
# Usage: shed.sh check <file>
#        shed.sh install <tool>
#        shed.sh update

set -euo pipefail

SHED_DIR="${LINTER_SHED_DIR:-$HOME/.linter-shed}"
SHED_BIN="$SHED_DIR/bin"
SHED_REGISTRY="$SHED_DIR/registry"
SHED_LOCK="$SHED_DIR/shed.lock"
SHED_LAST_CHECKED="$SHED_DIR/last-checked"
SHED_REPO="${LINTER_SHED_REPO:-https://github.com/I549741/linter-shed.git}"
UPDATE_INTERVAL_SECONDS=86400  # 24h

mkdir -p "$SHED_BIN" "$SHED_REGISTRY"

# --- helpers -----------------------------------------------------------------

log()  { echo "[shed] $*" >&2; }
fail() { echo "[shed] error: $*" >&2; exit 1; }

with_lock() {
    local timeout=5
    (
        flock -w "$timeout" 9 || { log "could not acquire lock, skipping"; exit 0; }
        "$@"
    ) 9>"$SHED_LOCK"
}

os_arch() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac
    echo "${os}_${arch}"
}

# --- registry ----------------------------------------------------------------

registry_path() {
    # If running from the repo itself (dev mode), use packages/ sibling
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/packages" ]]; then
        echo "$script_dir/packages"
    else
        echo "$SHED_REGISTRY/packages"
    fi
}

maybe_update_registry() {
    local reg_packages
    reg_packages="$(registry_path)"

    # If packages dir doesn't exist yet, clone
    if [[ ! -d "$reg_packages" ]]; then
        log "cloning registry..."
        git clone --depth=1 "$SHED_REPO" "$SHED_REGISTRY"
        date +%s > "$SHED_LAST_CHECKED"
        return
    fi

    # Throttle to once per UPDATE_INTERVAL_SECONDS
    if [[ -f "$SHED_LAST_CHECKED" ]]; then
        local last now
        last=$(cat "$SHED_LAST_CHECKED")
        now=$(date +%s)
        if (( now - last < UPDATE_INTERVAL_SECONDS )); then
            return
        fi
    fi

    log "checking for registry updates..."
    git -C "$SHED_REGISTRY" pull --ff-only --quiet 2>/dev/null || true
    date +%s > "$SHED_LAST_CHECKED"
}

# --- tool resolution ---------------------------------------------------------

find_tool_for_file() {
    local file="$1"
    local reg_packages
    reg_packages="$(registry_path)"

    [[ -d "$reg_packages" ]] || fail "registry not found at $reg_packages"

    for pkg_yaml in "$reg_packages"/*/package.yaml; do
        local tool_name filetypes
        tool_name=$(grep '^name:' "$pkg_yaml" | awk '{print $2}')

        # Read filetypes block (simple line-by-line, no yq dependency)
        local in_filetypes=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^filetypes: ]]; then
                in_filetypes=1
                continue
            fi
            if [[ $in_filetypes -eq 1 ]]; then
                if [[ "$line" =~ ^[a-z] ]]; then
                    in_filetypes=0
                    break
                fi
                local pattern
                pattern=$(echo "$line" | sed 's/.*- "//' | sed 's/"//' | tr -d "'" | xargs)
                if matches_pattern "$file" "$pattern"; then
                    echo "$tool_name"
                    return 0
                fi
            fi
        done < "$pkg_yaml"
    done

    return 1
}

matches_pattern() {
    local file="$1" pattern="$2"
    # Use bash glob matching
    case "$file" in
        $pattern) return 0 ;;
        */$pattern) return 0 ;;
    esac
    # Also match basename
    local base
    base=$(basename "$file")
    case "$base" in
        $pattern) return 0 ;;
    esac
    return 1
}

# --- install -----------------------------------------------------------------

install_tool() {
    local tool="$1"
    local reg_packages
    reg_packages="$(registry_path)"
    local pkg_yaml="$reg_packages/$tool/package.yaml"

    [[ -f "$pkg_yaml" ]] || fail "unknown tool: $tool (no package.yaml found)"

    log "installing $tool..."

    local source_id
    source_id=$(grep 'id:' "$pkg_yaml" | head -1 | sed 's/.*id: //' | xargs)

    if [[ "$source_id" == pkg:npm/* ]]; then
        local pkg version
        pkg=$(echo "$source_id" | sed 's|pkg:npm/||' | cut -d@ -f1)
        version=$(echo "$source_id" | cut -d@ -f2)
        npm install -g "${pkg}@${version}" --prefix "$SHED_DIR" 2>&1 | tail -3
        # npm installs to $SHED_DIR/bin automatically
    elif [[ "$source_id" == pkg:pypi/* ]]; then
        local pkg version
        pkg=$(echo "$source_id" | sed 's|pkg:pypi/||' | cut -d@ -f1)
        version=$(echo "$source_id" | cut -d@ -f2)
        pip install --quiet "${pkg}==${version}" --target "$SHED_DIR/pylib" 2>&1 | tail -3
        # Create wrapper in bin
        cat > "$SHED_BIN/$tool" <<EOF
#!/usr/bin/env bash
PYTHONPATH="$SHED_DIR/pylib" exec python3 -m $pkg "\$@"
EOF
        chmod +x "$SHED_BIN/$tool"
    elif [[ "$source_id" == pkg:github/* ]]; then
        install_github_release "$tool" "$pkg_yaml" "$source_id"
    else
        fail "unsupported source type for $tool: $source_id"
    fi

    log "$tool installed → $SHED_BIN/$tool"
}

install_github_release() {
    local tool="$1" pkg_yaml="$2" source_id="$3"
    local target
    target=$(os_arch)

    # Find matching asset for current platform
    local in_asset=0 current_target="" file_template="" bin_name=""
    while IFS= read -r line; do
        if [[ "$line" =~ "- target:" ]]; then
            current_target=$(echo "$line" | sed 's/.*target: //' | xargs)
            in_asset=1
        elif [[ $in_asset -eq 1 && "$line" =~ "file:" ]]; then
            file_template=$(echo "$line" | sed 's/.*file: //' | tr -d '"' | xargs)
        elif [[ $in_asset -eq 1 && "$line" =~ "bin:" ]]; then
            bin_name=$(echo "$line" | sed 's/.*bin: //' | xargs)
            if [[ "$current_target" == "$target" ]]; then
                break
            fi
            in_asset=0
        fi
    done < "$pkg_yaml"

    [[ -n "$file_template" ]] || fail "no asset found for platform $target in $tool"

    local repo version
    repo=$(echo "$source_id" | sed 's|pkg:github/||' | cut -d@ -f1)
    version=$(echo "$source_id" | cut -d@ -f2 | sed 's/^v//')
    local file
    file=$(echo "$file_template" | sed "s/{{version}}/v${version}/g")

    local url="https://github.com/${repo}/releases/download/v${version}/${file}"
    local tmpdir
    tmpdir=$(mktemp -d)

    log "downloading $file..."
    curl -fsSL "$url" -o "$tmpdir/$file"

    if [[ "$file" == *.tar.gz || "$file" == *.tar.xz ]]; then
        tar -xf "$tmpdir/$file" -C "$tmpdir"
    elif [[ "$file" == *.zip ]]; then
        unzip -q "$tmpdir/$file" -d "$tmpdir"
    fi

    local bin_path
    bin_path=$(find "$tmpdir" -name "$bin_name" -type f | head -1)
    [[ -n "$bin_path" ]] || fail "binary $bin_name not found in archive"

    install -m 0755 "$bin_path" "$SHED_BIN/$tool"
    rm -rf "$tmpdir"
}

is_installed() {
    local tool="$1"
    [[ -x "$SHED_BIN/$tool" ]] || command -v "$tool" &>/dev/null
}

ensure_installed() {
    local tool="$1"
    if ! is_installed "$tool"; then
        with_lock install_tool "$tool"
    fi
}

# --- run & parse -------------------------------------------------------------

run_linter() {
    local tool="$1" file="$2"
    local output exit_code=0

    # Ensure bin dir is on PATH
    export PATH="$SHED_BIN:$PATH"

    case "$tool" in
        jsonlint)
            output=$(jsonlint --compact "$file" 2>&1) || exit_code=$?
            parse_jsonlint "$file" "$output" "$exit_code"
            ;;
        yamllint)
            output=$(yamllint -f parsable "$file" 2>&1) || exit_code=$?
            parse_yamllint "$file" "$output" "$exit_code"
            ;;
        shellcheck)
            output=$(shellcheck -f json "$file" 2>&1) || exit_code=$?
            parse_shellcheck "$output" "$exit_code"
            ;;
        actionlint)
            output=$(actionlint -format '{{range $e := .}}{{$e.Filepath}}:{{$e.Line}}:{{$e.Col}}:error:{{$e.Message}}\n{{end}}' "$file" 2>&1) || exit_code=$?
            parse_generic "$file" "$output" "$exit_code"
            ;;
        ruff)
            output=$(ruff check --output-format=json "$file" 2>&1) || exit_code=$?
            parse_ruff "$output" "$exit_code"
            ;;
        *)
            fail "no parser for tool: $tool"
            ;;
    esac
}

parse_jsonlint() {
    local file="$1" output="$2" exit_code="$3"
    if [[ $exit_code -eq 0 ]]; then
        echo '{"ok":true,"diagnostics":[]}'
        return
    fi
    # jsonlint output: "Error: Parse error on line N: ..."
    local line msg
    line=$(echo "$output" | grep -oP 'line \K[0-9]+' | head -1)
    msg=$(echo "$output" | head -1)
    printf '{"ok":false,"diagnostics":[{"file":"%s","line":%s,"col":1,"severity":"error","message":"%s"}]}\n' \
        "$file" "${line:-1}" "$(echo "$msg" | sed 's/"/\\"/g')"
}

parse_yamllint() {
    local file="$1" output="$2" exit_code="$3"
    if [[ $exit_code -eq 0 ]]; then
        echo '{"ok":true,"diagnostics":[]}'
        return
    fi
    # parsable format: file:line:col: [level] message
    local diags="[]"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local f l c sev msg
        f=$(echo "$line" | cut -d: -f1)
        l=$(echo "$line" | cut -d: -f2)
        c=$(echo "$line" | cut -d: -f3)
        sev=$(echo "$line" | grep -oP '\[(error|warning)\]' | tr -d '[]')
        msg=$(echo "$line" | sed 's/.*\[.*\] //' | sed 's/"/\\"/g')
        diags=$(echo "$diags" | sed "s/\]$/,{\"file\":\"$f\",\"line\":$l,\"col\":$c,\"severity\":\"${sev:-error}\",\"message\":\"$msg\"}]/")
    done <<< "$output"
    diags=$(echo "$diags" | sed 's/^\[,/[/')
    printf '{"ok":false,"diagnostics":%s}\n' "$diags"
}

parse_shellcheck() {
    local output="$1" exit_code="$2"
    if [[ $exit_code -eq 0 ]]; then
        echo '{"ok":true,"diagnostics":[]}'
        return
    fi
    # shellcheck -f json already outputs JSON array
    local diags
    diags=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
out = []
for d in data:
    out.append({
        'file': d.get('file',''),
        'line': d.get('line', 1),
        'col': d.get('column', 1),
        'severity': d.get('level', 'error'),
        'message': d.get('message','')
    })
print(json.dumps(out))
")
    printf '{"ok":false,"diagnostics":%s}\n' "$diags"
}

parse_generic() {
    local file="$1" output="$2" exit_code="$3"
    if [[ $exit_code -eq 0 ]]; then
        echo '{"ok":true,"diagnostics":[]}'
        return
    fi
    # file:line:col:severity:message
    local diags="[]"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local f l c sev msg
        f=$(echo "$line" | cut -d: -f1)
        l=$(echo "$line" | cut -d: -f2)
        c=$(echo "$line" | cut -d: -f3)
        sev=$(echo "$line" | cut -d: -f4)
        msg=$(echo "$line" | cut -d: -f5- | sed 's/"/\\"/g')
        diags=$(echo "$diags" | sed "s/\]$/,{\"file\":\"$f\",\"line\":$l,\"col\":$c,\"severity\":\"${sev:-error}\",\"message\":\"$msg\"}]/")
    done <<< "$output"
    diags=$(echo "$diags" | sed 's/^\[,/[/')
    printf '{"ok":false,"diagnostics":%s}\n' "$diags"
}

parse_ruff() {
    local output="$1" exit_code="$2"
    if [[ $exit_code -eq 0 ]]; then
        echo '{"ok":true,"diagnostics":[]}'
        return
    fi
    local diags
    diags=$(echo "$output" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except:
    print('[]')
    sys.exit(0)
out = []
for d in data:
    loc = d.get('location', {})
    out.append({
        'file': d.get('filename',''),
        'line': loc.get('row', 1),
        'col': loc.get('column', 1),
        'severity': 'error' if d.get('fix') is None else 'warning',
        'message': '[' + d.get('code','') + '] ' + d.get('message','')
    })
print(json.dumps(out))
")
    printf '{"ok":false,"diagnostics":%s}\n' "$diags"
}

# --- commands ----------------------------------------------------------------

cmd_check() {
    local file="$1"
    [[ -f "$file" ]] || fail "file not found: $file"

    with_lock maybe_update_registry

    local tool
    tool=$(find_tool_for_file "$file") || {
        echo '{"ok":true,"diagnostics":[],"skipped":true}'
        return 0
    }

    ensure_installed "$tool"
    run_linter "$tool" "$file"
}

cmd_install() {
    local tool="$1"
    with_lock maybe_update_registry
    with_lock install_tool "$tool"
}

cmd_update() {
    with_lock maybe_update_registry
    log "registry up to date"
}

cmd_list() {
    local reg_packages
    reg_packages="$(registry_path)"
    for pkg_yaml in "$reg_packages"/*/package.yaml; do
        local name installed
        name=$(grep '^name:' "$pkg_yaml" | awk '{print $2}')
        if is_installed "$name"; then
            installed="✓"
        else
            installed=" "
        fi
        printf "[%s] %s\n" "$installed" "$name"
    done
}

# --- main --------------------------------------------------------------------

CMD="${1:-help}"
shift || true

case "$CMD" in
    check)   cmd_check "${1:-}" ;;
    install) cmd_install "${1:-}" ;;
    update)  cmd_update ;;
    list)    cmd_list ;;
    *)
        echo "Usage: shed.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  check <file>    run the appropriate linter and return JSON diagnostics"
        echo "  install <tool>  install a tool from the registry"
        echo "  update          pull latest registry"
        echo "  list            show available tools and install status"
        ;;
esac
