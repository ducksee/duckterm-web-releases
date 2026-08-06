<p align="center">
  <img src="./assets/duckterm-mark.svg" width="72" height="72" alt="DuckTerm">
</p>

<h1 align="center">DuckTerm Web</h1>

<p align="center">
  <strong>把本地 Shell、远程主机、长驻会话与编程 Agent，放进同一个浏览器。</strong>
</p>

<p align="center">
  <a href="./README.md">English</a> · 简体中文
</p>

<p align="center">
  <a href="https://github.com/ducksee/duckterm-web-releases/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/ducksee/duckterm-web-releases?display_name=tag&style=flat-square"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-Apple%20silicon%20%7C%20Intel-111827?style=flat-square&logo=apple">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-x64%20%7C%20arm64-0078D4?style=flat-square&logo=windows11&logoColor=white">
  <img alt="Linux 和 WSL" src="https://img.shields.io/badge/Linux%20%7C%20WSL-x64%20%7C%20arm64-FCC624?style=flat-square&logo=linux&logoColor=111827">
</p>

DuckTerm Web 把已经拥有终端会话的机器，变成一台自托管的浏览器终端。
本地 Shell、SSH 与 Mosh 主机、tmux/psmux/Herdr 工作区、文件、Git 和
编程 Agent 终端，都可以在同一个 DuckTerm 界面中使用，而不需要把会话
迁移到托管服务。

它面向需要跨多台机器工作，或者需要保留长时间运行的终端 Agent 的开发者。
它**不是**公网终端网关：默认安装只监听本机地址，局域网访问需要显式开启。

## 你会得到什么

- **一个浏览器工作区**：统一访问 macOS、Windows、Linux 与 WSL 终端。
- **长驻会话**：支持 tmux、psmux 与 Herdr，以及已适配的编程 Agent TUI 工作流。
- **本地与远程连接**：支持本地 Shell、SSH 与 Mosh。
- **终端旁边的生产力工具**：文件、Git、预览与终端工具集中在同一界面。
- **一个托管进程、一个端口**：由 launchd、systemd、WSL1 SysV 或 Windows
  任务计划程序持有。
- **事务式安装和升级**：校验 SHA-256、执行健康检查，并在失败时回滚到
  上一个可用版本。

## 安装

### macOS — Homebrew（推荐）

```sh
brew install ducksee/tap/duckterm-web
duckterm-web start
```

支持 Apple silicon 与 Intel。Homebrew 同时管理软件包与后台服务；
`duckterm-web start` 会启动服务并打开首次登录地址。

如果希望在 macOS 上使用不受 Homebrew 管理的独立服务，可以使用与 Linux
相同的直接安装脚本。检测到 Homebrew 已安装时，脚本会拒绝再创建第二个服务。

### Windows 10 / 11 — 原生 PowerShell

在 PowerShell 5.1 或更新版本中运行：

```powershell
irm https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.ps1 | iex
```

安装器会自动选择 x64 或 arm64、校验发布包 SHA-256、在需要时安装自带运行时，
并注册隐藏运行的登录任务。原生 Windows 与 WSL 是两台独立主机；PowerShell、
psmux 与 Windows Herdr 会话请使用这个安装器。

### Linux

```sh
curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh | sh
```

安装器会自动选择 x86_64 或 arm64、校验发布包，并为当前用户注册 systemd
服务；以 root 运行时则注册系统服务。

### Windows Subsystem for Linux

请在 **WSL 发行版内部**运行，而不是在 PowerShell 中运行：

```sh
curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh | sh
```

WSL 会被视为独立的 Linux 主机。有 systemd 时优先使用 systemd；WSL1
会回退到受管理的 SysV 服务与 Windows 登录启动器。

### 安装包选择

直接安装器会自动选择当前机器可用的最小已验证安装包：

| 类型 | 选择条件 | 运行时 |
|---|---|---|
| `tiny` | 已安装 Node.js 22.5 或更新版本 | 使用系统 Node.js |
| `full` | 未找到兼容的 Node.js | 自带 Node.js 24 |

目标机器上不会执行 npm install。两种安装包包含相同的 Web UI 与原生 PTY 支持。

## 首次登录与网络模式

安装器会启动 DuckTerm Web 并打印访问地址。首次访问使用一次性引导令牌创建
本地管理员账号；之后使用你设置的密码登录。

安全默认值是仅本机访问：

```text
http://127.0.0.1:1420
```

如需允许局域网访问，请打开 **设置 → 驻留服务**。Homebrew 用户也可以使用 CLI：

```sh
duckterm-web config --lan --reload       # 0.0.0.0 + HTTPS
duckterm-web config --local --reload     # 恢复为本机地址 + HTTP
duckterm-web config --port 1443 --reload
```

局域网模式会为每台主机生成自签名 HTTPS 证书，浏览器可能会要求信任一次。
不要通过公网路由器转发 1420 端口；请只在可信局域网或 VPN 中使用。

也可以安装时直接开启局域网模式：

```sh
curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh \
  | DUCKTERM_EXPOSE=1 DUCKTERM_PORT=1420 sh
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.ps1))) -Expose -Port 1420
```

## 高频命令

Homebrew 会把 `duckterm-web` 放到 `PATH`。直接安装版本通过
**设置 → 驻留服务**管理服务配置、安装与卸载；重新运行安装器是其受支持的
升级与修复方式。

