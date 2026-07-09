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
prints the URL + one-time token.

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
```sh
brew install ducksee/tap/duckterm-web
brew services start duckterm-web
```

Homebrew prints the first-login URL to `$(brew --prefix)/var/log/duckterm-web.log`.

Homebrew service management:
```sh
duckterm-web status
duckterm-web config --lan --reload
duckterm-web config --local --reload
duckterm-web config --port 1443 --reload
duckterm-web reload
```
