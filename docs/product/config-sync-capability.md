# Capability: Sync/Mirror Config Paths Across the Tailnet

Status: IMPLEMENTED as publish/subscribe (hub shares a catalog; each spoke subscribes and
chooses local placement via `--to`). Tool: bin/ymir. See docs/GUIDE.md.
Date: 2026-07-17
Owner: (you)

## CAPABILITY

As the operator of a personal Apple tailnet (3 Macs + iPad + iPhone), I want selected
local paths (shell/app config, dotfiles, project settings) to stay in sync across my
Macs over Tailscale so that editing config on one machine propagates to the others
without a cloud provider and without exposing the traffic to the public internet.

## REQUIREMENT UPDATE: paths are addable/removable (2026-07-17)

The synced set is NOT hardcoded. The operator must be able to add a path and remove
a path at any time, and the change applies across all Mac peers. This makes a single
**manifest** the source of truth for "what is synced", plus a tiny wrapper CLI:

    pathsync add  <path>     # start syncing a file/dir
    pathsync rm   <path>     # stop syncing it (leaves local copy in place)
    pathsync list            # show managed paths
    pathsync sync            # run one reconcile now
    pathsync status          # peers reachable + last run

Manifest lives at `~/.config/pathsync/paths.list` (one path per line, `#` comments,
`!glob` exclude lines). The manifest itself is synced first, so `add`/`rm` on one Mac
propagates the managed set to the others.

Design choice: keep files **in place** (no symlink-store) so apps that don't follow
symlinks keep working and there is no destructive relink step. `add`/`rm` only edit the
manifest; the engine reads the manifest each run.

Underlying engine is chosen by direction (see OPEN QUESTIONS Q2):
- one-way push from hub  -> GNU rsync driven by the manifest (`--files-from`)
- true 2-way multi-writer -> Unison invoked once per manifest root, or Syncthing with
  the wrapper calling its REST API to create/remove a shared folder per path.

## ENVIRONMENT (assumed)

A personal Apple tailnet under a single user account:

| Node       | OS     | Role for sync            |
|------------|--------|--------------------------|
| laptop-a   | macOS  | spoke (this machine)     |
| hub        | macOS  | always-on hub candidate  |
| laptop-b   | macOS  | spoke                    |
| tablet     | iOS    | read/consume only        |
| phone      | iOS    | read/consume only        |

Facts that constrain the design:
- Tailscale up on all nodes. Do not point Funnel at synced paths.
- Tailscale SSH may be OFF by default. Any SSH-based option needs it enabled
  (`sudo tailscale set --ssh`), or macOS Remote Login enabled, on the target node(s).
- `brew` on Apple Silicon lives at `/opt/homebrew` -> installing tools is easy.
- System `rsync` is Apple **openrsync** (protocol 29), missing many GNU rsync 3.x
  flags. For scripted mirroring install GNU rsync: `brew install rsync`.
- iOS nodes cannot run Syncthing/Unison/rsync as background daemons. They can only
  participate via on-demand apps (Mobius Sync for Syncthing, Working Copy, a WebDAV
  client for Taildrive). Treat tablet/phone as read/consume endpoints, not sync peers.

## CONSTRAINTS (fixed rules and boundaries)

- Transport MUST stay inside the tailnet (100.x addresses / MagicDNS names). No public
  exposure of config data. Funnel is unrelated and must not be pointed at synced paths.
- Config files are often **machine-specific** (absolute paths, host names, secrets).
  A blind mirror WILL clobber per-host differences. Decide per path: identical-everywhere
  vs machine-templated.
- Secrets (SSH keys, tokens, `~/.aws/credentials`, keychains) MUST NOT be synced in the
  clear by default. Exclude them or hand them to a secret manager.
- Sync must survive reboots (launchd / login-item), not depend on a terminal being open.
- Bidirectional sync REQUIRES conflict handling. Last-write-wins silent overwrite is a
  data-loss bug for config.

## OPTIONS (researched)

Tailscale is only the secure network layer. It does not sync files by itself. Pair it
with one of these:

### A. Syncthing over Tailscale  (recommended for "set and forget" mirror)
- Continuous, bidirectional, P2P, versioned, has conflict files, GUI.
- Bind it to Tailscale IPs so all traffic rides WireGuard; disable global discovery/relays.
- Best when you want a live mirror of one or more folders across the 3 Macs.
- iOS: possible via Mobius Sync (paid, foreground-limited), so keep phones out of scope.
- Cost: a background daemon + periodic rescans. Overkill for a handful of dotfiles.

