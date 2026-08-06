<p align="center">
  <img src="./assets/duckterm-mark.svg" width="72" height="72" alt="DuckTerm">
</p>

<h1 align="center">DuckTerm Web</h1>

<p align="center">
  <strong>Your local shells, remote hosts, persistent sessions, and coding agents — in one browser.</strong>
</p>

<p align="center">
  English · <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/ducksee/duckterm-web-releases/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/ducksee/duckterm-web-releases?display_name=tag&style=flat-square"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-Apple%20silicon%20%7C%20Intel-111827?style=flat-square&logo=apple">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-x64%20%7C%20arm64-0078D4?style=flat-square&logo=windows11&logoColor=white">
  <img alt="Linux and WSL" src="https://img.shields.io/badge/Linux%20%7C%20WSL-x64%20%7C%20arm64-FCC624?style=flat-square&logo=linux&logoColor=111827">
</p>

DuckTerm Web turns the machine that already owns your terminal sessions into a
self-hosted browser terminal. It brings local shells, SSH and Mosh hosts,
tmux/psmux/Herdr workspaces, files, Git, and coding-agent terminals into the
same DuckTerm interface — without moving those sessions to a hosted service.

It is designed for developers who work across several machines or leave
long-running terminal agents behind. It is **not** a public terminal gateway:
the default installation listens only on localhost, and LAN access is an
explicit opt-in.

## What you get

- **One browser workspace** for macOS, Windows, Linux, and WSL terminals.
- **Persistent sessions** through tmux, psmux, and Herdr, including supported
  coding-agent TUI workflows.
- **Local and remote access** through local shell, SSH, and Mosh.
- **Files, Git, previews, and terminal tools** beside the active session.
- **One managed process and one port** with launchd, systemd, WSL1 SysV, or
  Windows Task Scheduler ownership.
- **Transactional installs and updates** with SHA-256 verification, health
  checks, and rollback to the previous working installation.

## Install

### macOS — Homebrew (recommended)

```sh
brew install ducksee/tap/duckterm-web
duckterm-web start
```

Supports Apple silicon and Intel. Homebrew owns both the package and its
background service; `duckterm-web start` starts it and opens the first-login
URL.

For an app-owned service without Homebrew, use the same direct installer as
Linux. It refuses to create a second service beside an existing Homebrew-owned
installation.

### Windows 10 / 11 — native PowerShell

Run in PowerShell 5.1 or newer:

```powershell
irm https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.ps1 | iex
```

The installer selects x64 or arm64, verifies the release SHA-256, installs a
self-contained runtime when needed, and registers a hidden logon task. Native
Windows and WSL are separate hosts; use this installer for PowerShell, psmux,
and Windows Herdr sessions.

### Linux

```sh
curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh | sh
```

The installer selects x86_64 or arm64, verifies the release, and registers a
systemd service for the current user (or the system when run as root).

### Windows Subsystem for Linux

Run this **inside the WSL distribution**, not in PowerShell:

```sh
curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh | sh
```

WSL is treated as its own Linux host. systemd is used when available; WSL1
falls back to a managed SysV service plus a Windows logon launcher.

### Package selection

The direct installers automatically choose the smallest verified package that
works on the machine:

| flavor | when it is selected | runtime |
|---|---|---|
| `tiny` | Node.js 22.5 or newer is already available | uses the system Node.js |
| `full` | no compatible Node.js is found | bundles Node.js 24 |

No npm install runs on the target machine. Both flavors contain the same Web UI
and native PTY support.

## First login and network mode

The installer starts DuckTerm Web and prints its URL. The first visit uses a
one-time bootstrap token to create the local admin account; later visits use
the password you set.

The secure default is local-only:

```text
http://127.0.0.1:1420
```

To make an installed service available on the LAN, use **Settings → Resident
service (驻留服务)**. Homebrew users can make the same change from the CLI:

```sh
duckterm-web config --lan --reload       # 0.0.0.0 + HTTPS
duckterm-web config --local --reload     # back to localhost + HTTP
duckterm-web config --port 1443 --reload
```

LAN mode generates a per-host self-signed HTTPS certificate. Your browser may
ask you to trust it once. Do not expose port 1420 through public router port
forwarding; use a trusted LAN or VPN.

Install directly into LAN mode instead:

```sh
curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh \
  | DUCKTERM_EXPOSE=1 DUCKTERM_PORT=1420 sh
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.ps1))) -Expose -Port 1420
```

## Everyday commands

Homebrew exposes `duckterm-web` on `PATH`. Direct installs expose service
configuration and install/uninstall in **Settings → Resident service
(驻留服务)**; re-running their installer is the supported update/recovery path.

