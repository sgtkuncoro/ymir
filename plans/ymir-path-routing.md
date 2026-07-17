# Blueprint: ymir path routing + per-spoke targeting

Objective: let a hub path map to a different destination path on a spoke, and let a
path be delivered to specific spokes only, instead of "same path, all spokes".

Status: REVIEWED (adversarial review incorporated; ready to implement)
Mode: git present (origin github.com/sgtkuncoro/ymir, default branch `main`).
Repo convention is commit-directly-to-`main` (single-writer personal repo), so each
step below is one focused commit on `main`. Rollback = `git revert <sha>`.

Review: architect pass raised C1-C3 (data-loss/security) + M1-M3 (silent mismatch);
all folded into the Design and Steps below. See "Review fixes" tags inline.

---

## Problem (why this plan exists)

Today the manifest (`~/.config/ymir/paths.list` on the hub) is a flat list of
HOME-relative paths. `sync` copies `hub:~/<rel>` -> `spoke:~/<rel>` for **every**
entry on **every** spoke. There is:
- no source->destination mapping (a path must land at the same relative location), and
- no per-spoke targeting (you cannot send a path to laptop-a but not laptop-b).

Question this answers: "how do we know a hub path is for a specific spoke path?" ->
each manifest entry gains an optional destination and an optional target list.

## Design (the contract every step implements)

### Manifest v2 line grammar (backward compatible)

```
SRC [-> DEST] [@NODE[,NODE...]]
```

- `SRC`  HOME-relative source path on the hub (required).
- `DEST` HOME-relative destination on the spoke (optional; defaults to `SRC`).
- `@NODE,...` comma list of spoke node names this entry applies to (optional;
  absent = all spokes). Node names are canonicalized lowercase.

Existing plain lines (`.zshrc`, `.config/nvim`) parse as `SRC=DEST`, all spokes -> no
migration. Examples:

```
.zshrc
.config/work.gitconfig -> .gitconfig @work-laptop
.config/nvim @home-laptop,travel-laptop
```

Parsing (pure bash 3.2, no arrays): split on the LAST ` @` for targets, then on the
FIRST ` -> ` for dest. Trim each field with `${x#"${x%%[![:space:]]*}"}` /
`${x%"${x##*[![:space:]]}"}` so a trailing `\r` (CRLF manifest) is stripped [m2].
Strip a trailing `/` from `DEST` before appending the dir suffix [m2].

### DEST validation (security) [C3, M1]

`DEST` is a free-text, hand-editable field. Before it is ever used as `$HOME/$DEST`:
- reject a leading `/` (absolute) and any `..` path segment -> skip+warn (never `die`
  mid-sync; log and continue with the other entries).
- `ymir add --to DEST` runs `DEST` through `to_rel` first and rejects anything that
  resolves outside `$HOME`.

### Node identity [M3, m4]

New per-machine config value `NODE_NAME` identifies a spoke for `@` targeting.
Derive (canonical lowercase, both branches):
`NODE_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"; NODE_NAME="$(printf '%s' "$NODE_NAME" | tr 'A-Z' 'a-z')"`.
`--for` values and `@` targets are lowercased at write and matched case-insensitively.
If `NODE_NAME` is empty AND any parsed entry has targets, `warn` once (targets would
silently never apply otherwise).

### Sync rule [C1, C2, m6]

For each raw line:
1. `parse_entry` FIRST unconditionally resets `E_SRC="" E_DEST="" E_TARGETS=""`, then
   parses, then `E_DEST=${E_DEST:-$E_SRC}`. (Prevents a targeted line leaking its
   target/dest into the next plain line.) [C1]
2. Validate `E_DEST` (see above); invalid -> skip+warn.
3. `entry_applies` (targets empty OR NODE_NAME in list) checked BEFORE any `hub_exec`
   round trip; not-applies -> `skip=$((skip+1)); continue`. [m6]
