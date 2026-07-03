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

## Homebrew (macOS / Linux)
```sh
brew install ducksee/tap/duckterm-web
brew services start duckterm-web
```
