# DuckTerm Web — releases

Standalone browser terminal (SolidJS SPA + Node bridge). One process, one
port, HTTPS-by-exposure, first-login password setup. Pure Node.js — zero
Rust/Tauri.

## Install (one line)

```sh
curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh | sh
```

Picks the smallest package that runs on your machine:
- **tiny** (~10MB) if you already have Node ≥ 22.5
- **full-<os>-<arch>** (~50MB, bundles Node) otherwise

Then installs a persistent service (systemd / launchd), starts it, and
prints the URL + bootstrap token.

### Options
```sh
DUCKTERM_EXPOSE=1 sh install.sh   # bind 0.0.0.0 + HTTPS (LAN/remote)
DUCKTERM_PORT=1420
DUCKTERM_FLAVOR=full              # force bundled-node package
DUCKTERM_NO_SERVICE=1             # install only, don't register a service
```

After install, `~/.duckterm/config.json` holds runtime settings while the
launchd/systemd unit stays stable.

Persistent LAN/HTTPS:
```sh
~/.duckterm/app/duckterm.mjs config --lan --reload
~/.duckterm/app/duckterm.mjs status
```

## Homebrew (macOS / Linux)

`ducksee/tap` is a third-party tap maintained by the DuckTerm authors, not
Homebrew. Install the fully-qualified formula — Homebrew adds the tap
automatically and trusts only this formula:

```sh
brew install ducksee/tap/duckterm-web
brew services start duckterm-web
```

Get the login URL (with the first-login bootstrap token):
```sh
duckterm-web url
```

Everyday commands:
```sh
duckterm-web url                        # login URL + bootstrap token
duckterm-web status                     # service state, version, update check
duckterm-web version                    # installed version
duckterm-web upgrade                    # update to the latest release
duckterm-web config --lan --reload      # persistent LAN + HTTPS
duckterm-web config --local --reload    # back to localhost + HTTP
duckterm-web config --port 1443 --reload
duckterm-web reload
```

Upgrade — one command (Homebrew doesn't reliably auto-pull third-party taps, so
plain `brew upgrade` can miss updates; this does a targeted tap refresh, then
upgrades and restarts the service):
```sh
duckterm-web upgrade
```

Prefer the manual steps? Targeted refresh (not a full `brew update`):
```sh
git -C "$(brew --repo ducksee/tap)" pull --ff-only && brew upgrade duckterm-web && brew services restart duckterm-web
```

Uninstall:
```sh
brew services stop duckterm-web && brew uninstall duckterm-web
```