| 命令 | 作用 |
|---|---|
| `duckterm-web start [--no-open]` | 启动托管服务并打开登录地址，或只打印地址 |
| `duckterm-web url` | 打印当前登录地址，以及可用时的引导令牌 |
| `duckterm-web status [--json]` | 显示服务归属、状态、版本、访问地址与更新状态 |
| `duckterm-web version` | 打印已安装版本 |
| `duckterm-web restart` | 重启托管服务 |
| `duckterm-web reload` | 重新加载配置，同时保留自动启动 |
| `duckterm-web stop` | 立即停止，但保留自动启动注册 |
| `duckterm-web config --lan\|--local --reload` | 保存网络模式并立即应用 |
| `duckterm-web config --port <n> --reload` | 保存端口并立即应用 |
| `duckterm-web update` | 更新当前托管安装并重启服务 |
| `duckterm-web upgrade` | `update` 的完全等价别名 |
| `duckterm-web service install\|uninstall` | 添加或移除驻留服务 |
| `duckterm-web foreground [--lan]` | 不使用服务管理器，运行一个前台进程 |

## 升级

Homebrew 安装：

```sh
duckterm-web update
```

它会定向刷新 tap、升级 Formula，并重启同一个 Homebrew 服务。`upgrade`
是完全等价的别名。

Windows、Linux、WSL 或直接安装的 macOS 版本，请重新运行原来的一行安装命令。
安装器会保留现有主机与端口配置、校验新包，只停止 DuckTerm Web 的精确服务
归属者；如果新版本未能通过健康检查，则恢复之前的应用和服务。

## 卸载

### Homebrew

```sh
brew services stop duckterm-web
brew uninstall duckterm-web
```

### 直接安装的 macOS / Linux / WSL

先选择 **设置 → 驻留服务 → 卸载服务**。然后如需移除默认位置的软件包文件：

```sh
rm -rf "$HOME/.duckterm/app"
```

### 原生 Windows

先选择 **设置 → 驻留服务 → 卸载服务**，再在 PowerShell 中移除默认软件包目录：

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\Programs\DuckTerm Web" -Recurse -Force
```

以上步骤会保留 DuckTerm 设置与会话元数据。只有在确实需要清除本地数据时，
才应单独备份并移除 DuckTerm 数据目录。

## 直接安装器选项

<details>
<summary>macOS、Linux 与 WSL 环境变量</summary>

| 变量 | 含义 |
|---|---|
| `DUCKTERM_VERSION=0.2.9` | 安装指定版本 |
| `DUCKTERM_FLAVOR=tiny\|full` | 覆盖自动安装包选择 |
| `DUCKTERM_APP_DIR=/path` | 覆盖应用目录 |
| `DUCKTERM_PORT=1443` | 保存非默认端口 |
| `DUCKTERM_EXPOSE=1` | 通过 HTTPS 绑定局域网地址 |
| `DUCKTERM_NO_SERVICE=1` | 只安装软件包，不注册服务 |
| `DUCKTERM_TARBALL=/path` | 安装本地或离线归档 |
| `DUCKTERM_SHA256=<hex>` | 校验本地或离线归档 |

</details>

<details>
<summary>Windows PowerShell 参数</summary>

| 参数 | 含义 |
|---|---|
| `-Version 0.2.9` | 安装指定版本 |
| `-Flavor tiny\|full` | 覆盖自动安装包选择 |
| `-AppDirectory <path>` | 覆盖应用目录 |
| `-Port 1443` | 保存非默认端口 |
| `-Expose` | 通过 HTTPS 绑定局域网地址，并添加 LocalSubnet 防火墙规则 |
| `-NoService` | 只安装软件包，不注册登录任务 |
| `-Tarball <path>` | 安装本地或离线归档 |
| `-Sha256 <hex>` | 校验本地或离线归档 |

</details>

## 发布包

| 文件 | 平台 |
|---|---|
| `duckterm-web-vX.Y.Z-tiny.tar.gz` | 通用；需要 Node.js 22.5+ |
| `duckterm-web-vX.Y.Z-full-darwin-arm64.tar.gz` | macOS Apple silicon |
| `duckterm-web-vX.Y.Z-full-darwin-x64.tar.gz` | macOS Intel |
| `duckterm-web-vX.Y.Z-full-linux-arm64.tar.gz` | Linux / WSL arm64 |
| `duckterm-web-vX.Y.Z-full-linux-x64.tar.gz` | Linux / WSL x86_64 |
| `duckterm-web-vX.Y.Z-full-win32-arm64.tar.gz` | Windows arm64 |
| `duckterm-web-vX.Y.Z-full-win32-x64.tar.gz` | Windows x64 |

手动下载时，请使用每个 Release 附带的 `SHA256SUMS` 校验文件。

## 打包方式

DuckTerm Web 是 DuckTerm 共享 TypeScript UI 的浏览器发行版。发布包由构建后的
SPA 与 Node bridge 组成，提供 PTY、SSH/Mosh、文件、Git、SQLite、凭据与
服务管理能力。它只需要一个进程、一个端口，不依赖 Tauri 桌面运行时。

官方发布包是专有软件；许可证见每个安装包内的 `LICENSE`。
