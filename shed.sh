#!/usr/bin/env bash
# shed.sh — linter-shed dispatcher
# Manages linter installation and execution via a unified interface.
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants and paths
# ---------------------------------------------------------------------------
SHED_DIR="${SHED_DIR:-${HOME}/.linter-shed}"
SHED_BIN="${SHED_DIR}/bin"
REGISTRY_DIR="${SHED_DIR}/registry"
LOCK_PATH="${SHED_DIR}/shed.lock"
VERSIONS_DIR="${SHED_DIR}/versions"
TOOLS_DIR="${SHED_DIR}/tools"
LAST_CHECKED_PATH="${SHED_DIR}/last-checked"
REGISTRY_TTL=86400  # 24h in seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLED_REGISTRY_DIR="${SCRIPT_DIR}/packages"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
die() {
  echo "shed: error: $*" >&2
  exit 1
}

log() {
  [[ -n "${SHED_QUIET:-}" ]] && return 0
  echo "shed: $*" >&2
}

# ---------------------------------------------------------------------------
# Process safety: lock and trap
# ---------------------------------------------------------------------------
# Use flock on Linux; fall back to mkdir-based lock on macOS (no flock).
_LOCK_DIR="${SHED_DIR}.lock.d"

acquire_lock() {
  mkdir -p "${SHED_DIR}"
  if command -v flock &>/dev/null; then
    exec 9>"${LOCK_PATH}"
    flock -n 9 || die "shed already running (lock: ${LOCK_PATH})"
  else
    # Clean up stale lock from a dead process
    if [[ -f "${_LOCK_DIR}/pid" ]]; then
      local lock_pid
      lock_pid="$(cat "${_LOCK_DIR}/pid" 2>/dev/null)"
      if [[ -n "${lock_pid}" ]] && ! kill -0 "${lock_pid}" 2>/dev/null; then
        rm -rf "${_LOCK_DIR}"
      fi
    fi
    local deadline=$(( $(date +%s) + 5 ))
    until mkdir "${_LOCK_DIR}" 2>/dev/null; do
      [[ $(date +%s) -lt $deadline ]] || die "shed already running (lock: ${_LOCK_DIR})"
      sleep 0.1
    done
    echo $$ > "${_LOCK_DIR}/pid"
  fi
}

