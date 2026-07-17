#!/usr/bin/env bash
# Unit tests for ymir's parse_entry / dest_ok (sourced, main not run).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
# isolate from the host home so sourcing/config lookups never touch real files
HOME="$(mktemp -d "${TMPDIR:-/tmp}/ymir-parse.XXXXXX")"; export HOME
YMIR_CFG_DIR="$HOME/.config/ymir"; export YMIR_CFG_DIR
trap 'rm -rf "$HOME"' EXIT
# shellcheck disable=SC1090
source "$here/bin/ymir"
set +e

fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1  want[$3] got[$2]"; fail=1; fi; }
ok_rc()  { if "$@"; then echo "ok: accept ($*)"; else echo "FAIL: should accept ($*)"; fail=1; fi; }
bad_rc() { if "$@"; then echo "FAIL: should reject ($*)"; fail=1; else echo "ok: reject ($*)"; fi; }

# plain line -> src == dest
parse_entry ".zshrc";        ck plain-src  "$E_SRC" ".zshrc";  ck plain-dest "$E_DEST" ".zshrc"
# mapped line
parse_entry ".a -> .b";      ck map-src    "$E_SRC" ".a";      ck map-dest  "$E_DEST" ".b"
# C1: plain line AFTER a mapped line must NOT inherit the previous dest
parse_entry ".c";            ck reset-dest "$E_DEST" ".c"
# trailing slash stripped on dest
parse_entry ".d -> .e/";     ck trailslash "$E_DEST" ".e"
# trailing slash stripped on source too
parse_entry ".d/ -> .e";     ck src-trailslash "$E_SRC" ".d"
# surrounding whitespace trimmed
parse_entry "  .f  ->  .g "; ck trim-src   "$E_SRC" ".f";      ck trim-dest "$E_DEST" ".g"

# dest_ok
ok_rc  dest_ok ".config/x"
bad_rc dest_ok "/etc/x"
bad_rc dest_ok "../x"
bad_rc dest_ok "a/../b"

exit $fail
