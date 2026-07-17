#!/usr/bin/env bash
# Behavior tests for ymir over the `local` transport (no network, two fake homes).
# ymir runs as a subprocess so its `set -euo pipefail` stays contained here.
# This runner deliberately does NOT use `set -e` (assertions must tally, not abort);
# setup commands that must succeed are wrapped in `must` so a broken arrange step
# fails loudly instead of producing a false pass.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YMIR="$ROOT/bin/ymir"
TESTS=0; FAILS=0

pass() { TESTS=$((TESTS+1)); printf 'ok %d - %s\n' "$TESTS" "$1"; }
fail() { TESTS=$((TESTS+1)); FAILS=$((FAILS+1)); printf 'not ok %d - %s\n' "$TESTS" "$1"
         [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/#   /'; return 0; }

assert_eq()      { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want: [$3]"$'\n'"got : [$2]"; fi; }
assert_rc()      { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want rc $2, got rc $3"; fi; }
assert_file_eq() { if [ -f "$2" ] && [ "$(cat "$2")" = "$3" ]; then pass "$1"
                   else fail "$1" "file $2"$'\n'"want: [$3]"$'\n'"got : [$([ -f "$2" ] && cat "$2" || echo '<missing>')]"; fi; }
assert_present() { if [ -e "$2" ]; then pass "$1"; else fail "$1" "expected to exist: $2"; fi; }
assert_absent()  { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "expected absent: $2"; fi; }
assert_contains(){ case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to contain: [$3]"$'\n'"in: [$2]" ;; esac; }

setup_case() { # setup_case [extra spoke config lines...]
  local base="${TMPDIR:-/tmp}"; base="${base%/}"   # avoid // when TMPDIR ends in / (macOS)
  CASE_DIR="$(mktemp -d "$base/ymir.XXXXXX")"
  HUBH="$CASE_DIR/hub"; SPOKEH="$CASE_DIR/spoke"
  mkdir -p "$HUBH/.config/ymir" "$SPOKEH/.config/ymir"
  printf 'IS_HUB="1"\n' > "$HUBH/.config/ymir/config"
  { printf 'IS_HUB="0"\nTRANSPORT="local"\nHUB_ROOT="%s"\n' "$HUBH"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$SPOKEH/.config/ymir/config"
}
teardown_case() { [ -n "${CASE_DIR:-}" ] && rm -rf "$CASE_DIR"; CASE_DIR=; }
trap 'teardown_case' EXIT

hub()   { ( cd "$HUBH"   && HOME="$HUBH"   YMIR_CFG_DIR="$HUBH/.config/ymir"   bash "$YMIR" "$@" ); }
spoke() { ( cd "$SPOKEH" && HOME="$SPOKEH" YMIR_CFG_DIR="$SPOKEH/.config/ymir" bash "$YMIR" "$@" ); }
# act: capture stdout/stderr/rc separately (rc read on its own line).
run()   { OUT="$( "$@" 2>"$CASE_DIR/.err" )"; RC=$?; ERR="$(cat "$CASE_DIR/.err")"; }
# arrange: a setup step that MUST succeed; abort the suite loudly if it does not.
must()  { if ! "$@" >/dev/null 2>&1; then printf 'SETUP FAILED (rc %d): %s\n' "$?" "$*" >&2; exit 1; fi; }

HUB_CAT() { echo "$HUBH/.config/ymir/shares.list"; }
SP_SUBS() { echo "$SPOKEH/.config/ymir/paths.list"; }

# ---- cases --------------------------------------------------------------
t_pub_secret_pubs() {
  setup_case
  echo ZSH > "$HUBH/.zshrc"; echo KEY > "$HUBH/id_rsa"
  run hub pub .zshrc;  assert_rc "pub .zshrc rc" 0 "$RC"
  run hub pub id_rsa;  assert_rc "pub id_rsa rc" 0 "$RC"
  assert_contains "pub secret refused" "$ERR" "refusing secret-looking"
  assert_file_eq "catalog has only .zshrc" "$(HUB_CAT)" ".zshrc"
}

t_sub_plain() {
  setup_case; echo ZSH > "$HUBH/.zshrc"; must hub pub .zshrc
  run spoke sub .zshrc; assert_rc "sub plain rc" 0 "$RC"
  assert_file_eq "subs plain line" "$(SP_SUBS)" ".zshrc"
}

t_sub_map() {
  setup_case; echo WG > "$HUBH/work.gitconfig"; must hub pub work.gitconfig
  run spoke sub --from work.gitconfig --to .gitconfig; assert_rc "sub map rc" 0 "$RC"
  assert_file_eq "subs mapped line" "$(SP_SUBS)" "work.gitconfig -> .gitconfig"
}

t_sub_all() {
  setup_case; echo A > "$HUBH/.a"; echo B > "$HUBH/.b"
  must hub pub .a; must hub pub .b
  run spoke sub --all; assert_rc "sub --all rc" 0 "$RC"
  assert_file_eq "subs all lines" "$(SP_SUBS)" $'.a\n.b'
}

t_sub_unsafe_dest() {
  setup_case; echo A > "$HUBH/.a"; must hub pub .a
  run spoke sub --from .a --to '../evil'
  assert_rc "unsafe dest rejected rc" 1 "$RC"
  assert_contains "unsafe dest message" "$ERR" "unsafe destination"
  assert_file_eq "no subscription written" "$(SP_SUBS)" ""
}

t_sub_mix_guard() {
  setup_case; echo A > "$HUBH/.a"; echo B > "$HUBH/.b"
  must hub pub .a; must hub pub .b
  run spoke sub --from .a .b
  assert_rc "mix guard rc" 1 "$RC"
  assert_contains "mix guard message" "$ERR" "do not mix --from with positional"
}

t_sync_plain() {
  setup_case; echo ZSH > "$HUBH/.zshrc"; must hub pub .zshrc; must spoke sub .zshrc
  run spoke sync; assert_rc "sync plain rc" 0 "$RC"
  assert_file_eq "same-path file landed" "$SPOKEH/.zshrc" "ZSH"
}

t_sync_map() {
  setup_case; echo WG > "$HUBH/work.gitconfig"; must hub pub work.gitconfig
  must spoke sub --from work.gitconfig --to .gitconfig
  run spoke sync; assert_rc "sync map rc" 0 "$RC"
  assert_file_eq "mapped file landed" "$SPOKEH/.gitconfig" "WG"
}

t_sync_dir() {
  setup_case; mkdir -p "$HUBH/.config/nvim"; echo V > "$HUBH/.config/nvim/init.vim"
  must hub pub .config/nvim
  must spoke sub --from .config/nvim --to .config/nvim2
  run spoke sync; assert_rc "sync dir rc" 0 "$RC"
  assert_file_eq "dir remapped recursively" "$SPOKEH/.config/nvim2/init.vim" "V"
}

t_sync_gate() {
  setup_case; echo A > "$HUBH/.a"; must hub pub .a
  must spoke sub .a
  printf '.unshared\n' >> "$(SP_SUBS)"      # subscribed but hub never published it
  run spoke sync; assert_rc "sync gate rc" 0 "$RC"
  assert_contains "gatekeep warning" "$ERR" "not shared by hub, skipped: .unshared"
  assert_contains "gatekeep skip count" "$OUT" "skipped 1"
  assert_absent "unshared not pulled" "$SPOKEH/.unshared"
  assert_file_eq "shared pulled" "$SPOKEH/.a" "A"
}

t_mirror_remap_safe() {
  setup_case 'MIRROR="1"'
  mkdir -p "$HUBH/share"; echo A > "$HUBH/share/a.txt"; must hub pub share
  must spoke sub --from share --to dest
  mkdir -p "$SPOKEH/dest"; echo KEEP > "$SPOKEH/dest/keep.txt"
  run spoke sync; assert_rc "mirror remap rc" 0 "$RC"
  assert_file_eq "unrelated sibling survives" "$SPOKEH/dest/keep.txt" "KEEP"
  assert_file_eq "remapped content pulled" "$SPOKEH/dest/a.txt" "A"
}

t_mirror_samepath_delete() {
  setup_case 'MIRROR="1"'
  mkdir -p "$HUBH/share"; echo A > "$HUBH/share/a.txt"; must hub pub share
  must spoke sub share
  mkdir -p "$SPOKEH/share"; echo OLD > "$SPOKEH/share/stale.txt"
  run spoke sync; assert_rc "mirror samepath rc" 0 "$RC"
  assert_file_eq "same-path content pulled" "$SPOKEH/share/a.txt" "A"
  assert_absent "same-path stale pruned" "$SPOKEH/share/stale.txt"
}

t_unsub_src_only() {
  setup_case
  printf '%s\n' '.a -> .b' '.abc' '.x -> .a' > "$(SP_SUBS)"
  run spoke unsub .a; assert_rc "unsub rc" 0 "$RC"
  assert_file_eq "unsub removed only SRC .a" "$(SP_SUBS)" $'.abc\n.x -> .a'
}

t_push() {
  setup_case; echo P > "$SPOKEH/starship.toml"
  run spoke push starship.toml; assert_rc "push rc" 0 "$RC"
  assert_file_eq "push landed on hub" "$HUBH/starship.toml" "P"
  assert_contains "push added to catalog" "$(cat "$(HUB_CAT)")" "starship.toml"
}

t_alias_add_hub() {   # `add` on the hub == pub
  setup_case; echo A > "$HUBH/.a"
  run hub add .a; assert_rc "add-on-hub rc" 0 "$RC"
  assert_file_eq "add-on-hub published" "$(HUB_CAT)" ".a"
}

t_alias_add_spoke() { # `add` on a spoke == sub
  setup_case; echo A > "$HUBH/.a"; must hub pub .a
  run spoke add .a; assert_rc "add-on-spoke rc" 0 "$RC"
  assert_file_eq "add-on-spoke subscribed" "$(SP_SUBS)" ".a"
}

t_role_pub_on_spoke() {
  setup_case
  run spoke pub .zshrc
  assert_rc "pub on spoke rejected rc" 1 "$RC"
  assert_contains "pub on spoke message" "$ERR" "run 'pub' on the hub"
  assert_absent "spoke published nothing" "$SPOKEH/.config/ymir/shares.list"
}

t_role_sub_on_hub() {
  setup_case
  run hub sub .zshrc
  assert_rc "sub on hub rejected rc" 1 "$RC"
  assert_contains "sub on hub message" "$ERR" "run 'sub' on a spoke"
  assert_absent "hub subscribed nothing" "$HUBH/.config/ymir/paths.list"
}

# ---- driver -------------------------------------------------------------
for t in t_pub_secret_pubs t_sub_plain t_sub_map t_sub_all t_sub_unsafe_dest \
         t_sub_mix_guard t_sync_plain t_sync_map t_sync_dir t_sync_gate \
         t_mirror_remap_safe t_mirror_samepath_delete t_unsub_src_only t_push \
         t_alias_add_hub t_alias_add_spoke t_role_pub_on_spoke t_role_sub_on_hub; do
  if ! "$t"; then FAILS=$((FAILS+1)); printf 'not ok - %s (test function crashed)\n' "$t"; fi
  teardown_case
done

printf '1..%d\n# passed %d, failed %d\n' "$TESTS" "$((TESTS-FAILS))" "$FAILS"
[ "$FAILS" -eq 0 ]