release_lock() {
  if command -v flock &>/dev/null; then
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "${LOCK_PATH}"
  else
    rm -rf "${_LOCK_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# Version file helpers
# ---------------------------------------------------------------------------
read_installed_version() {
  local tool="$1"
  local vfile="${VERSIONS_DIR}/${tool}"
  if [[ -f "${vfile}" ]]; then
    head -1 "${vfile}"
  else
    echo ""
  fi
}

write_installed_version() {
  local tool="$1"
  local version="$2"
  # Strip any newlines — version must be a single line
  version="$(printf '%s' "${version}" | head -1 | tr -d '\r\n')"
  mkdir -p "${VERSIONS_DIR}"
  printf '%s\n' "${version}" > "${VERSIONS_DIR}/${tool}"
}

# ---------------------------------------------------------------------------
# Registry management
# ---------------------------------------------------------------------------
# The registry is the packages/ directory (one YAML per tool).
# We use Python3 to parse YAML-like package files.
# Format: simple key: value pairs and indented lists.

# Parse a package.yaml file into a JSON object using Python3.
# Usage: parse_package_yaml <filepath>
parse_package_yaml() {
  local filepath="$1"
  python3 - "${filepath}" <<'PYEOF'
import sys, json, re, os

filepath = sys.argv[1]
with open(filepath) as f:
    content = f.read()

result = {}
current_key = None
current_list = None
current_dict_key = None
current_nested = None

lines = content.splitlines()
i = 0
while i < len(lines):
    line = lines[i]
    # Skip empty lines and comments
    if not line.strip() or line.strip().startswith('#'):
        i += 1
        continue

    indent = len(line) - len(line.lstrip())

    if indent == 0:
        # Top-level key: value or key: (list follows)
        m = re.match(r'^(\w[\w-]*):\s*(.*)', line)
        if m:
            current_key = m.group(1)
            raw = m.group(2).strip()
            # Preserve explicitly-quoted empty strings (e.g. tag_prefix: "")
            was_quoted = (raw.startswith('"') and raw.endswith('"')) or \
                         (raw.startswith("'") and raw.endswith("'"))
            val = raw.strip('"').strip("'")
            if val or was_quoted:
                result[current_key] = val
                current_list = None
                current_nested = None
            else:
                # Will be a list or dict
                result[current_key] = None
                current_list = None
                current_nested = None
    elif indent == 2:
        if current_key is None:
            i += 1
            continue
        line_stripped = line.strip()
        if line_stripped.startswith('- '):
            # List item
            val = line_stripped[2:].strip().strip('"').strip("'")
            if result.get(current_key) is None:
                result[current_key] = []
            if isinstance(result[current_key], list):
                result[current_key].append(val)
            current_nested = None
        else:
            # Nested dict key -- regex allows linux/amd64 style keys
            m = re.match(r'^(\S[\w/.-]*):\s*(.*)', line_stripped)
            if m:
                nested_key = m.group(1)
                nested_val = m.group(2).strip().strip('"').strip("'")
                if result.get(current_key) is None:
                    result[current_key] = {}
                if isinstance(result[current_key], dict):
                    if nested_val:
                        result[current_key][nested_key] = nested_val
                    else:
                        result[current_key][nested_key] = {}
                    current_dict_key = nested_key
                    current_nested = current_key
    elif indent == 4:
        if current_nested is None or current_dict_key is None:
            i += 1
            continue
        line_stripped = line.strip()
        m = re.match(r'^(\S[\w/.-]*):\s*(.*)', line_stripped)
        if m:
            k = m.group(1)
            v = m.group(2).strip().strip('"').strip("'")
            if isinstance(result.get(current_nested), dict):
                if isinstance(result[current_nested].get(current_dict_key), dict):
                    result[current_nested][current_dict_key][k] = v
    i += 1

print(json.dumps(result))
PYEOF
}

# Load all packages from the packages directory into a single JSON registry.
# Outputs JSON: {"tools": {"toolname": {...}, ...}}
load_registry() {
  local pkgs_dir="${1:-${BUNDLED_REGISTRY_DIR}}"
  python3 - "${pkgs_dir}" <<'PYEOF'
import sys, json, os, re

pkgs_dir = sys.argv[1]
registry = {"tools": {}}

for entry in sorted(os.listdir(pkgs_dir)):
    pkg_file = os.path.join(pkgs_dir, entry, "package.yaml")
    if not os.path.isfile(pkg_file):
        continue
    with open(pkg_file) as f:
        content = f.read()

    result = {}
    current_key = None
    current_dict_key = None
    current_nested = None

    lines = content.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.strip().startswith('#'):
            i += 1
            continue

        indent = len(line) - len(line.lstrip())

        if indent == 0:
            m = re.match(r'^(\w[\w-]*):\s*(.*)', line)
            if m:
                current_key = m.group(1)
                raw = m.group(2).strip()
                was_quoted = (raw.startswith('"') and raw.endswith('"')) or \
                             (raw.startswith("'") and raw.endswith("'"))
                val = raw.strip('"').strip("'")
                if val or was_quoted:
                    result[current_key] = val
                    current_nested = None
                    current_dict_key = None
                else:
                    result[current_key] = None
                    current_nested = None
                    current_dict_key = None
        elif indent == 2:
            if current_key is None:
                i += 1
                continue
            line_stripped = line.strip()
            if line_stripped.startswith('- '):
                val = line_stripped[2:].strip().strip('"').strip("'")
                if result.get(current_key) is None:
                    result[current_key] = []
                if isinstance(result[current_key], list):
                    result[current_key].append(val)
                current_nested = None
                current_dict_key = None
            else:
                # Allow linux/amd64 style keys
                m = re.match(r'^([\w/.\-]+):\s*(.*)', line_stripped)
                if m:
                    nested_key = m.group(1)
                    nested_val = m.group(2).strip().strip('"').strip("'")
                    if result.get(current_key) is None:
                        result[current_key] = {}
                    if isinstance(result[current_key], dict):
                        if nested_val:
                            result[current_key][nested_key] = nested_val
                        else:
                            result[current_key][nested_key] = {}
                        current_dict_key = nested_key
                        current_nested = current_key
        elif indent == 4:
            if current_nested is None or current_dict_key is None:
                i += 1
                continue
            line_stripped = line.strip()
            m = re.match(r'^([\w/.\-]+):\s*(.*)', line_stripped)
            if m:
                k = m.group(1)
                v = m.group(2).strip().strip('"').strip("'")
                if isinstance(result.get(current_nested), dict):
                    if isinstance(result[current_nested].get(current_dict_key), dict):
                        result[current_nested][current_dict_key][k] = v
        i += 1

    tool_name = result.get("name", entry)
    registry["tools"][tool_name] = result

print(json.dumps(registry))
PYEOF
}

# Validate that python3 is available.
check_python3() {
  if ! command -v python3 &>/dev/null; then
    die "python3 is required but not found in PATH"
  fi
}

# maybe_update_registry: in dev mode use bundled packages dir; in installed
# mode refresh from remote if TTL has expired.
maybe_update_registry() {
  # Check if running from inside a git repo (dev mode)
  if git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    # Dev mode: use bundled packages directory, just update last-checked
    log "dev mode: using bundled packages at ${BUNDLED_REGISTRY_DIR}"
    mkdir -p "${SHED_DIR}"
    date +%s > "${LAST_CHECKED_PATH}"
    return 0
  fi

  # Installed mode: check TTL
  local now last_checked
  now="$(date +%s)"
  if [[ -f "${LAST_CHECKED_PATH}" ]]; then
    last_checked="$(cat "${LAST_CHECKED_PATH}")"
  else
    last_checked=0
  fi

  local elapsed=$(( now - last_checked ))
  if (( elapsed < REGISTRY_TTL )); then
    return 0
  fi

  log "registry TTL expired, updating..."
  # If registry dir is a git repo, pull; otherwise skip
  if [[ -d "${REGISTRY_DIR}/.git" ]]; then
    git -C "${REGISTRY_DIR}" pull --quiet || log "warning: registry pull failed, using cached version"
  fi

  printf '%s\n' "${now}" > "${LAST_CHECKED_PATH}"
}

# Get the packages directory to use (dev: bundled, installed: shed dir)
get_packages_dir() {
  if git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    echo "${BUNDLED_REGISTRY_DIR}"
  else
    if [[ -d "${REGISTRY_DIR}" ]]; then
      echo "${REGISTRY_DIR}"
    else
      echo "${BUNDLED_REGISTRY_DIR}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Tool discovery: find_tool_for_file
# ---------------------------------------------------------------------------
# Uses Python3 fnmatch to match a file against tool patterns.
# Evaluates all tools and all patterns; the tool whose matched pattern is
# longest wins (specificity). On a tie, >= ensures the last alphabetically-
# sorted tool wins rather than the first, avoiding systematic alphabetical
# bias.
find_tool_for_file() {
  local file="$1"
  local pkgs_dir
  pkgs_dir="$(get_packages_dir)"

  python3 - "${file}" "${pkgs_dir}" <<'PYEOF'
import sys, os, fnmatch, re

filepath = sys.argv[1]
pkgs_dir = sys.argv[2]

basename = os.path.basename(filepath)

# Build ordered list of (tool_name, patterns)
tools = []
for entry in sorted(os.listdir(pkgs_dir)):
    pkg_file = os.path.join(pkgs_dir, entry, "package.yaml")
    if not os.path.isfile(pkg_file):
        continue
    with open(pkg_file) as f:
        content = f.read()

    name = entry
    filetypes = []
    in_filetypes = False
    for line in content.splitlines():
        m = re.match(r'^name:\s*(.+)', line)
        if m:
            name = m.group(1).strip().strip('"').strip("'")
        if re.match(r'^filetypes:', line):
            in_filetypes = True
            continue
        if in_filetypes:
            lstripped = line.strip()
            if lstripped.startswith('- '):
                filetypes.append(lstripped[2:].strip().strip('"').strip("'"))
            elif lstripped and not lstripped.startswith('#'):
                in_filetypes = False

    tools.append((name, filetypes))

best_tool = ""
best_len = -1

for tool_name, patterns in tools:
    for pattern in patterns:
        matched = False
        # Try full path match first
        if fnmatch.fnmatch(filepath, pattern):
            matched = True
        # Try basename match for simple *.ext patterns (e.g. *.yaml, Dockerfile)
        elif fnmatch.fnmatch(basename, pattern):
            matched = True
        # Try matching path suffix for relative patterns like .github/workflows/*.yaml
        elif not pattern.startswith('*'):
            parts = filepath.split(os.sep)
            pattern_parts = pattern.split('/')
            n = len(pattern_parts)
            if len(parts) >= n:
                suffix = os.sep.join(parts[-n:])
                if fnmatch.fnmatch(suffix, os.sep.join(pattern_parts)):
                    matched = True
        # Try **/X style: match basename against the non-glob suffix
        elif '**' in pattern:
            suffix_pattern = pattern.lstrip('*').lstrip('/')
            if fnmatch.fnmatch(basename, suffix_pattern):
                matched = True

        # Use >= so that on a tie the last tool evaluated wins rather than
        # the first -- avoids systematic alphabetical-order bias for equal-
        # length patterns.
        if matched and len(pattern) >= best_len:
            best_len = len(pattern)
            best_tool = tool_name

print(best_tool)
PYEOF
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux*)  os="linux" ;;
    Darwin*) os="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) os="windows" ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    i386|i686)    arch="386" ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
  echo "${os}/${arch}"
}

