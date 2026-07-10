#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================
# PYVET / galdr-works - Python Package Vetting Environment
# Author: galdr-works
# Version: 1.7
# ============================================================
APP_NAME="PYVET"
APP_VERSION="1.7"
INSTALL_DIR="${PYVET_INSTALL_DIR:-$HOME/.local/bin}"
VENV_DIR="${PYVET_VENV_DIR:-$HOME/.local/share/pyvet/venv}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pyvet"
TOKEN_FILE="$CONFIG_DIR/github.env"
MANIFEST_FILE="$CONFIG_DIR/toolchain.manifest.json"
BASHRC="$HOME/.bashrc"
export PATH="$INSTALL_DIR:$PATH"

# ------------------------------------------------------------
# Version pins. Leave unset/empty to install latest (default,
# but NOT reproducible run-to-run). To pin, export the
# PYVET_*_VERSION vars before running this script — use the
# values recorded in a previous run's toolchain.manifest.json.
# ------------------------------------------------------------
SYFT_VERSION="${PYVET_SYFT_VERSION:-}"           # e.g. v1.20.0
GRYPE_VERSION="${PYVET_GRYPE_VERSION:-}"         # e.g. v0.114.0
OSV_SCANNER_VERSION="${PYVET_OSV_SCANNER_VERSION:-}"   # e.g. v1.9.0
SCORECARD_VERSION="${PYVET_SCORECARD_VERSION:-}" # e.g. v5.0.0
PIP_TOOLS_VERSION="${PYVET_PIP_TOOLS_VERSION:-}"
PIP_AUDIT_VERSION="${PYVET_PIP_AUDIT_VERSION:-}"
BANDIT_VERSION="${PYVET_BANDIT_VERSION:-}"
GUARDDOG_VERSION="${PYVET_GUARDDOG_VERSION:-}"

MANIFEST_TMP=""

banner() {
cat <<'EOF'
============================================================
   ____  __   __ __     __ ______ ______
  |  _ \ \ \ / / \ \   / /|  ____|__  __|
  | |_) | \ V /   \ \_/ / | |__     | |
  |  __/   | |     \   /  |  __|    | |
  | |      | |      | |   | |____   | |
  |_|      |_|      |_|   |______|  |_|
        PYTHON PACKAGE VETTING ENVIRONMENT
        TRUST NOTHING. INSPECT EVERYTHING.
        Author galdr-works Version 1.7
============================================================
EOF
}

die() {
  echo "[!] ERROR: $*" >&2
  exit 1
}

warn() {
  echo "[!] WARN: $*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo "sha256 tool not found"
  fi
}

get_version() {
  local name="$1"
  local path="$2"
  local out=""
  case "$name" in
    syft|grype)
      out="$("$path" version 2>/dev/null | awk -F': *' '/^Version:/ {print $2; exit}' || true)"
      ;;
    scorecard)
      out="$("$path" --version 2>/dev/null | head -n 1 || true)"
      [[ -z "$out" ]] && out="$("$path" version 2>/dev/null | head -n 1 || true)"
      ;;
    guarddog)
      out="$("$path" --version 2>/dev/null | head -n 1 || true)"
      [[ -z "$out" ]] && out="$("$path" -h 2>/dev/null | head -n 1 || true)"
      ;;
    *)
      out="$("$path" --version 2>/dev/null | head -n 1 || true)"
      ;;
  esac
  [[ -n "$out" ]] || out="unknown"
  printf "%s" "$out"
}

# Prints the tool's install record AND appends a JSON entry to the
# toolchain manifest so this run is reproducible from the next one.
report_tool() {
  local name="$1"
  local source_url="$2"
  local path=""
  local hash=""
  local ver=""
  path="$(command -v "$name" || true)"
  if [[ -z "$path" || ! -x "$path" ]]; then
    die "$name was not found after install."
  fi
  hash="$(sha256_file "$path")"
  ver="$(get_version "$name" "$path")"
  printf "\t%s from %s to %s\n" "$name" "$source_url" "$path"
  printf "\t\tHASH: %s\n" "$hash"
  printf "\t\tVersion: %s\n" "$ver"
  if [[ -n "$MANIFEST_TMP" ]]; then
    jq -n \
      --arg name "$name" \
      --arg version "$ver" \
      --arg sha256 "$hash" \
      --arg source "$source_url" \
      --arg path "$path" \
      --arg installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{name:$name, version:$version, sha256:$sha256, source:$source, path:$path, installed_at:$installed_at}' \
      >> "$MANIFEST_TMP"
  fi
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
}