4. rsync `hub:E_SRC` -> `$HOME/E_DEST` (dir/file suffix from `test -d E_SRC`).
5. `--delete` (MIRROR=1) is applied ONLY when `E_DEST == E_SRC`. A remapped DEST never
   mirror-deletes, so a line like `x -> .config` can never wipe unrelated `~/.config`
   subtrees. [C2]

### rm matching [M2, m3]

`rm SRC` must match the SRC field only, not the whole line and not as a regex. Decode
each manifest line's SRC (same split rule) and compare for string equality. `--for
NODES` removes only entries whose (normalized: lowercased, comma-sorted, space-
stripped) target list equals the normalized NODES; without `--for`, remove all entries
with that SRC. Never use bare `grep` for this.

### Constraints / non-goals

- Paths still may not contain spaces, ` -> `, ` @`, or single quotes (documented; a
  pre-existing flat line containing a literal ` @` would re-parse as a target -> noted
  in docs as a migration caveat) [m1, m8].
- Directory remap uses rsync contents-merge semantics (`dir/ -> other/`); documented
  explicitly so it is not surprising [m10].
- Secret guard still applies to `SRC`. Still one-way pull; no write-back. No wildcard
  targets.

---

## Steps

### Step 1 - Parser, identity, sourcing guard, tests  [model: strongest]

Context brief: `bin/ymir` reads via `read_manifest()` (~line 123); defaults ~line 24;
`cmd_init` template ~line 130; `load_cfg` ~line 64; `main "$@"` runs at file bottom.

Tasks:
1. Add `NODE_NAME=""` to defaults + `cmd_init` template (comment: "this spoke's
   identity for @targeting; default = local hostname, lowercased").
2. In `load_cfg`, derive `NODE_NAME` lowercased from LocalHostName else `hostname -s`
   when empty [M3].
3. Add `parse_entry LINE`: reset E_SRC/E_DEST/E_TARGETS first [C1]; split last ` @`
   then first ` -> `; trim (incl `\r`) [m2]; strip trailing `/` from E_DEST [m2];
   `E_DEST=${E_DEST:-$E_SRC}`.
4. Add `dest_ok DEST` -> false on leading `/` or any `..` segment [C3].
5. Add `entry_applies` -> case-insensitive membership; empty targets = all.
6. Guard the bottom of the file: `[ "${BASH_SOURCE[0]}" = "${0}" ] && main "$@"` so it
   can be sourced for unit tests [m5].
7. Add `tests/parse.sh`: source ymir, assert parse of plain / dest-only / target-only /
   dest+target, AND plain-line-after-targeted yields empty targets [C1 regression],
   dest_ok rejects `../x` and `/x`, entry_applies case-insensitive [m9].

Verification: `bash tests/parse.sh` all pass; `bash -n bin/ymir` clean; existing local
smoke (seed+pull of plain lines) unchanged.
Exit: parser+identity+guard+tests committed; no behavior change for plain lines.

### Step 2 - Routing-aware sync  [model: default]  (depends: Step 1)

Context brief: `cmd_sync` loop ~lines 285-301.

Tasks:
1. Init `skip=0` under set -u [m6].
2. Per line: `parse_entry`; `dest_ok "$E_DEST"` false -> warn+skip; `entry_applies`
   false -> skip++ + continue BEFORE the `test -d` round trip [m6].
3. rsync uses `E_SRC` (hub) and `E_DEST` (`$HOME/$E_DEST`); `mkdir -p` dest parent;
   dir suffix from `test -d E_SRC`.
4. Apply `--delete` only when `E_DEST = E_SRC` [C2].
5. Summary line reports synced / skipped / failed.

Verification (local transport, NODE_NAME set): `.a -> .b` lands at `~/.b`; `.c @x`
pulled when NODE_NAME=x, skipped when =y; plain line -> same path; MIRROR=1 with a
remap does NOT delete the dest siblings (assert an unrelated file under dest survives);
plain-after-targeted still pulls (C1). `bash -n` clean.
Exit: sync honors dest + targets + safe delete-gating; plain behavior intact.

### Step 3 - add/rm/list/status routing  [model: default]  (depends: Step 2)

Context brief: `cmd_add` ~228, `cmd_rm` ~259, `cmd_list` ~165, `cmd_status` ~308.

Tasks:
1. `cmd_add`: parse `--to DEST` (requires exactly ONE path; multi-path -> error),
   `--for NODES`. Normalize DEST via `to_rel` + `dest_ok` (reject outside HOME) [M1,C3];
   lowercase+sort+strip NODES [m3]. Compose `SRC[ -> DEST][ @NODES]`; dedup on composed
   line. Seed keyed on SRC only.
2. `cmd_rm`: decode SRC per line and compare equal (no bare grep) [M2]; `--for` removes
   only entries whose normalized targets equal normalized NODES [m3]; else all with SRC.
3. `cmd_list`: render `SRC[ -> DEST][ @nodes]` (omit `-> DEST` when equal, `@` when all).
4. `cmd_status`: print this machine's `NODE_NAME` and count of applicable entries;
   warn if NODE_NAME empty while targeted entries exist [m4].
5. Update `usage` + `help_topic` for add/rm flags.

Verification: `add --to .b .a` -> `.a -> .b`; `add --for X .c` -> `.c @x`;
`add --to x .a .b` errors; `add --to ../evil .a` rejected; `rm .a` drops only `.a` (not
`.abc`); `list` renders; `bash -n` clean.
Exit: routing fully manageable from the CLI; help updated.

### Step 4 - setup NODE_NAME + docs  [model: default]  (depends: Step 3)

Context brief: `cmd_setup` spoke branch + heredoc; docs README/GUIDE/capability.

Tasks:
1. `cmd_setup`: on a spoke, prompt `NODE_NAME` (default derived) and write it; show in
   summary.
2. GUIDE.md: "Path routing and per-spoke targeting" section (grammar, examples, --to/
   --for, NODE_NAME, DEST safety, dir-merge semantics [m10], legacy ` @` caveat [m1]);
   add keys to config table + command reference.
3. README.md: short routing example + NODE_NAME row.
4. capability doc: mark routing/targeting delivered.
5. Keep everything generic (no real machine names).

Verification: `ymir setup` (pty + non-interactive) writes NODE_NAME; docs fences
balanced; `bash -n` clean; full regression (plain + mapped + targeted + MIRROR-safe).
Exit: identity configurable; routing documented.

---

## Dependency graph

```
Step1 -> Step2 -> Step3 -> Step4
```

All steps edit `bin/ymir`, so strictly serial (shared file = no parallelism). Total: 4
commits on `main`.

## Invariants verified after every step

- `bash tests/parse.sh` + `bash -n bin/ymir` pass.
- Flat-manifest behavior unchanged (back-compat).
- Local-transport smoke (seed-up + pull-down) passes.
- No real machine names / IPs / usernames introduced.
- No manifest entry can write outside `$HOME`; MIRROR never deletes a remapped dest.

## Resolved review findings

C1 parser reset - Step 1.3/1.7. C2 delete-gating - Step 2.4. C3 DEST traversal -
Step 1.4 + Step 2.2 + Step 3.1. M1 --to via to_rel - Step 3.1. M2 rm SRC-field -
Step 3.2. M3 NODE_NAME case - Design + Step 1.2/3.1. m2 trim/CRLF/slash - Step 1.3.
m4 empty-NODE_NAME warn - Step 3.4. m5 source guard - Step 1.6. m6 skip init/order -
Step 2.1-2. m9 tests - Step 1.7. m1/m10 doc caveats - Step 4.2.

## Remaining accepted risks (documented, not fixed)

- m7 dedup on raw composed line (near-dup on hand-edit) - acceptable.
- m8 single-quote in path breaks remote manifest write - forbidden by constraints doc.