# ---------------------------------------------------------------------------
# Installation helpers
# ---------------------------------------------------------------------------

install_npm_tool() {
  local tool="$1"
  local package="$2"
  local version="$3"
  local tool_dir="${TOOLS_DIR}/${tool}"

  log "installing ${tool}@${version} via npm..."
  mkdir -p "${tool_dir}"
  npm install --prefix "${tool_dir}" "${package}@${version}" --save-exact --no-audit --no-fund >&2

  # Symlink all binaries into tool's bin/
  mkdir -p "${tool_dir}/bin"
  if [[ -d "${tool_dir}/node_modules/.bin" ]]; then
    for bin_path in "${tool_dir}/node_modules/.bin/"*; do
      [[ -e "${bin_path}" ]] || continue
      local bin_name
      bin_name="$(basename "${bin_path}")"
      ln -sf "${bin_path}" "${tool_dir}/bin/${bin_name}"
    done
  fi

  # Also symlink to global SHED_BIN
  mkdir -p "${SHED_BIN}"
  for bin_path in "${tool_dir}/bin/"*; do
    [[ -e "${bin_path}" ]] || continue
    local bin_name
    bin_name="$(basename "${bin_path}")"
    ln -sf "${bin_path}" "${SHED_BIN}/${bin_name}"
  done
}

install_pip_tool() {
  local tool="$1"
  local package="$2"
  local version="$3"
  local binary_name="${4:-${tool}}"
  local tool_dir="${TOOLS_DIR}/${tool}"

  log "installing ${tool}==${version} via pip (venv)..."
  mkdir -p "${tool_dir}"

  # Create a dedicated venv per tool
  python3 -m venv "${tool_dir}/venv"
  "${tool_dir}/venv/bin/pip" install --quiet "${package}==${version}"

  # Symlink binary into tool's bin/
  mkdir -p "${tool_dir}/bin"
  local venv_bin="${tool_dir}/venv/bin/${binary_name}"
  if [[ -f "${venv_bin}" ]]; then
    ln -sf "${venv_bin}" "${tool_dir}/bin/${binary_name}"
  else
    # Try to find any new executables in venv/bin
    for f in "${tool_dir}/venv/bin/"*; do
      [[ -x "${f}" && ! -d "${f}" ]] || continue
      local fname
      fname="$(basename "${f}")"
      # Skip python-related executables
      case "${fname}" in
        python*|pip*|activate*|easy_install*|wheel*) continue ;;
      esac
      ln -sf "${f}" "${tool_dir}/bin/${fname}"
    done
  fi

  # Also symlink to global SHED_BIN
  mkdir -p "${SHED_BIN}"
  for bin_path in "${tool_dir}/bin/"*; do
    [[ -e "${bin_path}" ]] || continue
    local bin_name
    bin_name="$(basename "${bin_path}")"
    ln -sf "${bin_path}" "${SHED_BIN}/${bin_name}"
  done
}