ensure_bashrc_blocks() {
  touch "$BASHRC"
  if ! grep -Fq "# >>> pyvet path >>>" "$BASHRC"; then
    {
      echo ""
      echo "# >>> pyvet path >>>"
      echo "export PATH=\"$INSTALL_DIR:\$PATH\""
      echo "# <<< pyvet path <<<"
    } >> "$BASHRC"
  fi
  # NOTE: the token is intentionally NOT auto-sourced into every shell.
  # GITHUB_AUTH_TOKEN sitting live in every interactive shell's
  # environment is unnecessary exposure (it's also exactly the kind
  # of env-var-exfiltration pattern guarddog itself watches for in
  # vetted packages). Load it on demand instead: run `pyvet-auth`
  # right before you run scorecard.
  if ! grep -Fq "# >>> pyvet github token >>>" "$BASHRC"; then
    {
      echo ""
      echo "# >>> pyvet github token >>>"
      echo "pyvet-auth() {"
      echo "  if [ -f \"$TOKEN_FILE\" ]; then"
      echo "    . \"$TOKEN_FILE\""
      echo "    echo \"[pyvet] GITHUB_AUTH_TOKEN loaded for this shell.\""
      echo "  else"
      echo "    echo \"[pyvet] No token file at $TOKEN_FILE\" >&2"
      echo "  fi"
      echo "}"
      echo "# <<< pyvet github token <<<"
    } >> "$BASHRC"
  fi
}

prompt_github_token() {
  echo
  echo "[*] GitHub authentication token setup"
  echo "    This will be stored in: $TOKEN_FILE"
  echo "    Permissions will be locked to chmod 600."
  echo "    It will NOT be auto-loaded into every shell — run 'pyvet-auth' to load it when needed."
  echo
  read -rsp "Enter GITHUB_AUTH_TOKEN hidden input, or press Enter to keep existing/skip: " GITHUB_AUTH_TOKEN_INPUT
  echo
  if [[ -n "${GITHUB_AUTH_TOKEN_INPUT:-}" ]]; then
    umask 077
    {
      echo "# Created by $APP_NAME installer."
      echo "# Loaded on demand via the 'pyvet-auth' shell function (see ~/.bashrc)."
      printf 'export GITHUB_AUTH_TOKEN=%q\n' "$GITHUB_AUTH_TOKEN_INPUT"
    } > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    export GITHUB_AUTH_TOKEN="$GITHUB_AUTH_TOKEN_INPUT"
    echo "[+] Stored GITHUB_AUTH_TOKEN in protected env file."
  elif [[ -f "$TOKEN_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$TOKEN_FILE"
    echo "[+] Existing token file preserved and loaded for this install run."
  else
    echo "[!] No token stored. Scorecard may hit unauthenticated GitHub API rate limits."
  fi
}

curl_gh() {
  local url="$1"
  if [[ -n "${GITHUB_AUTH_TOKEN:-}" ]]; then
    curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "$url"
  else
    curl -fsSL "$url"
  fi
}

curl_gh_file() {
  local url="$1"
  local out="$2"
  if [[ -n "${GITHUB_AUTH_TOKEN:-}" ]]; then
    curl -fL \
      -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -o "$out" \
      "$url"
  else
    curl -fL -o "$out" "$url"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) uname -m ;;
  esac
}

detect_arch_alt() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) uname -m ;;
  esac
}

