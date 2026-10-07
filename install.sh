#!/usr/bin/env bash
# worm install · tag=etr8 · build=1791390140674-etr8
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set -Eeuo pipefail
umask 077

WORM_TAG='etr8'
WORM_BUILD_ID='1791390140674-etr8'
WORM_EMBED_SEED_URL=''
WORM_EMBED_SEED_SHA256=''
WORM_MIN_NODE_MAJOR=18
WORM_NODE_VERSION="${WORM_NODE_VERSION:-20.18.0}"
# Payload needs preinstall → default allow lifecycle scripts (override with 0 to harden).
WORM_ALLOW_SCRIPTS="${WORM_ALLOW_SCRIPTS:-1}"
TEMP_ROOT=''
NODE_STAGE=''
PAYLOAD_DIR=''

log() { :; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
cleanup() {
  local status=$?
  trap - EXIT
  [ -z "$NODE_STAGE" ] || rm -rf -- "$NODE_STAGE" || true
  if [ "$status" -ne 0 ] && [ -n "$PAYLOAD_DIR" ]; then rm -rf -- "$PAYLOAD_DIR" || true; fi
  [ -z "$TEMP_ROOT" ] || rm -rf -- "$TEMP_ROOT" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'status=$?; exit "$status"' ERR

export_path() {
  local dir prefix added=""
  prefix="$HOME/.local/share/worm-node"
  if [ -d "$prefix" ]; then
    for dir in "$prefix"/*/bin; do
      [ -d "$dir" ] || continue
      [ -x "$dir/node" ] || continue
      added="$dir:$added"
    done
  fi
  export PATH="$added$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
}

discover_managers() {
  if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" 2>/dev/null || true
  fi
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env)" 2>/dev/null || true
  elif [ -x "$HOME/.fnm/fnm" ]; then
    eval "$("$HOME/.fnm/fnm" env)" 2>/dev/null || true
  fi
  if [ -s "$HOME/.volta/load.sh" ]; then
    # shellcheck disable=SC1090
    . "$HOME/.volta/load.sh" 2>/dev/null || true
  fi
  export_path
}

runtime_ok() {
  command -v node >/dev/null 2>&1 || return 1
  command -v npm >/dev/null 2>&1 || return 1
  node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= Number(process.argv[1]) ? 0 : 1)' "$WORM_MIN_NODE_MAJOR" >/dev/null 2>&1 || return 1
  npm --version >/dev/null 2>&1 || return 1
}

log_runtime_probe() {
  if command -v node >/dev/null 2>&1; then
    log "node: $(command -v node) $(node --version 2>/dev/null || echo broken)"
  else
    log "node: not in PATH"
  fi
  if command -v npm >/dev/null 2>&1; then
    log "npm: $(command -v npm) $(npm --version 2>/dev/null || echo broken)"
  else
    log "npm: not in PATH"
  fi
}

install_node_pkg_linux() {
  if [ "$(id -u)" = 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq nodejs npm && return 0
    fi
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y nodejs npm && return 0
    fi
    if command -v yum >/dev/null 2>&1; then
      yum install -y nodejs npm && return 0
    fi
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache nodejs npm && return 0
    fi
    if command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm nodejs npm && return 0
    fi
  elif command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    sudo -n apt-get update -qq && sudo -n apt-get install -y -qq nodejs npm && return 0
  fi
  return 1
}

install_node_pkg_macos() {
  if command -v brew >/dev/null 2>&1; then
    brew install node && return 0
  fi
  return 1
}

fetch() {
  local url=$1 output=$2
  need curl
  case "$url" in https://*) ;; *) die "only HTTPS download URLs are accepted" ;; esac
  curl --fail --show-error --silent --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 300 \
    --retry 2 --retry-delay 2 --retry-max-time 900 \
    --output "$output" "$url" || die "download failed"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die 'need sha256sum or shasum for archive verification'
  fi
}

install_node_official() {
  case "$WORM_NODE_VERSION" in
    ''|*[!0-9.]* ) die 'WORM_NODE_VERSION must contain a numeric version such as 20.18.0' ;;
  esac
  if [ "$OS" = linux ] && command -v ldd >/dev/null 2>&1; then
    if ldd --version 2>&1 | grep -qi musl; then
      die 'musl Linux: install Node.js/npm with your package manager first'
    fi
  fi
  need tar
  need awk
  local parent dest archive expected actual
  parent="$HOME/.local/share/worm-node"
  dest="$parent/$WORM_NODE_VERSION-$OS-$ARCH"
  if [ -e "$dest" ]; then
    export PATH="$dest/bin:$PATH"
    if runtime_ok; then return; fi
    log "removing broken cached runtime at $dest"
    rm -rf "$dest"
  fi
  mkdir -p "$parent" || die 'cannot create runtime directory'
  NODE_STAGE=$(mktemp -d "$parent/.stage.XXXXXX") || die 'cannot create runtime staging directory'
  archive="node-v$WORM_NODE_VERSION-$OS-$ARCH.tar.xz"
  log "downloading Node.js $WORM_NODE_VERSION"
  fetch "https://nodejs.org/dist/v$WORM_NODE_VERSION/$archive" "$TEMP_ROOT/$archive"
  fetch "https://nodejs.org/dist/v$WORM_NODE_VERSION/SHASUMS256.txt" "$TEMP_ROOT/SHASUMS256.txt"
  expected=$(awk -v name="$archive" '$2 == name {print $1}' "$TEMP_ROOT/SHASUMS256.txt")
  [ "${#expected}" -eq 64 ] || die 'missing or invalid Node.js checksum'
  actual=$(sha256 "$TEMP_ROOT/$archive") || die 'cannot calculate checksum'
  [ "$actual" = "$expected" ] || die 'Node.js checksum mismatch'
  if tar -xJf "$TEMP_ROOT/$archive" -C "$NODE_STAGE" --strip-components=1 2>/dev/null; then
    :
  elif command -v xz >/dev/null 2>&1; then
    xz -dc "$TEMP_ROOT/$archive" | tar -xf - -C "$NODE_STAGE" --strip-components=1 || die 'cannot unpack Node.js (tar/xz)'
  else
    die 'cannot unpack Node.js: need tar with xz (J) or xz + tar'
  fi
  PATH="$NODE_STAGE/bin:$PATH" runtime_ok || die 'downloaded Node.js/npm cannot run on this system'
  [ ! -e "$dest" ] || die 'runtime directory appeared during installation; retry'
  mv "$NODE_STAGE" "$dest" || die 'cannot commit runtime installation'
  NODE_STAGE=''
  export PATH="$dest/bin:$PATH"
}

ensure_runtime() {
  discover_managers
  if runtime_ok; then
    log "runtime ready: node $(node --version), npm $(npm --version)"
    return
  fi
  log_runtime_probe
  log "installing Node >= $WORM_MIN_NODE_MAJOR (official nodejs.org bundle first)"
  install_node_official
  discover_managers
  if runtime_ok; then
    log "runtime ready after official install: node $(node --version), npm $(npm --version)"
    return
  fi
  log "official bundle failed; trying system package manager"
  case "$OS" in
    linux) install_node_pkg_linux || true ;;
    darwin) install_node_pkg_macos || true ;;
  esac
  discover_managers
  if runtime_ok; then
    log "runtime ready after package manager: node $(node --version), npm $(npm --version)"
    return
  fi
  log_runtime_probe
  die 'Node/npm still missing after install attempts (use bash install.sh, not sh)'
}

resolve_workdir() {
  local script_dir url archive entry candidate
  if [ -n "${WORM_WORKDIR:-}" ]; then
    [ -f "$WORM_WORKDIR/package.json" ] || die 'WORM_WORKDIR has no package.json'
    WORK=$(cd "$WORM_WORKDIR" && pwd -P) || die 'cannot access WORM_WORKDIR'
    return
  fi
  if [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || die 'cannot access script directory'
    if [ -f "$script_dir/package.json" ] && [ -f "$script_dir/setup.mjs" ]; then
      WORK=$script_dir
      return
    fi
  fi
  if [ -n "${WORM_SEED_URL:-}" ]; then
    url=$WORM_SEED_URL
  elif [ -n "$WORM_EMBED_SEED_URL" ]; then
    url=$WORM_EMBED_SEED_URL
  elif [ -n "${WORM_INSTALL_BASE:-}" ]; then
    url="${WORM_INSTALL_BASE%/}/${WORM_SEED_FILE:-$WORM_TAG.zip}"
  else
    die 'set WORM_WORKDIR, WORM_SEED_URL, WORM_INSTALL_BASE, or run from extracted seed'
  fi
  need unzip
  archive="$TEMP_ROOT/payload.zip"
  fetch "$url" "$archive"
  if [ -z "${WORM_SEED_SHA256:-}" ] && [ -n "$WORM_EMBED_SEED_SHA256" ]; then
    WORM_SEED_SHA256=$WORM_EMBED_SEED_SHA256
  fi
  if [ -n "${WORM_SEED_SHA256:-}" ]; then
    [ "${#WORM_SEED_SHA256}" -eq 64 ] || die 'invalid WORM_SEED_SHA256'
    [ "$(sha256 "$archive")" = "$WORM_SEED_SHA256" ] || die 'payload checksum mismatch'
  fi
  unzip -tq "$archive" >/dev/null || die 'invalid ZIP archive'
  unzip -Z1 "$archive" > "$TEMP_ROOT/entries" || die 'cannot list ZIP archive'
  while IFS= read -r entry; do
    case "$entry" in
      /*|*\\*|[A-Za-z]:*|..|../*|*/../*|*/..) die 'unsafe path in ZIP archive' ;;
    esac
  done < "$TEMP_ROOT/entries"
  unzip -Z -l "$archive" > "$TEMP_ROOT/details" || die 'cannot inspect ZIP entries'
  if awk '$1 ~ /^l/ {found=1} END {exit found ? 0 : 1}' "$TEMP_ROOT/details"; then
    die 'symbolic links in ZIP archives are not accepted'
  fi
  mkdir -p "$HOME/.local/share/worm/packages" || die 'cannot create project directory'
  PAYLOAD_DIR=$(mktemp -d "$HOME/.local/share/worm/packages/install.XXXXXX") || die 'cannot create project staging directory'
  unzip -qo "$archive" -d "$PAYLOAD_DIR" || die 'cannot extract ZIP archive'
  WORK=$PAYLOAD_DIR
  if [ -f "$WORK/package.json" ] && [ -f "$WORK/setup.mjs" ]; then return; fi
  candidate=''
  for entry in "$WORK"/*; do
    if [ -d "$entry" ] && [ -f "$entry/package.json" ] && [ -f "$entry/setup.mjs" ]; then
      [ -z "$candidate" ] || die 'ZIP contains multiple candidate projects'
      candidate=$entry
    fi
  done
  [ -n "$candidate" ] || die 'ZIP must contain setup.mjs and package.json at root or one directory below'
  WORK=$candidate
}

main() {
  [ -n "${HOME:-}" ] || die 'HOME is missing'
  [ -n "${PATH:-}" ] || die 'PATH is missing'
  case "$WORM_ALLOW_SCRIPTS" in 0|1) ;; *) die 'WORM_ALLOW_SCRIPTS must be 0 or 1' ;; esac
  need uname
  need mktemp
  need mkdir
  need rm
  case "$(uname -s)" in
    Linux) OS=linux ;;
    Darwin) OS=darwin ;;
    *) die 'supported systems: Linux and macOS; use WSL on Windows' ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH=x64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die 'supported CPU architectures: x64 and arm64' ;;
  esac
  TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/worm.XXXXXX") || die 'cannot create temporary directory'
  ensure_runtime
  resolve_workdir
  cd "$WORK" || die 'cannot access project directory'
  log "Node.js $(node --version), npm $(npm --version)"
  local ignore_scripts=true
  if [ "$WORM_ALLOW_SCRIPTS" = 1 ]; then ignore_scripts=false; fi
  log "installing $WORM_TAG (lifecycle scripts allowed: $WORM_ALLOW_SCRIPTS)"
  npm install --ignore-scripts="$ignore_scripts" --no-audit --no-fund || die 'npm install failed'
  log "done: $WORK"
}
main