install_github_tool() {
  local tool="$1"
  local version="$2"
  local asset="$3"
  local binary_in_archive="$4"  # relative path inside archive, or "." for bare binary
  local download_url="$5"
  local tool_dir="${TOOLS_DIR}/${tool}"
  local bin_name="${6:-${tool}}"

  log "installing ${tool} ${version} from GitHub releases..."
  mkdir -p "${tool_dir}/bin"

  local tmpdir
  tmpdir="$(mktemp -d /tmp/shed_install_XXXXXX)"
  local asset_path="${tmpdir}/${asset}"

  curl -fsSL "${download_url}" -o "${asset_path}"

  # Extract based on extension
  if [[ "${asset}" == *.tar.gz ]] || [[ "${asset}" == *.tgz ]]; then
    tar -xzf "${asset_path}" -C "${tmpdir}"
    if [[ "${binary_in_archive}" == "." ]]; then
      # bare binary named like the asset without extension
      local extracted_name="${asset%.tar.gz}"
      extracted_name="${extracted_name%.tgz}"
      cp "${tmpdir}/${extracted_name}" "${tool_dir}/bin/${bin_name}" 2>/dev/null \
        || cp "${tmpdir}/${tool}" "${tool_dir}/bin/${bin_name}" 2>/dev/null \
        || die "could not find binary in archive ${asset}"
    else
      cp "${tmpdir}/${binary_in_archive}" "${tool_dir}/bin/${bin_name}"
    fi
  elif [[ "${asset}" == *.zip ]]; then
    unzip -q "${asset_path}" -d "${tmpdir}"
    if [[ "${binary_in_archive}" == "." ]]; then
      local bin_name_in_zip="${asset%.zip}"
      cp "${tmpdir}/${bin_name_in_zip}" "${tool_dir}/bin/${bin_name}" 2>/dev/null \
        || cp "${tmpdir}/${tool}" "${tool_dir}/bin/${bin_name}" 2>/dev/null \
        || die "could not find binary in zip ${asset}"
    else
      cp "${tmpdir}/${binary_in_archive}" "${tool_dir}/bin/${bin_name}"
    fi
  elif [[ "${asset}" == *.gz ]]; then
    # Single compressed binary (e.g. taplo)
    gunzip -c "${asset_path}" > "${tool_dir}/bin/${bin_name}"
  else
    # Bare binary (e.g. hadolint)
    cp "${asset_path}" "${tool_dir}/bin/${bin_name}"
  fi

  chmod +x "${tool_dir}/bin/${bin_name}"
  rm -rf "${tmpdir}"

  # Symlink to global SHED_BIN
  mkdir -p "${SHED_BIN}"
  ln -sf "${tool_dir}/bin/${bin_name}" "${SHED_BIN}/${bin_name}"
}

# Build the GitHub release download URL for a tool
github_release_url() {
  local source="$1"   # e.g. pkg:github/rhysd/actionlint
  local version="$2"  # e.g. 1.7.12
  local asset="$3"
  local tag_prefix="${4-v}"  # use ${4-v} not ${4:-v}: empty string is valid

  local repo_path="${source#pkg:github/}"
  local org="${repo_path%%/*}"
  local repo="${repo_path##*/}"

  echo "https://github.com/${org}/${repo}/releases/download/${tag_prefix}${version}/${asset}"
}

# Get asset and binary for current platform from tool info JSON
get_platform_asset() {
  local tool_json="$1"
  local platform="$2"

  python3 - "${tool_json}" "${platform}" <<'PYEOF'
import sys, json

tool_json = sys.argv[1]
platform = sys.argv[2]

tool = json.loads(tool_json)
platforms = tool.get("platforms", {})

if platform in platforms:
    p = platforms[platform]
    print(json.dumps({"asset": p.get("asset",""), "binary": p.get("binary",".")}))
    sys.exit(0)

print("{}")
PYEOF
}