### B. Unison + Tailscale SSH + launchd  (recommended for controlled config sync)
- Bidirectional with real conflict resolution; `repeat = watch` gives near-real-time.
- Uses `ssh://name//path`; with Tailscale SSH you skip managing SSH keys.
- launchd `KeepAlive` keeps it running across reboots.
- Both ends need the SAME Unison major version (`brew install unison`).
- Best when config correctness matters and you want auditable, reviewable sync.

### C. rsync over Tailscale SSH  (simplest, one-way mirror)
- One-direction mirror (hub -> spokes or spoke -> hub). No conflict logic.
- Trigger on a schedule (launchd) or manually. Great for "push my canonical config out".
- Use `brew install rsync` (GNU) not system openrsync for `-a --delete --exclude-from`.
- Best for a single source-of-truth model where one Mac owns the config.

### D. chezmoi/Stow + git (+ Tailscale only as a private git remote)  (recommended for dotfiles)
- Purpose-built for dotfiles: templating for per-host values, secret injection, history.
- Transport is `git push/pull`; you can host the bare repo on the always-on Mac and reach
  it over the tailnet, so nothing touches a third party.
- Best specifically for shell/editor/tool dotfiles that differ slightly per machine.

### E. Taildrive  (NOT a sync tool)
- `tailscale drive share <name> <path>` mounts a remote folder over WebDAV.
- Access remote files live; it does not mirror or keep local copies in sync. Use only
  for occasional remote access, not the stated goal.

## RECOMMENDATION

Split by data type instead of forcing one tool:

1. Dotfiles / shell / editor / tool config that varies per host -> **D. chezmoi + git**,
   with the bare repo on the hub reached over the tailnet.
2. Bulk "keep these folders identical" config (e.g. an app's settings dir, notes, a
   project config tree) -> **A. Syncthing** bound to Tailscale IPs, Macs only.
3. If you prefer explicit control over a small, high-value config set and want conflict
   review -> **B. Unison + Tailscale SSH + launchd** instead of Syncthing.

The always-on Mac (the hub) is the natural source-of-truth for options B, C, D.

## IMPLEMENTATION CONTRACT

Actors
- Operator (you): defines which paths sync and the per-path policy.
- Hub node (always-on Mac): canonical store / git remote / rsync source.
- Spoke Macs (laptops): sync peers.
- iOS nodes: consume-only, out of automated scope.

Surfaces
- Tailscale (network), chosen sync engine (Syncthing/Unison/rsync/chezmoi), launchd
  (persistence), git (for chezmoi).

States and transitions (bidirectional engines)
- idle -> scanning -> transferring -> idle
- transferring -> conflict (both sides changed same file) -> resolved (keep-both /
  newer-wins / manual). Conflict MUST be visible, never silent.
- node offline -> queued -> reconciled on reconnect.

Interface / data implications
- A per-path policy list: `path | direction (1-way/2-way) | scope (identical/templated) |
  secrets? | exclude globs`.
- launchd plists per engine under `~/Library/LaunchAgents/`.
- For chezmoi: a git repo (`~/.local/share/chezmoi`) + a bare remote on the hub.
- Enable Tailscale SSH (`sudo tailscale set --ssh`) on any node that is an SSH target,
  or enable macOS Remote Login for those nodes.

Observability / operator requirements
- Logs to `/tmp/<engine>.log`; a `tailscale status` check confirms peers reachable.
- A dry-run before first real sync (rsync `-n`, Unison shows the plan, Syncthing initial
  scan) to avoid a first-run clobber.

## NON-GOALS

- Not building a general cloud file service or exposing anything via Funnel.
- Not syncing secrets/keychains in the clear.
- Not automating iOS nodes (hard platform limit; consume-only).
- Not choosing Taildrive as the sync mechanism (wrong tool for mirroring).

## OPEN QUESTIONS (blockers before build)

1. Which exact paths? (e.g. `~/.config`, `~/.zshrc`, a specific app's support dir, a
   projects/ tree.) Needed to set per-path policy.
2. One source-of-truth (push model) or true multi-writer (2-way)? Determines rsync vs
   Unison/Syncthing.
3. Are any target paths identical-everywhere or do they need per-host values? Determines
   chezmoi vs raw mirror.
4. OK to enable Tailscale SSH on the hub / spokes (needed for B and C)?
5. Any secrets inside the chosen paths that must be excluded or vaulted?

## HANDOFF

Ready for implementation once Q1-Q5 are answered. Recommended next lane:
`workspace-surface-audit` to confirm what config actually lives where, then a direct
implementation pass (install engine, write launchd plist, dry-run, enable) for the
chosen option. `verification-loop` to prove sync + conflict behavior end to end.
