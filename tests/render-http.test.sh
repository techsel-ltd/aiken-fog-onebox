#!/usr/bin/env bash
# Tests for the HTTP-boot lighttpd.conf render (render_http_conf in scripts/lib.sh). No root, no network.
# Run: bash tests/render-http.test.sh   — exit 0 = all passed.
# shellcheck source=/dev/null
set -uo pipefail

T="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$T/.." && pwd)"
FIX="$T/fixtures"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# render_with <out> [HTTP_EXTRA_CONF value] — runs render_http_conf in a subshell; stderr to $WORK/stderr
render_with() {
  local out="$1" extra="${2-}"
  (
    set -a; . "$FIX/menu-test.conf"; set +a
    # shellcheck disable=SC2034  # read by render_http_conf in the sourced lib.sh
    TFTP_ROOT=/awbcboot
    # shellcheck disable=SC2034
    [ -n "$extra" ] && HTTP_EXTRA_CONF="$extra"
    . "$REPO/scripts/lib.sh"
    render_http_conf "$out"
  ) 2>"$WORK/stderr"
}

# --- hook off: the stock file, access log on, no include line -------------------------------
render_with "$WORK/off.conf"
if cmp -s "$FIX/lighttpd.conf.golden" "$WORK/off.conf"; then ok "no HTTP_EXTRA_CONF: identical to golden"
else bad "no HTTP_EXTRA_CONF: identical to golden" "$(diff "$FIX/lighttpd.conf.golden" "$WORK/off.conf")"; fi
if grep -q '@@' "$WORK/off.conf"; then bad "no placeholder left (off)"; else ok "no placeholder left (off)"; fi

# --- absolute path: golden + one include line at the end ------------------------------------
# shellcheck disable=SC2016  # $SERVER is lighttpd syntax, meant to stay literal
printf '$SERVER["socket"] == "10.10.0.1:8081" { server.document-root = "/srv/x" }\n' > "$WORK/extra.conf"
render_with "$WORK/on.conf" "$WORK/extra.conf"
want="$(cat "$FIX/lighttpd.conf.golden"; printf 'include "%s"\n' "$WORK/extra.conf")"
if [ "$(cat "$WORK/on.conf")" = "$want" ]; then ok "absolute path: golden + include at the end"
else bad "absolute path: golden + include at the end" "$(diff <(printf '%s\n' "$want") "$WORK/on.conf")"; fi

# --- relative path: taken from the repo root ------------------------------------------------
render_with "$WORK/rel.conf" "tests/fixtures/lighttpd.conf.golden"
if tail -n 1 "$WORK/rel.conf" | grep -qxF "include \"$REPO/tests/fixtures/lighttpd.conf.golden\""; then
  ok "relative path resolved from the repo root"
else bad "relative path resolved from the repo root" "$(tail -n 1 "$WORK/rel.conf")"; fi

# --- refusals: nothing written --------------------------------------------------------------
if render_with "$WORK/missing.conf" "$WORK/nope.conf"; then bad "missing file refused"
elif grep -q 'HTTP_EXTRA_CONF not found' "$WORK/stderr" && [ ! -e "$WORK/missing.conf" ]; then ok "missing file refused, nothing written"
else bad "missing file refused, nothing written" "$(cat "$WORK/stderr")"; fi

q="$WORK/bad\"name.conf"; : > "$q"
if render_with "$WORK/quote.conf" "$q"; then bad "path with a quote refused"
elif grep -q 'must not contain' "$WORK/stderr" && [ ! -e "$WORK/quote.conf" ]; then ok "path with a quote refused, nothing written"
else bad "path with a quote refused, nothing written" "$(cat "$WORK/stderr")"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