# Install a tool based on its source type
install_tool() {
  local tool="$1"
  local pkgs_dir
  pkgs_dir="$(get_packages_dir)"

  local pkg_file="${pkgs_dir}/${tool}/package.yaml"
  [[ -f "${pkg_file}" ]] || die "unknown tool: ${tool}"

  local tool_json
  tool_json="$(parse_package_yaml "${pkg_file}")"

  local registry_version
  registry_version="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('version',''))" "${tool_json}")"

  local installed_version
  installed_version="$(read_installed_version "${tool}")"

  if [[ -n "${installed_version}" && "${installed_version}" == "${registry_version}" ]]; then
    echo "${tool}: already up to date (${registry_version})"
    return 0
  fi

  if [[ -n "${installed_version}" && "${installed_version}" != "${registry_version}" ]]; then
    log "${tool}: upgrading from ${installed_version} to ${registry_version}"
    # Remove old installation
    rm -rf "${TOOLS_DIR}/${tool}"
  fi

  local source
  source="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('source',''))" "${tool_json}")"

  case "${source}" in
    pkg:npm/*)
      local package="${source#pkg:npm/}"
      install_npm_tool "${tool}" "${package}" "${registry_version}"
      ;;

    pkg:pypi/*)
      local package="${source#pkg:pypi/}"
      local binary_name
      binary_name="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); b=d.get('bin',{}); print(list(b.keys())[0] if b else sys.argv[2])" "${tool_json}" "${tool}")"
      install_pip_tool "${tool}" "${package}" "${registry_version}" "${binary_name}"
      ;;

    pkg:github/*)
      local platform
      platform="$(detect_platform)"

      local platform_info
      platform_info="$(get_platform_asset "${tool_json}" "${platform}")"

      if [[ "${platform_info}" == "{}" ]]; then
        # Check for install_fallback
        local fallback_method
        fallback_method="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('install_fallback',{}).get('method',''))" "${tool_json}")"
        if [[ "${fallback_method}" == "luarocks" ]]; then
          local pkg
          pkg="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('install_fallback',{}).get('package',''))" "${tool_json}")"
          local ver
          ver="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('install_fallback',{}).get('version',''))" "${tool_json}")"
          log "installing ${tool} via luarocks..."
          luarocks install "${pkg}" "${ver}" --local || die "luarocks install failed for ${tool}"
          # luarocks installs to ~/.luarocks/bin
          local luarocks_bin="${HOME}/.luarocks/bin"
          mkdir -p "${TOOLS_DIR}/${tool}/bin" "${SHED_BIN}"
          ln -sf "${luarocks_bin}/${tool}" "${TOOLS_DIR}/${tool}/bin/${tool}"
          ln -sf "${luarocks_bin}/${tool}" "${SHED_BIN}/${tool}"
        else
          die "no package available for platform ${platform} and tool ${tool}"
        fi
      else
        local asset binary_in_archive
        asset="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d['asset'])" "${platform_info}")"
        binary_in_archive="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d['binary'])" "${platform_info}")"

        local bin_name
        bin_name="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); b=d.get('bin',{}); print(list(b.keys())[0] if b else sys.argv[2])" "${tool_json}" "${tool}")"

        local tag_prefix
        tag_prefix="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('tag_prefix','v'))" "${tool_json}")"

        local download_url
        download_url="$(github_release_url "${source}" "${registry_version}" "${asset}" "${tag_prefix}")"

        install_github_tool "${tool}" "${registry_version}" "${asset}" "${binary_in_archive}" "${download_url}" "${bin_name}"
      fi
      ;;

    *)
      die "unsupported source type for ${tool}: ${source}"
      ;;
  esac

  # Capture actual installed version -- strip tool-name prefix to store bare
  # version number. e.g. "ruff 0.11.13" -> "0.11.13"
  local actual_version="${registry_version}"
  local tool_bin="${TOOLS_DIR}/${tool}/bin/${tool}"
  if [[ -x "${tool_bin}" ]]; then
    actual_version="$("${tool_bin}" --version 2>&1 | head -1 \
      | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -1 \
      || echo "${registry_version}")"
    # Fall back to registry_version if grep found nothing
    [[ -n "${actual_version}" ]] || actual_version="${registry_version}"
  fi

  write_installed_version "${tool}" "${actual_version}"
  log "${tool} ${actual_version}: installed successfully"
}

# ---------------------------------------------------------------------------
# Linting execution
# ---------------------------------------------------------------------------
run_linter() {
  local tool="$1"
  local file="$2"

  local tool_dir="${TOOLS_DIR}/${tool}"
  export PATH="${tool_dir}/bin:${SHED_BIN}:${PATH}"

  local tool_bin="${tool_dir}/bin/${tool}"
  if [[ ! -x "${tool_bin}" ]]; then
    python3 -c "
import sys, json
print(json.dumps({'ok': False, 'diagnostics': [], 'error': 'tool binary not found: ' + sys.argv[1]}))
" "${tool_bin}"
    return 0
  fi

  local stdout_file stderr_file exit_code
  stdout_file="$(mktemp /tmp/shed_stdout_XXXXXX)"
  stderr_file="$(mktemp /tmp/shed_stderr_XXXXXX)"

  set +e
  case "${tool}" in
    yamllint)
      "${tool_bin}" -f parsable "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    eslint)
      "${tool_bin}" --format json "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    prettier)
      # --check exits 0 when formatted, 1 when needs formatting, 2 on error
      "${tool_bin}" --check "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    ruff)
      "${tool_bin}" check --output-format json "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    shellcheck)
      "${tool_bin}" --format=json "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    actionlint)
      "${tool_bin}" -format '{{json .}}' "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    jsonlint)
      "${tool_bin}" "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    markdownlint-cli2)
      "${tool_bin}" --config /dev/null "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    hadolint)
      "${tool_bin}" --format json "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    golangci-lint)
      "${tool_bin}" run --out-format json "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    taplo)
      "${tool_bin}" lint "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    luacheck)
      "${tool_bin}" --formatter plain "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
    *)
      "${tool_bin}" "${file}" > "${stdout_file}" 2>"${stderr_file}"
      exit_code=$?
      ;;
  esac
  set -e

  parse_output "${tool}" "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}"
  rm -f "${stdout_file}" "${stderr_file}"
}

get_parse_format() {
  local tool="$1"
  case "${tool}" in
    yamllint)          echo "yamllint" ;;
    eslint)            echo "eslint" ;;
    prettier)          echo "prettier" ;;
    ruff)              echo "ruff_json" ;;
    shellcheck)        echo "shellcheck_json" ;;
    actionlint)        echo "actionlint_json" ;;
    jsonlint)          echo "jsonlint" ;;
    markdownlint-cli2) echo "markdownlint" ;;
    hadolint)          echo "hadolint_json" ;;
    golangci-lint)     echo "golangci_json" ;;
    taplo)             echo "taplo" ;;
    luacheck)          echo "luacheck" ;;
    *)                 echo "generic" ;;
  esac
}

# ---------------------------------------------------------------------------
# Output parsing
# ---------------------------------------------------------------------------
parse_output() {
  local tool="$1"
  local file="$2"
  local stdout_file="$3"
  local stderr_file="$4"
  local exit_code="$5"

  local format
  format="$(get_parse_format "${tool}")"

  case "${format}" in
    yamllint)         parse_yamllint "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    eslint)           parse_eslint "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    prettier)         parse_prettier "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    ruff_json)        parse_ruff_json "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    shellcheck_json)  parse_shellcheck_json "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    actionlint_json)  parse_actionlint_json "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    jsonlint)         parse_jsonlint "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    markdownlint)     parse_markdownlint "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    hadolint_json)    parse_hadolint_json "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    golangci_json)    parse_golangci_json "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    taplo)            parse_taplo "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    luacheck)         parse_luacheck "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
    *)                parse_generic "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" ;;
  esac
}

parse_yamllint() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json, re

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

findings = []
error = None

if exit_code >= 2:
    error = stderr.strip() or stdout.strip()
else:
    pattern = re.compile(r'^.+?:(\d+):(\d+): \[(error|warning)\] (.+?) \((.+?)\)$')
    for line in stdout.splitlines():
        m = pattern.match(line)
        if m:
            findings.append({
                "file": file,
                "line": int(m.group(1)),
                "col": int(m.group(2)),
                "severity": m.group(3),
                "message": m.group(4),
                "rule": m.group(5)
            })

result = {
    "ok": len(findings) == 0 and error is None,
    "diagnostics": findings,
    "error": error
}
print(json.dumps(result))
PYEOF
}

parse_eslint() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

if exit_code >= 2:
    result = {"ok": False, "diagnostics": [], "error": stderr.strip() or stdout.strip()}
else:
    try:
        eslint_out = json.loads(stdout) if stdout.strip() else []
    except json.JSONDecodeError:
        result = {"ok": False, "diagnostics": [], "error": stdout.strip()}
        print(json.dumps(result))
        sys.exit(0)

    findings = []
    for file_result in eslint_out:
        for msg in file_result.get("messages", []):
            findings.append({
                "file": file_result.get("filePath", file),
                "line": msg.get("line", 0),
                "col": msg.get("column", 0),
                "severity": "error" if msg.get("severity") == 2 else "warning",
                "message": msg.get("message", ""),
                "rule": msg.get("ruleId", "") or ""
            })
    result = {"ok": len(findings) == 0, "diagnostics": findings, "error": None}

print(json.dumps(result))
PYEOF
}

parse_prettier() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json, re

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

# prettier --check: 0=formatted, 1=needs formatting, 2=parse error
if exit_code >= 2:
    combined = stderr.strip() or stdout.strip()
    # Strip ANSI codes
    clean = re.sub(r'\x1b\[[0-9;]*m', '', combined)
    # Try to extract line/col from "(LINE:COL)" in prettier error output
    m = re.search(r'\((\d+):(\d+)\)', clean)
    if m:
        line, col = int(m.group(1)), int(m.group(2))
    else:
        line, col = 0, 0
    first = next((l.strip() for l in clean.splitlines() if l.strip()), clean)
    first = re.sub(r'^\[error\]\s*', '', first)
    first = re.sub(r'^[^:]+:\s*', '', first, count=1)
    findings = [{"file": file, "line": line, "col": col, "severity": "error",
                 "message": first, "rule": "syntax"}]
    result = {"ok": False, "diagnostics": findings, "error": None}
elif exit_code == 1:
    findings = [{"file": file, "line": 0, "col": 0, "severity": "warning",
                 "message": "File is not formatted by prettier", "rule": "format"}]
    result = {"ok": False, "diagnostics": findings, "error": None}
else:
    result = {"ok": True, "diagnostics": [], "error": None}

print(json.dumps(result))
PYEOF
}

parse_ruff_json() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

if exit_code >= 2:
    result = {"ok": False, "diagnostics": [], "error": stderr.strip() or stdout.strip()}
else:
    try:
        ruff_out = json.loads(stdout) if stdout.strip() else []
    except json.JSONDecodeError:
        result = {"ok": False, "diagnostics": [], "error": stdout.strip()}
        print(json.dumps(result))
        sys.exit(0)

    findings = []
    for item in ruff_out:
        loc = item.get("location", {})
        findings.append({
            "file": item.get("filename", file),
            "line": loc.get("row", 0),
            "col": loc.get("column", 0),
            "severity": "error" if item.get("fix") is None else "warning",
            "message": item.get("message", ""),
            "rule": item.get("code", "") or ""
        })
    result = {"ok": len(findings) == 0, "diagnostics": findings, "error": None}

print(json.dumps(result))
PYEOF
}

parse_shellcheck_json() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

if exit_code >= 2:
    result = {"ok": False, "diagnostics": [], "error": stderr.strip() or stdout.strip()}
else:
    try:
        sc_out = json.loads(stdout) if stdout.strip() else []
    except json.JSONDecodeError:
        result = {"ok": False, "diagnostics": [], "error": stdout.strip()}
        print(json.dumps(result))
        sys.exit(0)

    findings = []
    for item in sc_out:
        sev = item.get("level", "warning")
        if sev == "info":
            sev = "warning"
        findings.append({
            "file": item.get("file", file),
            "line": item.get("line", 0),
            "col": item.get("column", 0),
            "severity": sev,
            "message": item.get("message", ""),
            "rule": "SC" + str(item.get("code", "")) if item.get("code") else ""
        })
    result = {"ok": len(findings) == 0, "diagnostics": findings, "error": None}

print(json.dumps(result))
PYEOF
}

parse_actionlint_json() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

if exit_code >= 2:
    result = {"ok": False, "diagnostics": [], "error": stderr.strip() or stdout.strip()}
else:
    try:
        al_out = json.loads(stdout) if stdout.strip() else []
    except json.JSONDecodeError:
        result = {"ok": False, "diagnostics": [], "error": stdout.strip()}
        print(json.dumps(result))
        sys.exit(0)

    # actionlint -format '{{json .}}' returns array of error objects
    findings = []
    if isinstance(al_out, list):
        items = al_out
    else:
        items = [al_out]
    for item in items:
        findings.append({
            "file": item.get("filepath", file),
            "line": item.get("line", 0),
            "col": item.get("column", 0),
            "severity": "error",
            "message": item.get("message", ""),
            "rule": item.get("kind", "")
        })
    result = {"ok": len(findings) == 0, "diagnostics": findings, "error": None}

print(json.dumps(result))
PYEOF
}

parse_jsonlint() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json, re

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

findings = []
error = None

if exit_code != 0:
    # jsonlint outputs errors to stderr in two formats:
    # old: "Error: ... at line N column M"
    # new: "[error] file: SyntaxError: ... (LINE:COL)"
    combined = (stderr.strip() or stdout.strip())
    # Strip ANSI color codes
    combined_clean = re.sub(r'\x1b\[[0-9;]*m', '', combined)
    # Try "(LINE:COL)" format first
    m = re.search(r'\((\d+):(\d+)\)', combined_clean)
    if m:
        line, col = int(m.group(1)), int(m.group(2))
    else:
        m_line = re.search(r'line (\d+)', combined_clean)
        m_col = re.search(r'column (\d+)', combined_clean)
        line = int(m_line.group(1)) if m_line else 0
        col = int(m_col.group(1)) if m_col else 0
    # Use first non-empty line as message, strip [error] prefix
    first_line = next((l.strip() for l in combined_clean.splitlines() if l.strip()), combined_clean)
    first_line = re.sub(r'^\[error\]\s*', '', first_line)
    # Strip file path prefix "file: " if present
    first_line = re.sub(r'^[^:]+:\s*', '', first_line, count=1)
    findings.append({
        "file": file,
        "line": line,
        "col": col,
        "severity": "error",
        "message": first_line,
        "rule": "syntax"
    })

result = {"ok": len(findings) == 0, "diagnostics": findings, "error": error}
print(json.dumps(result))
PYEOF
}

parse_markdownlint() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json, re

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

findings = []
error = None

if exit_code >= 2:
    error = stderr.strip() or stdout.strip()
else:
    # markdownlint-cli2 output: filepath:line ruleName/aliases message [context]
    pattern = re.compile(r'^.+?:(\d+)(?::(\d+))? ([\w-]+/[\w -]+?) (.+)$')
    for line in (stdout + "\n" + stderr).splitlines():
        m = pattern.match(line.strip())
        if m:
            findings.append({
                "file": file,
                "line": int(m.group(1)),
                "col": int(m.group(2)) if m.group(2) else 0,
                "severity": "error",
                "message": m.group(4).strip(),
                "rule": m.group(3).strip()
            })

result = {"ok": len(findings) == 0 and error is None, "diagnostics": findings, "error": error}
print(json.dumps(result))
PYEOF
}

parse_hadolint_json() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

if exit_code >= 2:
    result = {"ok": False, "diagnostics": [], "error": stderr.strip() or stdout.strip()}
else:
    try:
        hd_out = json.loads(stdout) if stdout.strip() else []
    except json.JSONDecodeError:
        result = {"ok": False, "diagnostics": [], "error": stdout.strip()}
        print(json.dumps(result))
        sys.exit(0)

    findings = []
    for item in hd_out:
        sev = item.get("level", "warning").lower()
        if sev not in ("error", "warning", "info"):
            sev = "warning"
        findings.append({
            "file": item.get("file", file),
            "line": item.get("line", 0),
            "col": item.get("column", 0),
            "severity": sev,
            "message": item.get("message", ""),
            "rule": item.get("code", "") or ""
        })
    result = {"ok": len(findings) == 0, "diagnostics": findings, "error": None}

print(json.dumps(result))
PYEOF
}

parse_golangci_json() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

if exit_code >= 2:
    result = {"ok": False, "diagnostics": [], "error": stderr.strip() or stdout.strip()}
else:
    try:
        gc_out = json.loads(stdout) if stdout.strip() else {}
    except json.JSONDecodeError:
        result = {"ok": False, "diagnostics": [], "error": stdout.strip()}
        print(json.dumps(result))
        sys.exit(0)

    findings = []
    for issue in gc_out.get("Issues", []) or []:
        pos = issue.get("Pos", {})
        findings.append({
            "file": pos.get("Filename", file),
            "line": pos.get("Line", 0),
            "col": pos.get("Column", 0),
            "severity": "error",
            "message": issue.get("Text", ""),
            "rule": issue.get("FromLinter", "") or ""
        })
    result = {"ok": len(findings) == 0, "diagnostics": findings, "error": None}

print(json.dumps(result))
PYEOF
}

parse_taplo() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json, re

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

findings = []
error = None

if exit_code >= 2:
    error = stderr.strip() or stdout.strip()
else:
    # taplo lint output: error: message\n  --> file:line:col
    combined = stdout + "\n" + stderr
    pattern = re.compile(r'^(error|warning|note):\s*(.+)', re.IGNORECASE)
    loc_pattern = re.compile(r'-->\s*.+:(\d+):(\d+)')
    lines = combined.splitlines()
    i = 0
    while i < len(lines):
        m = pattern.match(lines[i].strip())
        if m:
            sev = m.group(1).lower()
            if sev == "note":
                sev = "warning"
            msg = m.group(2)
            line_num = 0
            col_num = 0
            if i + 1 < len(lines):
                lm = loc_pattern.search(lines[i + 1])
                if lm:
                    line_num = int(lm.group(1))
                    col_num = int(lm.group(2))
                    i += 1
            findings.append({
                "file": file,
                "line": line_num,
                "col": col_num,
                "severity": sev,
                "message": msg,
                "rule": ""
            })
        i += 1

result = {"ok": len(findings) == 0 and error is None, "diagnostics": findings, "error": error}
print(json.dumps(result))
PYEOF
}

parse_luacheck() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json, re

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

findings = []
error = None

if exit_code >= 2 and not stdout.strip():
    error = stderr.strip() or "luacheck error"
else:
    # luacheck plain: filepath:line:col-col: (WN) message
    pattern = re.compile(r'^.+?:(\d+):(\d+)-\d+: \(([EW]\d+)\) (.+)$')
    for line in stdout.splitlines():
        m = pattern.match(line.strip())
        if m:
            code = m.group(3)
            sev = "error" if code.startswith("E") else "warning"
            findings.append({
                "file": file,
                "line": int(m.group(1)),
                "col": int(m.group(2)),
                "severity": sev,
                "message": m.group(4),
                "rule": code
            })

result = {"ok": len(findings) == 0 and error is None, "diagnostics": findings, "error": error}
print(json.dumps(result))
PYEOF
}

parse_generic() {
  local file="$1" stdout_file="$2" stderr_file="$3" exit_code="$4"
  python3 - "${file}" "${stdout_file}" "${stderr_file}" "${exit_code}" <<'PYEOF'
import sys, json

file = sys.argv[1]
stdout = open(sys.argv[2]).read()
stderr = open(sys.argv[3]).read()
exit_code = int(sys.argv[4])

error = None
if exit_code >= 2:
    error = stderr.strip() or stdout.strip()
    result = {"ok": False, "diagnostics": [], "error": error}
else:
    findings = []
    for line in stdout.splitlines():
        if line.strip():
            findings.append({
                "file": file,
                "line": 0,
                "col": 0,
                "severity": "warning",
                "message": line,
                "rule": ""
            })
    result = {"ok": len(findings) == 0, "diagnostics": findings, "error": None}

print(json.dumps(result))
PYEOF
}

# ---------------------------------------------------------------------------
# No-tool JSON output
# ---------------------------------------------------------------------------
emit_no_tool() {
  local file="$1"
  python3 - "${file}" <<'PYEOF'
import sys, json
file = sys.argv[1]
result = {
    "ok": True,
    "diagnostics": [],
    "error": "no tool registered for this filetype"
}
print(json.dumps(result))
PYEOF
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_check() {
  local file="$1"

  # Normalize file path
  if command -v realpath &>/dev/null; then
    file="$(realpath "${file}" 2>/dev/null || echo "${file}")"
  fi

  trap 'release_lock' EXIT INT TERM HUP
  acquire_lock

  maybe_update_registry

  local tool
  tool="$(find_tool_for_file "${file}")"

  if [[ -z "${tool}" ]]; then
    emit_no_tool "${file}"
    return 0
  fi

  # Check if tool is installed; install if missing or outdated
  local pkgs_dir
  pkgs_dir="$(get_packages_dir)"
  local pkg_file="${pkgs_dir}/${tool}/package.yaml"

  if [[ -f "${pkg_file}" ]]; then
    local tool_json
    tool_json="$(parse_package_yaml "${pkg_file}")"
    local registry_version
    registry_version="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('version',''))" "${tool_json}")"
    local installed_version
    installed_version="$(read_installed_version "${tool}")"

    if [[ -z "${installed_version}" ]] || [[ "${installed_version}" != "${registry_version}" ]]; then
      if ! install_tool "${tool}" 2>/tmp/shed_install_err_$$; then
        local err_msg
        err_msg="$(head -1 /tmp/shed_install_err_$$ 2>/dev/null)"
        rm -f /tmp/shed_install_err_$$
        python3 -c "
import sys, json
print(json.dumps({'ok': False, 'diagnostics': [], 'error': 'failed to install ' + sys.argv[1] + ': ' + sys.argv[2]}))
" "${tool}" "${err_msg:-unknown error}"
        return 0
      fi
      rm -f /tmp/shed_install_err_$$
    fi
  else
    log "warning: no package file found for tool '${tool}'"
  fi

  run_linter "${tool}" "${file}"
}

cmd_install() {
  local tool="$1"

  trap 'release_lock' EXIT INT TERM HUP
  acquire_lock

  maybe_update_registry

  local pkgs_dir
  pkgs_dir="$(get_packages_dir)"
  [[ -d "${pkgs_dir}/${tool}" ]] || die "unknown tool: ${tool}"

  install_tool "${tool}"
}

cmd_update() {
  trap 'release_lock' EXIT INT TERM HUP
  acquire_lock

  # Force registry refresh (ignore TTL)
  if ! git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    if [[ -d "${REGISTRY_DIR}/.git" ]]; then
      log "pulling registry..."
      git -C "${REGISTRY_DIR}" pull --quiet || log "warning: registry pull failed"
    fi
  fi
  printf '%s\n' "$(date +%s)" > "${LAST_CHECKED_PATH}"

  local pkgs_dir
  pkgs_dir="$(get_packages_dir)"

  local updated=0
  local current=0
  local skipped=0

  for tool_dir in "${pkgs_dir}"/*/; do
    [[ -d "${tool_dir}" ]] || continue
    local pkg_file="${tool_dir}package.yaml"
    [[ -f "${pkg_file}" ]] || continue

    local tool
    tool="$(basename "${tool_dir}")"

    local installed_version
    installed_version="$(read_installed_version "${tool}")"

    if [[ -z "${installed_version}" ]]; then
      echo "${tool}: not installed (skipped)"
      (( skipped++ )) || true
      continue
    fi

    local tool_json
    tool_json="$(parse_package_yaml "${pkg_file}")"
    local registry_version
    registry_version="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('version',''))" "${tool_json}")"

    if [[ "${installed_version}" == "${registry_version}" ]]; then
      echo "${tool}: already current (${registry_version})"
      (( current++ )) || true
    else
      echo "${tool}: updating ${installed_version} -> ${registry_version}"
      install_tool "${tool}"
      (( updated++ )) || true
    fi
  done

  echo "update complete: ${updated} updated, ${current} already current, ${skipped} not installed (skipped)"
}