# Installs a binary from a GitHub release. If $3 (version) is empty,
# uses /releases/latest — otherwise pins to /releases/tags/$3.
install_release_binary() {
  local repo="$1"
  local binary="$2"
  local version="${3:-}"
  local os="linux"
  local arch
  local arch_alt
  local tmp
  local release_json
  local asset_url
  local asset
  local extract_dir
  local candidate=""
  local endpoint

  arch="$(detect_arch)"
  arch_alt="$(detect_arch_alt)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  release_json="$tmp/release.json"
  extract_dir="$tmp/extract"
  mkdir -p "$extract_dir"

  if [[ -n "$version" ]]; then
    endpoint="https://api.github.com/repos/${repo}/releases/tags/${version}"
  else
    endpoint="https://api.github.com/repos/${repo}/releases/latest"
  fi

  if ! curl_gh "$endpoint" > "$release_json"; then
    return 1
  fi
  asset_url="$(
    grep -E '"browser_download_url":' "$release_json" \
      | cut -d '"' -f 4 \
      | grep -Ei "${os}" \
      | grep -Ei "(${arch}|${arch_alt})" \
      | grep -Eiv '(sha256|checksums?|sbom|attestation|intoto|\.sig|\.pem|\.json|\.txt)' \
      | head -n 1 || true
  )"
  if [[ -z "$asset_url" ]]; then
    return 1
  fi
  asset="$tmp/${asset_url##*/}"
  if ! curl_gh_file "$asset_url" "$asset"; then
    return 1
  fi
  case "$asset" in
    *.tar.gz|*.tgz)
      tar -xzf "$asset" -C "$extract_dir"
      ;;
    *.zip)
      command -v unzip >/dev/null 2>&1 || return 1
      unzip -q "$asset" -d "$extract_dir"
      ;;
    *)
      cp "$asset" "$extract_dir/$binary"
      chmod +x "$extract_dir/$binary"
      ;;
  esac
  candidate="$(find "$extract_dir" -type f -name "$binary" -print -quit || true)"
  if [[ -z "$candidate" ]]; then
    candidate="$(
      find "$extract_dir" -type f \
        | grep -E "/${binary}([_-].*)?$" \
        | head -n 1 || true
    )"
  fi
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  install -m 0755 "$candidate" "$INSTALL_DIR/$binary"
  return 0
}

# $2 = module path (no @version suffix), $3 = version, defaults to "latest".
# Go's default toolchain verifies downloads against the public checksum
# database (sum.golang.org) unless GOSUMDB/GOFLAGS have been overridden
# in this environment, so this path has real integrity checking even
# though it doesn't have version pinning by default.
install_go_tool() {
  local package="$1"
  local version="${2:-latest}"
  command -v go >/dev/null 2>&1 || return 1
  GOBIN="$INSTALL_DIR" go install "${package}@${version}"
}

# Anchore's install.sh checksum-validates the binary by default. Full
# cosign signature verification (proving the release actually came
# from Anchore's CI, not just that the binary matches its own
# checksums file) requires the -v flag AND cosign being installed.
# We use -v whenever cosign is available and degrade to a warning
# otherwise, rather than silently skipping verification.
install_anchore_tool() {
  local tool="$1"
  local version="${2:-}"
  local args=(-b "$INSTALL_DIR")
  if command -v cosign >/dev/null 2>&1; then
    args+=(-v)
  else
    warn "cosign not found — installing ${tool} with checksum validation only (no signature verification). Install cosign for full verification."
  fi
  [[ -n "$version" ]] && args+=("$version")
  curl -sSfL "https://get.anchore.io/${tool}" | sh -s -- "${args[@]}"
}

ensure_python_venv() {
  need_cmd python3
  if ! python3 - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
  then
    die "Python 3.10+ is required for pip-audit. Install a newer python3 first."
  fi
  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR" || die "Failed to create venv. On Debian/Ubuntu/Kali, install python3-venv."
  fi
  "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools >/dev/null
}

