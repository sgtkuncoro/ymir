# ymir

Publish/subscribe config sync across your Macs, entirely over your Tailscale tailnet.
No cloud, no public exposure.

> Full documentation: [docs/GUIDE.md](docs/GUIDE.md) - model, internals, every command, automation, security, troubleshooting, FAQ.

- **Hub** = source of truth. It publishes a **share catalog**: the paths it offers.
- **Spoke** = each other Mac. It **subscribes** to shared items and decides **where**
  each one lands locally (`--to`). The hub needs no knowledge of the spokes.
- A spoke can only pull what the hub currently shares (the hub is the gatekeeper).
- Paths are stored **HOME-relative**, so different local usernames map correctly.
- Files stay **in place** (no symlinks). **Secrets excluded by default.**
- Transport is `ssh` over Tailscale SSH (enable on the hub with `sudo tailscale set --ssh`).

## Install

Guided wizard (recommended):

```sh
brew install rsync                 # GNU rsync (once)
./bin/ymir setup                   # asks hub/spoke, writes config, links PATH, agent
```

Manual:

```sh
ln -sf "$PWD/bin/ymir" /opt/homebrew/bin/ymir
ymir init
$EDITOR ~/.config/ymir/config      # hub: IS_HUB=1   |   spoke: HUB_USER=<id -un on hub>
ymir status
```

## Use

### On the hub (decide what to share)
```sh
ymir share ~/.zshrc ~/.config/nvim ~/work.gitconfig
ymir shares
ymir unshare ~/.zshrc
```

### On each spoke (decide what you pull and where)
```sh
ymir catalog                                  # see what the hub offers
ymir add ~/.config/nvim                                # subscribe, same path
ymir add --from work.gitconfig --to ~/.gitconfig       # explicit: hub source -> local dest
ymir add --to ~/.gitconfig work.gitconfig              # same thing, positional shorthand
ymir add --all                                # subscribe to everything shared
ymir list                                     # your subscriptions (SHARE -> DEST)
ymir sync                                      # pull them down
ymir install-agent                            # auto-sync on an interval
```

`add`/`rm`/`list` are role-aware: on the hub they act on the **share catalog**; on a
spoke they act on that spoke's **subscriptions**. Optional: `ymir publish ~/file` pushes
a local file up to the hub and shares it in one step.

## Config (`~/.config/ymir/config`)

| Key | Meaning |
|-----|---------|
| `HUB_HOST` | hub Tailscale MagicDNS name |
| `HUB_USER` | spoke only: local macOS username on the hub |
| `IS_HUB` | set `1` on the hub (publish/share here; `sync` is a no-op) |
| `TRANSPORT` | `ssh` (real) or `local` (testing) |
| `MIRROR` | `1` => `rsync --delete`, applied only to same-path subscriptions |
| `INTERVAL` | launchd auto-sync interval (seconds) |
| `HUB_RSYNC_PATH` | set to `/opt/homebrew/bin/rsync` if the hub has GNU rsync |

## Safety

- One-way pull: the hub is authoritative. A spoke cannot pull a path the hub does not share.
- A subscription destination cannot escape your home (`..` / absolute are rejected).
- `MIRROR=1` never deletes for a remapped destination, so it cannot wipe a shared parent
  like `~/.config`.
- Secret patterns (`.ssh/*`, `id_rsa`, `*.pem`, `*.key`, `.aws/credentials`, `.env`, ...)
  are excluded from every transfer and blocked by `share`/`publish` without `--force`.

## Tests

```sh
bash tests/parse.sh      # parser + destination-safety unit tests
```

## Scope

Macs only. iOS nodes (iPad/iPhone) cannot run the agent; use them read-only via a
Tailscale file client if needed.
