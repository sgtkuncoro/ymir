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

### On the hub (publish what you offer)
```sh
ymir pub ~/.zshrc ~/.config/nvim ~/work.gitconfig
ymir pubs
ymir unpub ~/.zshrc
```

### On each spoke (subscribe; decide what you pull and where)
```sh
ymir pubs                                              # see what the hub publishes
ymir sub ~/.config/nvim                                # subscribe, same path
ymir sub --from work.gitconfig --to ~/.gitconfig       # explicit: hub source -> local dest
ymir sub --to ~/.gitconfig work.gitconfig              # same thing, positional shorthand
ymir sub --all                                         # subscribe to everything published
ymir subs                                              # your subscriptions (SHARE -> DEST)
ymir sync                                              # pull them down
ymir install-agent                                     # auto-sync on an interval
```

Aliases: `add`/`rm`/`list` are role-aware shorthands (hub: `pub`/`unpub`/`pubs`; spoke:
`sub`/`unsub`/`subs`). Optional: `ymir push ~/file` pushes a local file up to the hub and
publishes it in one step.

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
  are excluded from every transfer and blocked by `pub`/`push` without `--force`.

## Tests

```sh
bash tests/parse.sh    # unit tests: parse_entry / dest_ok
bash tests/run.sh      # behavior tests: full hub/spoke flows over the local transport
```

Both run in CI (GitHub Actions, `.github/workflows/ci.yml`) on Linux and macOS, along
with `shellcheck -S warning`, on every push and pull request.

## Scope

Macs only. iOS nodes (iPad/iPhone) cannot run the agent; use them read-only via a
Tailscale file client if needed.