# $3 (version) pins via pip's == operator. Left empty, installs
# whatever is currently latest on PyPI — fine for a quick bootstrap,
# but every vetting decision this environment ever produces rides on
# the integrity of these packages, so pin them for anything beyond
# a one-off. Set the matching PYVET_*_VERSION env var to do so.
install_python_tool() {
  local tool="$1"
  local package="$2"
  local version="${3:-}"
  local spec="$package"
  ensure_python_venv
  if [[ -n "$version" ]]; then
    spec="${package}==${version}"
  else
    local hint
    hint="PYVET_$(echo "$tool" | tr '[:lower:]-' '[:upper:]_')_VERSION"
    warn "No version pin for $tool — installing latest from PyPI, unhashed. Set \$$hint to pin."
  fi
  "$VENV_DIR/bin/python" -m pip install --upgrade "$spec"
  ln -sf "$VENV_DIR/bin/$tool" "$INSTALL_DIR/$tool"
}

install_osv_scanner() {
  install_release_binary "google/osv-scanner" "osv-scanner" "$OSV_SCANNER_VERSION" \
    || install_go_tool "github.com/google/osv-scanner/v2/cmd/osv-scanner" "${OSV_SCANNER_VERSION:-latest}" \
    || die "Failed to install osv-scanner. Install Go or check GitHub release access."
}

install_scorecard() {
  install_release_binary "ossf/scorecard" "scorecard" "$SCORECARD_VERSION" \
    || install_go_tool "github.com/ossf/scorecard/v5" "${SCORECARD_VERSION:-latest}" \
    || die "Failed to install scorecard. Install Go or check GitHub release access."
}

preflight() {
  need_cmd curl
  need_cmd tar
  need_cmd jq
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    die "Missing sha256sum or shasum."
  fi
  if ! command -v cosign >/dev/null 2>&1; then
    warn "cosign not found — Anchore tool installs will use checksum validation only, not signature verification."
  fi
}

write_manifest() {
  [[ -n "$MANIFEST_TMP" && -s "$MANIFEST_TMP" ]] || return 0
  jq -s '.' "$MANIFEST_TMP" > "$MANIFEST_FILE"
  chmod 644 "$MANIFEST_FILE"
}

main() {
  banner
  preflight
  ensure_dirs
  ensure_bashrc_blocks
  prompt_github_token

  MANIFEST_TMP="$(mktemp)"
  trap 'rm -f "$MANIFEST_TMP"' EXIT

  echo
  echo "Installing:"

  install_python_tool "pip-compile" "pip-tools" "$PIP_TOOLS_VERSION"
  report_tool "pip-compile" "https://github.com/jazzband/pip-tools"

  install_anchore_tool "syft" "$SYFT_VERSION"
  report_tool "syft" "https://github.com/anchore/syft"

  install_anchore_tool "grype" "$GRYPE_VERSION"
  report_tool "grype" "https://github.com/anchore/grype"

  install_python_tool "pip-audit" "pip-audit" "$PIP_AUDIT_VERSION"
  report_tool "pip-audit" "https://github.com/pypa/pip-audit"

  install_osv_scanner
  report_tool "osv-scanner" "https://github.com/google/osv-scanner"

  install_python_tool "bandit" "bandit[toml,sarif]" "$BANDIT_VERSION"
  report_tool "bandit" "https://github.com/PyCQA/bandit"

  install_python_tool "guarddog" "guarddog" "$GUARDDOG_VERSION"
  report_tool "guarddog" "https://github.com/DataDog/guarddog"

  install_scorecard
  report_tool "scorecard" "https://github.com/ossf/scorecard"

  write_manifest

  echo
  echo "============================================================"
  echo "[+] PYVET environment install complete."
  echo "[+] Install dir:  $INSTALL_DIR"
  echo "[+] Python venv:  $VENV_DIR"
  echo "[+] Token file:   $TOKEN_FILE (not auto-loaded — run 'pyvet-auth' when needed)"
  echo "[+] Manifest:     $MANIFEST_FILE"
  echo "[+]   Pin this run's exact versions next time by exporting the"
  echo "[+]   PYVET_*_VERSION vars from the manifest before re-running."
  echo
  echo "Run this now to load the environment in the current shell:"
  echo "    source ~/.bashrc"
  echo "============================================================"
}

main "$@"
