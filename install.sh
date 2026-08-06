#!/usr/bin/env sh
# DuckTerm Web transactional installer for macOS, Linux, and WSL.
# Windows uses install-web.ps1. A network install requires the published
# SHA256SUMS entry; a local/offline install can pin DUCKTERM_SHA256.
set -eu

REPO="ducksee/duckterm-web-releases"
APP_DIR="${DUCKTERM_APP_DIR:-$HOME/.duckterm/app}"
MIN_NODE_MAJOR=22
MIN_NODE_MINOR=5

say()  { printf '\033[1;36m[duckterm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[duckterm]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[duckterm]\033[0m %s\n' "$*" >&2; exit 1; }

valid_version() { printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

case "$APP_DIR" in
  ""|/|"$HOME") die "refusing unsafe DUCKTERM_APP_DIR: ${APP_DIR:-<empty>}" ;;
esac

resolve_latest_version() {
  candidate=$(curl -fsSL --connect-timeout 10 --max-time 20 \
    "https://raw.githubusercontent.com/$REPO/main/LATEST" 2>/dev/null | tr -d '\r\n') \
    || candidate=""
  if [ -n "$candidate" ] && valid_version "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  effective=$(curl -fsSL --connect-timeout 10 --max-time 20 -o /dev/null \
    -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null) \
    || effective=""
  candidate=${effective##*/}; candidate=${candidate#v}
  if [ -n "$candidate" ] && valid_version "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  candidate=$(curl -fsSL --connect-timeout 10 --max-time 20 \
    "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/') \
    || candidate=""
  if [ -n "$candidate" ] && valid_version "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
  return 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

node_supported() {
  cand=$1
  [ -n "$cand" ] && [ -x "$cand" ] || return 1
  v=$("$cand" -p 'process.versions.node' 2>/dev/null) || return 1
  maj=$(printf '%s' "$v" | cut -d. -f1)
  min=$(printf '%s' "$v" | cut -d. -f2)
  [ "${maj:-0}" -gt "$MIN_NODE_MAJOR" ] 2>/dev/null || {
    [ "${maj:-0}" -eq "$MIN_NODE_MAJOR" ] 2>/dev/null &&
      [ "${min:-0}" -ge "$MIN_NODE_MINOR" ] 2>/dev/null
  }
}

find_node() {
  for cand in \
    "$(command -v node 2>/dev/null || true)" \
    /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node \
    "$HOME"/.nvm/versions/node/*/bin/node
  do
    if node_supported "$cand"; then
      printf '%s\n' "$cand"; return 0
    fi
  done
  return 0
}

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux) OS=linux ;;
  *) die "unsupported OS: $(uname -s); use install-web.ps1 on Windows" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64) ARCH=x64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

# A Homebrew formula is a package *and* a supervisor identity. Installing the
# generic app-owned LaunchAgent beside it would create two KeepAlive owners for
# the same port. Match Hookd's proven policy: fail before downloading or
# replacing any bytes, and direct authorized canaries to the dedicated
# Homebrew convergence script. A no-service extraction is harmless, while an
# explicit migration remains available for an operator who deliberately wants
# to leave Homebrew ownership.
homebrew_bin=""
homebrew_formula_installed=0
homebrew_was_running=0
if [ "$OS" = darwin ]; then
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$brew" ] || continue
    if "$brew" list --versions duckterm-web >/dev/null 2>&1; then
      homebrew_bin="$brew"
      homebrew_formula_installed=1
      break
    fi
  done
  if [ "$homebrew_formula_installed" -eq 1 ] &&
    [ "${DUCKTERM_NO_SERVICE:-}" != 1 ] &&
    [ "${DUCKTERM_MIGRATE_HOMEBREW:-}" != 1 ]; then
    die "Homebrew duckterm-web is installed; use converge-macos-homebrew-web-dev.sh for a private canary, or brew upgrade for a published build"
  fi
fi

SYS_NODE=$(find_node)
FLAVOR=${DUCKTERM_FLAVOR:-}
if [ -z "$FLAVOR" ]; then [ -n "$SYS_NODE" ] && FLAVOR=tiny || FLAVOR=full; fi
case "$FLAVOR" in tiny) ASSET_SUFFIX=tiny ;; full) ASSET_SUFFIX="full-$OS-$ARCH" ;; *) die "DUCKTERM_FLAVOR must be tiny or full" ;; esac
say "platform: $OS-$ARCH | node: ${SYS_NODE:-bundled} | flavor: $FLAVOR"

download_tmp=$(mktemp -d)
app_parent=$(dirname "$APP_DIR")
mkdir -p "$app_parent"
stage=$(mktemp -d "${APP_DIR}.stage.XXXXXX")
backup="${APP_DIR}.rollback"
activated=0
service_stopped=0
cleanup() {
  rm -rf "$download_tmp" "$stage"
  if [ "$activated" -eq 0 ]; then
    if [ -d "$backup" ] && [ ! -e "$APP_DIR" ]; then mv "$backup" "$APP_DIR"; fi
    if [ "$service_stopped" -eq 1 ]; then restart_previous_service || warn "ROLLBACK INCOMPLETE: previous service did not restart"; fi
  fi
}
trap cleanup EXIT HUP INT TERM

VER=${DUCKTERM_VERSION:-}
if [ -n "${DUCKTERM_TARBALL:-}" ]; then
  [ -f "$DUCKTERM_TARBALL" ] || die "local tarball not found: $DUCKTERM_TARBALL"
  say "using local tarball $DUCKTERM_TARBALL"
  cp "$DUCKTERM_TARBALL" "$download_tmp/pkg.tar.gz"
  if [ -n "${DUCKTERM_SHA256:-}" ]; then
    got=$(sha256_file "$download_tmp/pkg.tar.gz")
    [ "$got" = "$DUCKTERM_SHA256" ] || die "sha256 mismatch (want $DUCKTERM_SHA256 got $got)"
    say "sha256 verified"
  fi
else
  [ -n "$VER" ] || VER=$(resolve_latest_version) \
    || die "could not resolve latest version (set DUCKTERM_VERSION or check network/proxy)"
  valid_version "$VER" || die "DUCKTERM_VERSION must be X.Y.Z (got '$VER')"
  ASSET="duckterm-web-v${VER}-${ASSET_SUFFIX}.tar.gz"
  release="https://github.com/$REPO/releases/download/v${VER}"
  say "downloading $ASSET"
  curl -fsSL -o "$download_tmp/SHA256SUMS" "$release/SHA256SUMS" \
    || die "release checksum manifest unavailable"
  want=$(grep " $ASSET\$" "$download_tmp/SHA256SUMS" | awk '{print $1}')
  [ -n "$want" ] || die "release checksum missing for $ASSET"
  curl -fsSL -o "$download_tmp/pkg.tar.gz" "$release/$ASSET" || die "download failed: $ASSET"
  got=$(sha256_file "$download_tmp/pkg.tar.gz")
  [ "$want" = "$got" ] || die "sha256 mismatch (want $want got $got)"
  say "sha256 verified"
fi

tar -xzf "$download_tmp/pkg.tar.gz" -C "$stage"
[ -f "$stage/package.json" ] || die "package is missing package.json"
[ -f "$stage/duckterm.mjs" ] || die "package is missing duckterm.mjs"
[ -f "$stage/service-manager.mjs" ] || die "package is missing service-manager.mjs"
if node_supported "$stage/node/node"; then STAGE_NODE="$stage/node/node"; else STAGE_NODE="$SYS_NODE"; fi
node_supported "$STAGE_NODE" || die "no compatible Node >=22.5 and package has no compatible bundled runtime"
package_version=$("$STAGE_NODE" -p "require(process.argv[1]).version" "$stage/package.json")
valid_version "$package_version" || die "package version is invalid: $package_version"
if [ -n "$VER" ] && [ "$package_version" != "$VER" ]; then die "package version $package_version does not match requested $VER"; fi
"$STAGE_NODE" "$stage/duckterm.mjs" version | grep -F "duckterm-web $package_version" >/dev/null \
  || die "staged launcher failed its version check"

# Service registration and runtime config are part of the same transaction as
# the application directory. A previous installer restored only APP_DIR; if a
# new systemd unit was invalid, rollback left the old bytes behind an unusable
# new unit. Snapshot the exact platform owner before activation and restore it
# without invoking the previous launcher (old launchers may not implement the
# modern `service` command at all).
service_state="$download_tmp/service-state"
mkdir -p "$service_state"
service_kind=none
service_path=""
service_scope=gui
service_was_present=0
service_was_running=0
service_was_enabled=0
wsl_launcher=""
wsl_launcher_was_present=0
config_path="$HOME/.duckterm/config.json"
config_was_present=0

if [ -f "$config_path" ]; then
  cp -p "$config_path" "$service_state/config.json"
  config_was_present=1
fi

systemctl_web() {
  if [ "$(id -u)" -eq 0 ]; then systemctl "$@"; else systemctl --user "$@"; fi
}

if [ "$OS" = darwin ]; then
  service_kind=launchd
  service_path="$HOME/Library/LaunchAgents/com.duckterm.web.plist"
  if [ -f "$service_path" ]; then
    cp -p "$service_path" "$service_state/com.duckterm.web.plist"
    service_was_present=1
  fi
  if /bin/launchctl print "gui/$(id -u)/com.duckterm.web" >/dev/null 2>&1; then
    service_was_running=1
    service_scope=gui
  elif /bin/launchctl print "user/$(id -u)/com.duckterm.web" >/dev/null 2>&1; then
    service_was_running=1
    service_scope=user
  fi
elif grep -Eqi 'microsoft|wsl' /proc/sys/kernel/osrelease /proc/version 2>/dev/null &&
  [ "$(cat /proc/1/comm 2>/dev/null || true)" != systemd ]; then
  service_kind=sysv
  service_path=/etc/init.d/duckterm-web
  if [ -f "$service_path" ]; then
    cp -p "$service_path" "$service_state/duckterm-web.init"
    service_was_present=1
    "$service_path" status >/dev/null 2>&1 && service_was_running=1 || true
    service_was_enabled=1
  fi
  appdata=$(cmd.exe /d /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r' | tail -n 1 || true)
  if [ -n "$appdata" ]; then
    wsl_appdata=$(wslpath -u "$appdata" 2>/dev/null || true)
    if [ -n "$wsl_appdata" ]; then
      wsl_launcher="$wsl_appdata/Microsoft/Windows/Start Menu/Programs/Startup/DuckTerm-Web.cmd"
      if [ -f "$wsl_launcher" ]; then
        cp -p "$wsl_launcher" "$service_state/DuckTerm-Web.cmd"
        wsl_launcher_was_present=1
      fi
    fi
  fi
else
  service_kind=systemd
  if [ "$(id -u)" -eq 0 ]; then
    service_path=/etc/systemd/system/duckterm-web.service
  else
    service_path="$HOME/.config/systemd/user/duckterm-web.service"
  fi
  if [ -f "$service_path" ]; then
    cp -p "$service_path" "$service_state/duckterm-web.service"
    service_was_present=1
  fi
  systemctl_web is-active --quiet duckterm-web >/dev/null 2>&1 && service_was_running=1 || true
  systemctl_web is-enabled --quiet duckterm-web >/dev/null 2>&1 && service_was_enabled=1 || true
fi

restart_previous_service() {
  case "$service_kind" in
    launchd) /bin/launchctl bootstrap "$service_scope/$(id -u)" "$service_path" >/dev/null 2>&1 ;;
    systemd) systemctl_web start duckterm-web >/dev/null 2>&1 ;;
    sysv) "$service_path" start >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# Stop the exact existing owner before replacing application bytes. Ordinary
# Unix filesystems allow renaming a directory whose scripts are still mapped,
# but WSL1's wslfs can reject it with EPERM. More importantly, stopping first
# gives every platform one lifecycle contract and prevents old code from
# racing the newly registered owner during activation.
if [ "$service_was_running" -eq 1 ]; then
  case "$service_kind" in
    launchd)
      /bin/launchctl bootout "$service_scope/$(id -u)/com.duckterm.web" >/dev/null 2>&1 ||
        die "could not stop the previous launchd owner"
      ;;
    systemd)
      systemctl_web stop duckterm-web >/dev/null 2>&1 ||
        die "could not stop the previous systemd owner"
      ;;
    sysv)
      "$service_path" stop >/dev/null 2>&1 ||
        die "could not stop the previous SysV owner"
      ;;
  esac
  service_stopped=1
fi

rm -rf "$backup"
if [ -e "$APP_DIR" ]; then mv "$APP_DIR" "$backup"; fi
mv "$stage" "$APP_DIR"
stage="$APP_DIR.__activated__"
activated=1
if node_supported "$APP_DIR/node/node"; then NODE="$APP_DIR/node/node"; else NODE="$SYS_NODE"; fi
node_supported "$NODE" || rollback

rollback() {
  warn "installation did not become healthy; restoring the previous application"
  case "$service_kind" in
    launchd)
      /bin/launchctl bootout "gui/$(id -u)/com.duckterm.web" >/dev/null 2>&1 || true
      /bin/launchctl bootout "user/$(id -u)/com.duckterm.web" >/dev/null 2>&1 || true
      rm -f "$service_path"
      ;;
    systemd)
      systemctl_web stop duckterm-web >/dev/null 2>&1 || true
      systemctl_web disable duckterm-web >/dev/null 2>&1 || true
      rm -f "$service_path"
      systemctl_web daemon-reload >/dev/null 2>&1 || true
      ;;
    sysv)
      [ ! -x "$service_path" ] || "$service_path" stop >/dev/null 2>&1 || true
      update-rc.d -f duckterm-web remove >/dev/null 2>&1 || true
      rm -f "$service_path"
      [ -z "$wsl_launcher" ] || rm -f "$wsl_launcher"
      ;;
  esac
  rm -rf "$APP_DIR"
  if [ -d "$backup" ]; then
    mv "$backup" "$APP_DIR"
  fi

  mkdir -p "$(dirname "$config_path")"
  if [ "$config_was_present" -eq 1 ]; then
    cp -p "$service_state/config.json" "$config_path"
  else
    rm -f "$config_path"
  fi

  case "$service_kind" in
    launchd)
      if [ "$service_was_present" -eq 1 ]; then
        mkdir -p "$(dirname "$service_path")"
        cp -p "$service_state/com.duckterm.web.plist" "$service_path"
        if [ "$service_was_running" -eq 1 ]; then
          /bin/launchctl bootstrap "$service_scope/$(id -u)" "$service_path" >/dev/null 2>&1 ||
            warn "ROLLBACK INCOMPLETE: previous launchd owner did not restart"
        fi
      fi
      ;;
    systemd)
      if [ "$service_was_present" -eq 1 ]; then
        mkdir -p "$(dirname "$service_path")"
        cp -p "$service_state/duckterm-web.service" "$service_path"
      fi
      systemctl_web daemon-reload >/dev/null 2>&1 || true
      if [ "$service_was_enabled" -eq 1 ]; then
        systemctl_web enable duckterm-web >/dev/null 2>&1 ||
          warn "ROLLBACK INCOMPLETE: previous systemd owner was not re-enabled"
      fi
      if [ "$service_was_running" -eq 1 ]; then
        systemctl_web start duckterm-web >/dev/null 2>&1 ||
          warn "ROLLBACK INCOMPLETE: previous systemd owner did not restart"
      fi
      ;;
    sysv)
      if [ "$service_was_present" -eq 1 ]; then
        cp -p "$service_state/duckterm-web.init" "$service_path"
        chmod 0755 "$service_path"
        [ "$service_was_enabled" -eq 0 ] || update-rc.d duckterm-web defaults >/dev/null 2>&1 || true
        [ "$service_was_running" -eq 0 ] || "$service_path" start >/dev/null 2>&1 ||
          warn "ROLLBACK INCOMPLETE: previous SysV owner did not restart"
      fi
      if [ "$wsl_launcher_was_present" -eq 1 ] && [ -n "$wsl_launcher" ]; then
        mkdir -p "$(dirname "$wsl_launcher")"
        cp -p "$service_state/DuckTerm-Web.cmd" "$wsl_launcher"
      fi
      ;;
  esac

  if [ "$homebrew_was_running" -eq 1 ] && [ -n "$homebrew_bin" ]; then
    "$homebrew_bin" services start duckterm-web >/dev/null 2>&1 || true
  fi
  exit 1
}

# Optional, explicit migration for a private/direct build on a Mac that was
# previously supervised by Homebrew. It runs only after the new app directory
# is activated, so a filesystem activation failure cannot strand the existing
# service. A later health failure removes the new app-owned LaunchAgent and
# restores the previously-running Homebrew owner.
if [ "$OS" = darwin ] && [ "${DUCKTERM_MIGRATE_HOMEBREW:-}" = 1 ]; then
  if [ -n "$homebrew_bin" ]; then
    if /bin/launchctl print "gui/$(id -u)/homebrew.mxcl.duckterm-web" >/dev/null 2>&1 \
      || /bin/launchctl print "user/$(id -u)/homebrew.mxcl.duckterm-web" >/dev/null 2>&1; then
      homebrew_was_running=1
    fi
    if ! "$brew" services stop duckterm-web >/dev/null 2>&1; then
      warn "could not stop the Homebrew-owned DuckTerm Web service"
      rollback
    fi
  fi
fi

if [ "${DUCKTERM_NO_SERVICE:-}" = 1 ]; then
  rm -rf "$backup"
  say "installed v$package_version to $APP_DIR (service registration skipped)"
  say "run: $NODE $APP_DIR/duckterm.mjs foreground --lan"
  exit 0
fi

# Preserve an existing bind/port unless the operator explicitly overrides it.
HOST_OVERRIDE=""
[ "${DUCKTERM_EXPOSE:-}" = 1 ] && HOST_OVERRIDE="0.0.0.0"
PORT_OVERRIDE="${DUCKTERM_PORT:-}"
DUCKTERM_INSTALL_HOST="$HOST_OVERRIDE" DUCKTERM_INSTALL_PORT="$PORT_OVERRIDE" \
  "$NODE" --input-type=module - "$APP_DIR" "$NODE" <<'NODEJS' || rollback
const [appDir, nodePath] = process.argv.slice(2);
const sm = await import(`${appDir}/service-manager.mjs`);
const existing = sm.readBridgeConfig(undefined, { host: "127.0.0.1", port: 1420 });
const host = process.env.DUCKTERM_INSTALL_HOST || existing.host || "127.0.0.1";
const port = Number(process.env.DUCKTERM_INSTALL_PORT || existing.port || 1420);
const result = sm.installService({
  nodePath,
  bridgeEntry: `${appDir}/dev-bridge.mjs`,
  launcherEntry: `${appDir}/duckterm.mjs`,
  distPath: `${appDir}/dist`,
  workdir: appDir,
  port,
  host,
  forceReconcile: true,
});
if (!result.ok) throw new Error(result.error || "service_install_failed");
if (result.reloadNeeded) {
  const restarted = sm.restartService();
  if (!restarted.ok) throw new Error(restarted.error || "service_restart_failed");
}
NODEJS

scheme=http
host=127.0.0.1
config_host=$("$NODE" -p "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).host" "$HOME/.duckterm/config.json" 2>/dev/null || echo 127.0.0.1)
config_port=$("$NODE" -p "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).port" "$HOME/.duckterm/config.json" 2>/dev/null || echo 1420)
case "$config_host" in 127.0.0.1|localhost|::1) ;; *) scheme=https; host=localhost ;; esac
healthy=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if curl -kfsS --max-time 2 "$scheme://$host:$config_port/" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 1
done
[ "$healthy" -eq 1 ] || rollback
rm -rf "$backup"
say "installed DuckTerm Web v$package_version; service is healthy and auto-start is enabled"
"$NODE" "$APP_DIR/duckterm.mjs" status
