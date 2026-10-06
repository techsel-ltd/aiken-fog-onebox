#!/usr/bin/env bash
# Tests for the boot-menu render (render_menu in scripts/lib.sh). No root, no network.
# Run: bash tests/render-menu.test.sh   — exit 0 = all passed.
# shellcheck disable=SC2016  # ${...} here are iPXE variables, meant to stay literal
# shellcheck source=/dev/null
set -uo pipefail

T="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$T/.." && pwd)"
FIX="$T/fixtures"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# render_with <out> [MENU_EXTRA_FILE value] — runs render_menu in a subshell; prints stderr, returns its status
render_with() {
  local out="$1" extra="${2-}"
  (
    set -a; . "$FIX/menu-test.conf"; set +a
    # shellcheck disable=SC2034  # read by render_menu in the sourced lib.sh
    [ -n "$extra" ] && MENU_EXTRA_FILE="$extra"
    . "$REPO/scripts/lib.sh"
    render_menu "$out"
  ) 2>"$WORK/stderr"
}

entries() { printf '%s\n' "$@" > "$WORK/extra.conf"; echo "$WORK/extra.conf"; }

# --- hook off: byte-identical to the menu rendered before the hook existed ------------------
render_with "$WORK/off.ipxe"
if cmp -s "$FIX/default.ipxe.golden" "$WORK/off.ipxe"; then ok "no MENU_EXTRA_FILE: identical to golden"
else bad "no MENU_EXTRA_FILE: identical to golden" "$(diff "$FIX/default.ipxe.golden" "$WORK/off.ipxe")"; fi

render_with "$WORK/empty.ipxe" "$(entries '# only comments' '' '   ')"
if cmp -s "$FIX/default.ipxe.golden" "$WORK/empty.ipxe"; then ok "comment-only file: identical to golden"
else bad "comment-only file: identical to golden" "$(diff "$FIX/default.ipxe.golden" "$WORK/empty.ipxe")"; fi

# --- one entry on every platform -----------------------------------------------------------
render_with "$WORK/any.ipxe" "$(entries 'tools any http://${awb-server}:${http-port}/tools.ipxe Site tools')"
expected_diff="$(cat <<'EOF'
14a15
> item tools Site tools
36a38,40
> 
> :tools
> chain -ar http://${awb-server}:${http-port}/tools.ipxe || goto failed
EOF
)"
got="$(diff "$FIX/default.ipxe.golden" "$WORK/any.ipxe")"
if [ "$got" = "$expected_diff" ]; then ok "any-platform entry: only the item + target are added"
else bad "any-platform entry: only the item + target are added" "$got"; fi

# --- UEFI-only entry: '&&' must survive (bash 5.2 patsub_replacement) -----------------------
render_with "$WORK/efi.ipxe" "$(entries 'winst efi http://${awb-server}:${http-port}/winpxe/winst.ipxe Install Windows 11')"
if grep -qxF 'iseq ${platform} efi && item winst Install Windows 11 ||' "$WORK/efi.ipxe"; then ok "efi entry: guarded item line, && intact"
else bad "efi entry: guarded item line, && intact" "$(grep -n winst "$WORK/efi.ipxe")"; fi

render_with "$WORK/bios.ipxe" "$(entries 'legacy pcbios http://example.org/x.ipxe Legacy only')"
if grep -qxF 'iseq ${platform} pcbios && item legacy Legacy only ||' "$WORK/bios.ipxe"; then ok "pcbios entry: guarded item line"
else bad "pcbios entry: guarded item line" "$(grep -n legacy "$WORK/bios.ipxe")"; fi

# --- relative path resolves against the repo root ------------------------------------------
mkdir -p "$REPO/.test-tmp"; printf 'rel any http://example.org/r.ipxe Relative\n' > "$REPO/.test-tmp/extra.conf"
render_with "$WORK/rel.ipxe" ".test-tmp/extra.conf"
if grep -qxF 'item rel Relative' "$WORK/rel.ipxe"; then ok "relative MENU_EXTRA_FILE resolves against repo root"
else bad "relative MENU_EXTRA_FILE resolves against repo root" "$(cat "$WORK/stderr")"; fi
rm -rf "$REPO/.test-tmp"

# --- invalid input is refused, and nothing is written ---------------------------------------
refuse() {  # refuse <name> <expected stderr fragment> <extra-file value>
  rm -f "$WORK/bad.ipxe"
  if render_with "$WORK/bad.ipxe" "$3"; then bad "$1: should fail" "exit 0"
  elif ! grep -qF "$2" "$WORK/stderr"; then bad "$1: message" "$(cat "$WORK/stderr")"
  elif [ -e "$WORK/bad.ipxe" ]; then bad "$1: must not write output"
  else ok "$1: refused"; fi
}
refuse "missing file"       "MENU_EXTRA_FILE not found"         "$WORK/does-not-exist.conf"
refuse "reserved name"      "reserved"          "$(entries 'awb any http://x.org/a.ipxe Clash')"
refuse "bad name"           "invalid name"      "$(entries 'Bad!Name any http://x.org/a.ipxe X')"
refuse "bad platform"       "platform"          "$(entries 'x arm http://x.org/a.ipxe X')"
refuse "non-http url"       "url"               "$(entries 'x any tftp://x.org/a.ipxe X')"
refuse "missing label"      "label"             "$(entries 'x any http://x.org/a.ipxe')"
refuse "duplicate name"     "duplicate"         "$(entries 'x any http://x.org/a.ipxe A' 'x any http://x.org/b.ipxe B')"
refuse "placeholder in label" "@@"              "$(entries 'x any http://x.org/a.ipxe Evil @@MENU_TITLE@@')"
refuse "operator in label"   "must not contain"  "$(entries 'x any http://x.org/a.ipxe A || B')"
refuse "&& in url"           "url must not contain"  "$(entries 'x any http://x.org/b?a=1&&b=2 X')"
refuse "|| in url"           "url must not contain"  "$(entries 'x any http://x.org/b||c X')"
refuse "label starts with -" "must not start with"   "$(entries 'w any http://x.org/a.ipxe --gap Oops')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
