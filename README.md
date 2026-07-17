# ymir

Pull-sync a **managed, add/removable list** of config paths from one hub to your other
Macs, entirely over your Tailscale tailnet. No cloud, no public exposure.

> Full documentation: [docs/GUIDE.md](docs/GUIDE.md) - concepts, internals, every command, automation, security, troubleshooting, FAQ.

- **Hub** (`macminim4`) is the source of truth: it owns the manifest and canonical files.
- **Spokes** pull the manifest and every listed path from the hub.
- Paths are stored **HOME-relative**, so different local usernames map correctly
  (hub `sk...` vs laptop `sky0` -> `/Users/sk.../.zshrc` <-> `/Users/sky0/.zshrc`).
- Files stay **in place** (no symlinks). **Secrets excluded by default.**
- Transport is `ssh` over Tailscale SSH (already enabled on the hub).

## Install

Fastest path is the guided wizard:

```sh
brew install rsync                 # GNU rsync (once)
./bin/ymir setup                   # asks hub/spoke, writes config, links PATH, agent
```

`ymir setup` checks prerequisites, asks whether this machine is the HUB or a SPOKE,
collects `HUB_HOST`/`HUB_USER`, writes `~/.config/ymir/config`, offers to symlink
`ymir` onto your PATH, tests hub reachability, and can install the launchd agent.

Manual equivalent, if you prefer:

```sh
ln -sf "$PWD/bin/ymir" /opt/homebrew/bin/ymir   # PATH
ymir init                                          # writes ~/.config/ymir/config
$EDITOR ~/.config/ymir/config                      # set HUB_USER (run `id -un` on hub)
ymir status                                         # expect: reachable: yes
```

## Use

```sh
ymir add ~/.zshrc ~/.config/nvim   # register (seeds up to hub if new)
ymir add --force ~/.somesecret     # override the secret guard (rare)
ymir rm  ~/.zshrc                  # unregister (local copy kept)
ymir list                         # show managed paths
ymir sync                         # pull hub -> this machine now
ymir install-agent                # launchd: auto-sync every INTERVAL seconds
ymir uninstall-agent
```

Run `ymir add/rm` on any Mac; because the manifest lives on the hub, the managed set is
shared. Other spokes pick up the change on their next `sync`.

## Config (`~/.config/ymir/config`)

| Key | Meaning |
|-----|---------|
| `HUB_HOST` | hub MagicDNS name (default `macminim4`) |
| `HUB_USER` | **required** local macOS username on the hub |
| `IS_HUB` | set `1` on the hub to curate paths there (`sync` becomes a no-op) |
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
