#!/usr/bin/env bash
# Resolve, explicitly build, or explicitly install the native TUI. The resolve
# command is local-only; network access occurs only under the install command.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${TMUX_RADAR_BUILD_SCRIPT:-$ROOT/scripts/build-native.sh}"

usage() {
  cat >&2 <<'EOF'
usage:
  ensure-native.sh resolve
  ensure-native.sh platform <version>
  ensure-native.sh build
  ensure-native.sh install <version> [--base-url URL] [--install-dir DIR]
  ensure-native.sh legacy
EOF
}

platform_os() {
  local value="${TMUX_RADAR_PLATFORM_OS:-$(uname -s)}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in darwin|linux) printf '%s\n' "$value" ;; *) return 1 ;; esac
}

platform_arch() {
  local value="${TMUX_RADAR_PLATFORM_ARCH:-$(uname -m)}"
  case "$value" in
    arm64|aarch64) printf '%s\n' arm64 ;;
    amd64|x86_64) printf '%s\n' amd64 ;;
    *) return 1 ;;
  esac
}

asset_name() {
  local version="$1" os_name arch_name
  case "$version" in v[0-9]*.[0-9]*.[0-9]*) : ;; *) echo "invalid release version: $version" >&2; return 2 ;; esac
  os_name="$(platform_os)" || { echo 'unsupported operating system' >&2; return 3; }
  arch_name="$(platform_arch)" || { echo 'unsupported architecture' >&2; return 3; }
  printf 'tmux-radar_%s_%s_%s\n' "$version" "$os_name" "$arch_name"
}

compatible_binary() {
  local binary="$1"
  [ -x "$binary" ] || return 1
  case "$("$binary" version 2>/dev/null || true)" in *"protocol 1"*) return 0 ;; *) return 1 ;; esac
}

resolve_local() {
  local candidate
  candidate="${TMUX_RADAR_BIN:-}"
  if [ -n "$candidate" ] && compatible_binary "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$ROOT/bin/tmux-radar"
  if compatible_binary "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$(command -v tmux-radar 2>/dev/null || true)"
  if [ -n "$candidate" ] && compatible_binary "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo 'no SHA-256 tool found (need shasum or sha256sum)' >&2
    return 3
  fi
}

install_release() {
  local version="$1" base_url="" install_dir="$ROOT/bin" asset temporary expected actual staged
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base-url) [ "$#" -ge 2 ] || { usage; return 2; }; base_url="$2"; shift 2 ;;
      --install-dir) [ "$#" -ge 2 ] || { usage; return 2; }; install_dir="$2"; shift 2 ;;
      *) echo "unknown install option: $1" >&2; return 2 ;;
    esac
  done
  case "$install_dir" in /*) : ;; *) echo 'install directory must be absolute' >&2; return 2 ;; esac
  asset="$(asset_name "$version")" || return $?
  [ -n "$base_url" ] || base_url="https://github.com/lr00rl/tmux-radar/releases/download/$version"
  command -v curl >/dev/null 2>&1 || { echo 'curl is required for release install' >&2; return 3; }

  temporary="$(mktemp -d "${TMPDIR:-/tmp}/tmux-radar-install.XXXXXX")"
  cleanup_install() { rm -rf "$temporary"; }
  trap cleanup_install EXIT INT TERM HUP
  curl -fsSL "$base_url/$asset" -o "$temporary/$asset"
  curl -fsSL "$base_url/checksums.txt" -o "$temporary/checksums.txt"
  expected="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1; exit }' "$temporary/checksums.txt")"
  [ -n "$expected" ] || { echo "checksum is missing for $asset" >&2; return 4; }
  actual="$(sha256_file "$temporary/$asset")" || return $?
  [ "$actual" = "$expected" ] || { echo "checksum mismatch for $asset" >&2; return 4; }
  chmod 0755 "$temporary/$asset"
  compatible_binary "$temporary/$asset" || { echo 'downloaded binary failed protocol verification' >&2; return 5; }

  mkdir -p "$install_dir"
  staged="$install_dir/.tmux-radar.tmp.$$"
  cp "$temporary/$asset" "$staged"
  chmod 0755 "$staged"
  mv -f "$staged" "$install_dir/tmux-radar"
  trap - EXIT INT TERM HUP
  rm -rf "$temporary"
  printf '%s\n' "$install_dir/tmux-radar"
}

command_name="${1:-}"
case "$command_name" in
  resolve)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    resolve_local
    ;;
  platform)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    asset_name "$2"
    ;;
  build)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    exec "$BUILD_SCRIPT"
    ;;
  install)
    [ "$#" -ge 2 ] || { usage; exit 2; }
    version="$2"
    shift 2
    install_release "$version" "$@"
    ;;
  legacy)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    printf '%s\n' "Use TMUX_RADAR_LEGACY_UI=1 for the explicit legacy supervisor UI rollback."
    ;;
  *)
    usage
    exit 2
    ;;
esac