cmd_list() {
  # Read-only, no lock needed
  local pkgs_dir
  pkgs_dir="$(get_packages_dir)"

  printf '%-22s %-14s %-14s %s\n' "TOOL" "INSTALLED" "REGISTRY" "STATUS"
  printf '%-22s %-14s %-14s %s\n' "----" "---------" "--------" "------"

  for tool_dir in "${pkgs_dir}"/*/; do
    [[ -d "${tool_dir}" ]] || continue
    local pkg_file="${tool_dir}package.yaml"
    [[ -f "${pkg_file}" ]] || continue

    local tool
    tool="$(basename "${tool_dir}")"

    local tool_json
    tool_json="$(parse_package_yaml "${pkg_file}")"
    local registry_version
    registry_version="$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('version',''))" "${tool_json}")"

    local installed_version
    installed_version="$(read_installed_version "${tool}")"

    local status
    if [[ -z "${installed_version}" ]]; then
      status="not installed"
      installed_version="-"
    elif [[ "${installed_version}" == "${registry_version}" ]]; then
      status="current"
    else
      status="outdated"
    fi

    printf '%-22s %-14s %-14s %s\n' "${tool}" "${installed_version:0:13}" "${registry_version}" "${status}"
  done
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: shed <command> [args]

Commands:
  check <file>      Lint a file (auto-install tool if needed), print JSON result
  install <tool>    Install or update a specific tool
  update            Update all installed tools to registry versions
  list              List all registered tools and their install status

Environment:
  SHED_DIR          Override default directory (default: ~/.linter-shed)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  check_python3

  mkdir -p "${SHED_DIR}" "${SHED_BIN}" "${TOOLS_DIR}" "${VERSIONS_DIR}"

  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    check)
      [[ -n "${1:-}" ]] || die "check requires a file argument"
      cmd_check "$1"
      ;;
    install)
      [[ -n "${1:-}" ]] || die "install requires a tool name"
      cmd_install "$1"
      ;;
    update)
      cmd_update
      ;;
    list)
      cmd_list
      ;;
    help|--help|-h)
      usage
      ;;
    "")
      usage
      exit 1
      ;;
    *)
      die "unknown command: ${cmd}. Run 'shed help' for usage."
      ;;
  esac
}

main "$@"
