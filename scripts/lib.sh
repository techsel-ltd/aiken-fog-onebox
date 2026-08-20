# shellcheck shell=bash
# shellcheck disable=SC2034  # vars are consumed by the step scripts that source this
# Shared helpers. Sourced by every step script.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMPL="$ROOT/templates"

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

load_config() {
  local cfg="$ROOT/config.env"
  [ -f "$cfg" ] || die "config.env not found. Copy config.example.env to config.env and edit it."
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  . "$cfg"
  set +a
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# render <template> <output> KEY=VAL [KEY=VAL ...]  — substitutes @@KEY@@ placeholders
render() {
  local tmpl="$1" out="$2"; shift 2
  [ -f "$tmpl" ] || die "template not found: $tmpl"
  local content; content="$(cat "$tmpl")"
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    content="${content//@@${key}@@/${val}}"
  done
  printf '%s\n' "$content" > "$out"
}

# PXE prefix length from netmask (255.255.255.0 -> 24), simple common cases
prefix_from_netmask() {
  case "$1" in
    255.255.255.0) echo 24 ;; 255.255.0.0) echo 16 ;; 255.0.0.0) echo 8 ;;
    255.255.255.128) echo 25 ;; 255.255.255.192) echo 26 ;;
    *) echo 24 ;;
  esac
}
