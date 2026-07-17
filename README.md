# ymirr

Pull-sync a **managed, add/removable list** of config paths from one hub to your other
Macs, entirely over your Tailscale tailnet. No cloud, no public exposure.

- **Hub** (`macminim4`) is the source of truth: it owns the manifest and canonical files.
- **Spokes** pull the manifest and every listed path from the hub.
- Paths are stored **HOME-relative**, so different local usernames map correctly
  (hub `sk...` vs laptop `sky0` -> `/Users/sk.../.zshrc` <-> `/Users/sky0/.zshrc`).
- Files stay **in place** (no symlinks). **Secrets excluded by default.**
- Transport is `ssh` over Tailscale SSH (already enabled on the hub).

## Install

```sh
# GNU rsync is required (already installed via: brew install rsync)
ln -sf "$PWD/bin/ymirr" /opt/homebrew/bin/ymirr   # put it on PATH
ymirr init                                          # writes ~/.config/ymirr/config
```

Then set the hub username in `~/.config/ymirr/config`:

```sh
# on the hub (macminim4), find the local account name:
id -un
# put that value in HUB_USER=""
```

Verify:

```sh
ymirr status      # should show reachable: yes
```

## Use

```sh
ymirr add ~/.zshrc ~/.config/nvim   # register (seeds up to hub if new)
ymirr add --force ~/.somesecret     # override the secret guard (rare)
ymirr rm  ~/.zshrc                  # unregister (local copy kept)
ymirr list                         # show managed paths
ymirr sync                         # pull hub -> this machine now
ymirr install-agent                # launchd: auto-sync every INTERVAL seconds
ymirr uninstall-agent
```

Run `ymirr add/rm` on any Mac; because the manifest lives on the hub, the managed set is
shared. Other spokes pick up the change on their next `sync`.

## Config (`~/.config/ymirr/config`)

| Key | Meaning |
|-----|---------|
| `HUB_HOST` | hub MagicDNS name (default `macminim4`) |
| `HUB_USER` | **required** local macOS username on the hub |
| `TRANSPORT` | `ssh` (real) or `local` (testing) |
| `MIRROR` | `1` => `rsync --delete` (removes local files gone on hub); default `0` |
| `INTERVAL` | launchd sync interval in seconds |
| `HUB_RSYNC_PATH` | set to `/opt/homebrew/bin/rsync` if the hub has GNU rsync |

## Safety

- One-way pull: **edits on a spoke are overwritten** by the hub on the next sync. Curate
  config on the hub (`macminim4`).
- `MIRROR=1` is destructive on the receiver. Leave it `0` unless you want exact mirroring.
- Secret patterns (`.ssh/*`, `id_rsa`, `*.pem`, `*.key`, `.aws/credentials`, `.env`, ...)
  are excluded from every transfer and blocked by `add` without `--force`.

## Scope

Macs only. iOS nodes (iPad/iPhone) cannot run the sync agent; use them read-only via a
Tailscale file client if needed.