| command | purpose |
|---|---|
| `duckterm-web start [--no-open]` | start the managed service and open, or only print, the login URL |
| `duckterm-web url` | print the current login URL and bootstrap token when available |
| `duckterm-web status [--json]` | show service owner, state, version, endpoint, and update availability |
| `duckterm-web version` | print the installed version |
| `duckterm-web restart` | restart the managed service |
| `duckterm-web reload` | reload configuration without disabling auto-start |
| `duckterm-web stop` | stop now while keeping auto-start registered |
| `duckterm-web config --lan\|--local --reload` | persist the bind mode and apply it |
| `duckterm-web config --port <n> --reload` | persist a port and apply it |
| `duckterm-web update` | update the current managed install and restart it |
| `duckterm-web upgrade` | exact alias of `update` |
| `duckterm-web service install\|uninstall` | add or remove persistent service ownership |
| `duckterm-web foreground [--lan]` | run one foreground process without a supervisor |

## Upgrade

For a Homebrew installation:

```sh
duckterm-web update
```

This performs a targeted tap refresh, upgrades the formula, and restarts the
same Homebrew-owned service. `upgrade` is an exact alias.

For Windows, Linux, WSL, or a direct macOS install, re-run the same one-line
installer. It preserves the existing host/port configuration, verifies the new
package, stops only the exact DuckTerm Web owner, and restores the previous
application and service if the new version does not become healthy.

## Remove

### Homebrew

```sh
brew services stop duckterm-web
brew uninstall duckterm-web
```

### Direct macOS / Linux / WSL install

First choose **Settings → Resident service (驻留服务) → Uninstall service**. To
remove the package files from their default location afterward:

```sh
rm -rf "$HOME/.duckterm/app"
```

### Native Windows install

First choose **Settings → Resident service (驻留服务) → Uninstall service**.
Then remove the default package directory from PowerShell:

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\Programs\DuckTerm Web" -Recurse -Force
```

These package-removal steps preserve DuckTerm settings and session metadata.
Back up and remove the separate DuckTerm data directory only when you
deliberately want to erase local data as well.

## Direct-installer options

<details>
<summary>macOS, Linux, and WSL environment variables</summary>

| variable | meaning |
|---|---|
| `DUCKTERM_VERSION=0.2.9` | install an exact version |
| `DUCKTERM_FLAVOR=tiny\|full` | override automatic package selection |
| `DUCKTERM_APP_DIR=/path` | override the application directory |
| `DUCKTERM_PORT=1443` | persist a non-default port |
| `DUCKTERM_EXPOSE=1` | bind to the LAN with HTTPS |
| `DUCKTERM_NO_SERVICE=1` | install package files without registering a service |
| `DUCKTERM_TARBALL=/path` | install a local/offline archive |
| `DUCKTERM_SHA256=<hex>` | verify a local/offline archive |

</details>

<details>
<summary>Windows PowerShell parameters</summary>

| parameter | meaning |
|---|---|
| `-Version 0.2.9` | install an exact version |
| `-Flavor tiny\|full` | override automatic package selection |
| `-AppDirectory <path>` | override the application directory |
| `-Port 1443` | persist a non-default port |
| `-Expose` | bind to the LAN with HTTPS and add a LocalSubnet firewall rule |
| `-NoService` | install package files without registering the logon task |
| `-Tarball <path>` | install a local/offline archive |
| `-Sha256 <hex>` | verify a local/offline archive |

</details>

## Release packages

| asset | platform |
|---|---|
| `duckterm-web-vX.Y.Z-tiny.tar.gz` | universal; requires Node.js 22.5+ |
| `duckterm-web-vX.Y.Z-full-darwin-arm64.tar.gz` | macOS Apple silicon |
| `duckterm-web-vX.Y.Z-full-darwin-x64.tar.gz` | macOS Intel |
| `duckterm-web-vX.Y.Z-full-linux-arm64.tar.gz` | Linux / WSL arm64 |
| `duckterm-web-vX.Y.Z-full-linux-x64.tar.gz` | Linux / WSL x86_64 |
| `duckterm-web-vX.Y.Z-full-win32-arm64.tar.gz` | Windows arm64 |
| `duckterm-web-vX.Y.Z-full-win32-x64.tar.gz` | Windows x64 |

Verify manual downloads against the `SHA256SUMS` file attached to every
release.

## How it is packaged

DuckTerm Web is the browser distribution of DuckTerm's shared TypeScript UI.
The release combines the built SPA with a Node bridge for PTY, SSH/Mosh, files,
Git, SQLite, credentials, and service management. It is one process, one port,
and does not require the Tauri desktop runtime.

Official release packages are proprietary software; see the `LICENSE` inside
each package.
