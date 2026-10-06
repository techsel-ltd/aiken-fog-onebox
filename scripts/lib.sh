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

# render <template> <output> KEY=VAL [KEY=VAL ...]  — substitutes @@KEY@@ placeholders.
# A placeholder alone on its line with an EMPTY value removes the whole line, so optional
# blocks leave no trace. The replacement is quoted: bash 5.2's patsub_replacement would
# otherwise turn every '&' in a value into the matched placeholder.
render() {
  local tmpl="$1" out="$2"; shift 2
  [ -f "$tmpl" ] || die "template not found: $tmpl"
  local content; content="$(cat "$tmpl")"
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    [ -n "$val" ] || content="$(printf '%s\n' "$content" | grep -vxF "@@${key}@@" || true)"
    content="${content//"@@${key}@@"/"${val}"}"
  done
  printf '%s\n' "$content" > "$out"
}

# Optional site entries for the boot menu, read from MENU_EXTRA_FILE (absolute, or relative to
# the repo root). One entry per line; blank lines and lines starting with '#' are ignored:
#   <name> <any|efi|pcbios> <http(s)://url> <label ...>
# Each entry adds a menu item (efi/pcbios: shown only on that platform) and a target that
# chains to <url>. Sets MENU_EXTRA_ITEMS / MENU_EXTRA_TARGETS; both empty when unset.
menu_extra_entries() {
  MENU_EXTRA_ITEMS=""; MENU_EXTRA_TARGETS=""
  local f="${MENU_EXTRA_FILE:-}"
  [ -n "$f" ] || return 0
  case "$f" in /*) ;; *) f="$ROOT/$f" ;; esac
  [ -f "$f" ] || die "MENU_EXTRA_FILE not found: $f"
  local line name platform url label n=0 seen=" "
  local reserved=" start awb fog local shell reboot failed "
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r name platform url label <<<"$line"
    [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] \
      || die "$f:$n: invalid name '$name' (a-z, 0-9, _ or -, starting with a letter)"
    [[ "$reserved" == *" $name "* ]] && die "$f:$n: name '$name' is reserved by the base menu"
    [[ "$seen" == *" $name "* ]] && die "$f:$n: duplicate name '$name'"
    case "$platform" in any|efi|pcbios) ;; *) die "$f:$n: platform must be any, efi or pcbios (got '$platform')" ;; esac
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || die "$f:$n: url must start with http:// or https:// (got '$url')"
    [[ "$url" == *"&&"* || "$url" == *"||"* ]] && die "$f:$n: url must not contain '&&' or '||' (iPXE operators)"
    [ -n "$label" ] || die "$f:$n: missing label"
    [[ "$label" == -* ]] && die "$f:$n: label must not start with '-' (iPXE would read it as an option)"
    [[ "$name$url$label" == *@@* ]] && die "$f:$n: '@@' is not allowed (template placeholder syntax)"
    [[ "$label" == *[\|\&]* ]] && die "$f:$n: label must not contain '|' or '&' (iPXE operators)"
    seen+="$name "
    if [ "$platform" = any ]; then MENU_EXTRA_ITEMS+="item $name $label"$'\n'
    else MENU_EXTRA_ITEMS+="iseq \${platform} $platform && item $name $label ||"$'\n'; fi
    MENU_EXTRA_TARGETS+=$'\n'":$name"$'\n'"chain -ar $url || goto failed"$'\n'
  done < "$f"
  MENU_EXTRA_ITEMS="${MENU_EXTRA_ITEMS%$'\n'}"
  MENU_EXTRA_TARGETS="${MENU_EXTRA_TARGETS%$'\n'}"
}

# render_menu <output> — the iPXE boot menu from config.env (+ MENU_EXTRA_FILE). Validates the
# extra entries before writing anything.
render_menu() {
  menu_extra_entries
  render "$TMPL/default.ipxe.tmpl" "$1" \
    "AWB_HOST_IP=$AWB_HOST_IP" "FOG_VM_IP=$FOG_VM_IP" "HTTP_PORT=$HTTP_PORT" \
    "AWB_KERNEL=$AWB_KERNEL" "AWB_INITRD=$AWB_INITRD" "AWB_NFS_EXPORT=$AWB_NFS_EXPORT" \
    "AWB_CMDLINE_EXTRA=$AWB_CMDLINE_EXTRA" \
    "MENU_TITLE=${MENU_TITLE:-Network boot menu}" \
    "MENU_TIMEOUT_MS=${MENU_TIMEOUT_MS:-5000}" \
    "MENU_EXTRA_ITEMS=$MENU_EXTRA_ITEMS" "MENU_EXTRA_TARGETS=$MENU_EXTRA_TARGETS"
}

# PXE prefix length from netmask (255.255.255.0 -> 24), simple common cases
prefix_from_netmask() {
  case "$1" in
    255.255.255.0) echo 24 ;; 255.255.0.0) echo 16 ;; 255.0.0.0) echo 8 ;;
    255.255.255.128) echo 25 ;; 255.255.255.192) echo 26 ;;
    *) echo 24 ;;
  esac
}
