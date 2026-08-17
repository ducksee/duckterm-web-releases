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

shell_quote() {
  # POSIX single-quote serialization for the generated launcher/profile.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

path_contains_dir() {
  case ":${PATH:-}:" in
    *:"$1":*) return 0 ;;
    *) return 1 ;;
  esac
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

# The service always uses absolute paths. Separately expose one stable CLI
# entry so a fresh interactive shell can run `duckterm-web` without knowing
# the versioned app directory or bundled Node location.
if [ -n "${DUCKTERM_CLI_BIN_DIR:-}" ]; then
  cli_bin_dir=$DUCKTERM_CLI_BIN_DIR
elif [ "$(id -u)" -eq 0 ]; then
  cli_bin_dir=/usr/local/bin
else
  cli_bin_dir="$HOME/.local/bin"
fi
case "$cli_bin_dir" in
  /*) ;;
  *) die "DUCKTERM_CLI_BIN_DIR must be absolute: $cli_bin_dir" ;;
esac
cli_path="$cli_bin_dir/duckterm-web"
cli_marker="# DuckTerm Web CLI wrapper"
cli_was_present=0
if [ -e "$cli_path" ] || [ -L "$cli_path" ]; then
  grep -Fq "$cli_marker" "$cli_path" 2>/dev/null ||
    die "refusing to replace an unmanaged CLI entry: $cli_path"
  cli_was_present=1
fi

cli_profile_path=""
cli_profile_kind=posix
cli_profile_was_present=0
if ! path_contains_dir "$cli_bin_dir"; then
  case "${SHELL##*/}" in
    zsh) cli_profile_path="$HOME/.zprofile" ;;
    fish)
      cli_profile_path="$HOME/.config/fish/conf.d/duckterm-web-path.fish"
      cli_profile_kind=fish
      ;;
    *) cli_profile_path="$HOME/.profile" ;;
  esac
fi

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
if [ "$cli_was_present" -eq 1 ]; then
  cp -pP "$cli_path" "$service_state/duckterm-web.cli"
fi
if [ -n "$cli_profile_path" ] && [ -f "$cli_profile_path" ]; then
  cp -p "$cli_profile_path" "$service_state/cli-profile"
  cli_profile_was_present=1
fi

systemctl_web() {
  if [ "$(id -u)" -eq 0 ]; then systemctl "$@"; else systemctl --user "$@"; fi
}

# PIDs of foreground DuckTerm Web processes owned by this app dir. Argv alone
# is not a reliable key: an instance launched with `cd app && node duckterm.mjs`
# shows a relative script path in ps. /proc/<pid>/cwd is authoritative on the
# no-init Linux hosts where the foreground service kind applies.
fg_owner_pids() {
  for _pid in $(pgrep -f 'duckterm\.mjs|dev-bridge\.mjs' 2>/dev/null); do
    # Only ever target the launcher/bridge themselves — both are node. A
    # viewer or editor that merely mentions the script in argv while sitting
    # in the app dir (vim duckterm.mjs, less, tail -f, grep ...) must never
    # enter the kill set.
    case "$(readlink "/proc/$_pid/exe" 2>/dev/null)" in
      */node|*/nodejs) ;;
      *) continue ;;
    esac
    # cwd catches relative-argv instances; it may point at the previous
    # install's rollback dir (readlink appends " (deleted)" once that dir is
    # gone), so match the backup path as a prefix too.
    case "$(readlink "/proc/$_pid/cwd" 2>/dev/null)" in
      "$APP_DIR"|"$APP_DIR"/*|"$backup"*) printf '%s\n' "$_pid"; continue ;;
    esac
    # cmdline catches absolute-argv instances launched from any cwd.
    case "$(tr '\0' ' ' <"/proc/$_pid/cmdline" 2>/dev/null)" in
      *"$APP_DIR/"*) printf '%s\n' "$_pid" ;;
    esac
  done
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
elif [ "$(cat /proc/1/comm 2>/dev/null || true)" != systemd ] ||
  ! command -v systemctl >/dev/null 2>&1; then
  # Container / no-init Linux (PID 1 = tini, sh, ...). While systemd is
  # offline, `systemctl enable` still succeeds (it only writes symlinks) but
  # nothing can ever start the unit; the install would then time out its
  # health check and roll back with no explanation. Treat foreground as the
  # first-class service kind: the container's own supervisor is the boot
  # persistence layer, and the install validates the package by running a
  # temporary real instance instead of pretending a service manager exists.
  service_kind=foreground
  service_path="$APP_DIR/run.sh"
  [ -n "$(fg_owner_pids)" ] && service_was_running=1 || true
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

restore_cli_exposure() {
  rm -f "$cli_path"
  if [ "$cli_was_present" -eq 1 ]; then
    mkdir -p "$cli_bin_dir"
    cp -pP "$service_state/duckterm-web.cli" "$cli_path"
  fi
  if [ -n "$cli_profile_path" ]; then
    if [ "$cli_profile_was_present" -eq 1 ]; then
      mkdir -p "$(dirname "$cli_profile_path")"
      cp -p "$service_state/cli-profile" "$cli_profile_path"
    else
      rm -f "$cli_profile_path"
    fi
  fi
}

install_cli_exposure() {
  mkdir -p "$cli_bin_dir"
  cli_tmp=$(mktemp "${cli_path}.tmp.XXXXXX") || return 1
  {
    printf '#!/bin/sh\n%s\n' "$cli_marker"
    printf 'exec %s %s "$@"\n' "$(shell_quote "$NODE")" "$(shell_quote "$APP_DIR/duckterm.mjs")"
  } >"$cli_tmp" || { rm -f "$cli_tmp"; return 1; }
  chmod 0755 "$cli_tmp" || { rm -f "$cli_tmp"; return 1; }
  mv "$cli_tmp" "$cli_path" || { rm -f "$cli_tmp"; return 1; }

  [ -n "$cli_profile_path" ] || return 0
  mkdir -p "$(dirname "$cli_profile_path")" || return 1
  profile_tmp=$(mktemp "${cli_profile_path}.tmp.XXXXXX") || return 1
  if [ -f "$cli_profile_path" ]; then
    awk '
      $0 == "# >>> DuckTerm Web CLI >>>" { skipping=1; next }
      $0 == "# <<< DuckTerm Web CLI <<<" { skipping=0; next }
      !skipping { print }
    ' "$cli_profile_path" >"$profile_tmp" || { rm -f "$profile_tmp"; return 1; }
  fi
  {
    printf '\n# >>> DuckTerm Web CLI >>>\n'
    if [ "$cli_profile_kind" = fish ]; then
      printf 'fish_add_path --global --move %s\n' "$(shell_quote "$cli_bin_dir")"
    else
      quoted_cli_bin=$(shell_quote "$cli_bin_dir")
      printf 'case ":$PATH:" in *:%s:*) ;; *) PATH=%s:$PATH; export PATH ;; esac\n' \
        "$quoted_cli_bin" "$quoted_cli_bin"
    fi
    printf '# <<< DuckTerm Web CLI <<<\n'
  } >>"$profile_tmp" || { rm -f "$profile_tmp"; return 1; }
  mv "$profile_tmp" "$cli_profile_path" || { rm -f "$profile_tmp"; return 1; }
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
    foreground)
      # Kill the cwd-derived pid set: the launcher (duckterm.mjs) spawns
      # dev-bridge.mjs as the child that owns the listening socket, and either
      # may appear in ps with a relative script path. Leaving the bridge alive
      # would keep the port held and turn the health check into a false green.
      fg_pids=$(fg_owner_pids)
      [ -n "$fg_pids" ] || die "could not stop the previous foreground owner"
      kill $fg_pids 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        [ -z "$(fg_owner_pids)" ] && break
        sleep 1
      done
      [ -z "$(fg_owner_pids)" ] || die "could not stop the previous foreground owner"
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
    foreground)
      # Stop whatever health-check instance is still attached to the app dir;
      # $!-derived pgids are unreliable here (setsid may have forked).
      rollback_fg_pids=$(fg_owner_pids)
      [ -z "$rollback_fg_pids" ] || kill $rollback_fg_pids 2>/dev/null || true
      ;;
  esac
  rm -rf "$APP_DIR"
  if [ -d "$backup" ]; then
    mv "$backup" "$APP_DIR"
  fi

  restore_cli_exposure

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
    foreground)
      if [ "$service_was_running" -eq 1 ]; then
        # The restored app dir is the previous version, which may predate
        # run.sh — do not point at a file that might not exist.
        warn "ROLLBACK INCOMPLETE: restart your previous foreground instance with your supervisor"
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

install_cli_exposure || rollback

if [ "${DUCKTERM_NO_SERVICE:-}" = 1 ]; then
  rm -rf "$backup"
  say "installed v$package_version to $APP_DIR (service registration skipped)"
  say "CLI: $cli_path"
  [ -z "$cli_profile_path" ] || say "PATH registration: $cli_profile_path (open a new shell)"
  say "run: $NODE $APP_DIR/duckterm.mjs foreground --lan"
  exit 0
fi

if [ "$service_kind" = foreground ]; then
  run_sh="$APP_DIR/run.sh"
  {
    printf '#!/bin/sh\n'
    printf '# DuckTerm Web entry for hosts without an init supervisor (containers).\n'
    printf '# Wire this into the container supervisor for boot persistence, e.g.\n'
    printf '#   docker CMD / compose command: ["%s"]\n' "$run_sh"
    printf '#   ad hoc: setsid nohup %s >/var/log/duckterm-web.log 2>&1 &\n' "$run_sh"
    printf 'cd %s || exit 1\n' "$(shell_quote "$APP_DIR")"
    printf 'exec %s %s foreground --lan\n' "$(shell_quote "$NODE")" "$(shell_quote "$APP_DIR/duckterm.mjs")"
  } >"$run_sh"
  chmod 0755 "$run_sh"
  # Health-check the real application: launch a temporary foreground instance,
  # probe it, stop it. This proves the package runs on this machine without
  # pretending an init system exists.
  config_port="${DUCKTERM_PORT:-1420}"
  # The health check is only honest if it can see OUR instance. A lingering
  # listener (an unstopped previous owner, or an unrelated process) would
  # answer the probe and green-light an install that never ran.
  if curl -kfsS --max-time 2 "https://127.0.0.1:$config_port/" >/dev/null 2>&1 ||
    curl -fsS --max-time 2 "http://127.0.0.1:$config_port/" >/dev/null 2>&1; then
    warn "port $config_port is already served by another process; cannot health-check the new install"
    rollback
  fi
  fg_log="$HOME/.duckterm/web-install-health.log"
  setsid "$run_sh" >>"$fg_log" 2>&1 &
  healthy=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl -kfsS --max-time 2 "https://127.0.0.1:$config_port/" >/dev/null 2>&1 ||
      curl -fsS --max-time 2 "http://127.0.0.1:$config_port/" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 1
  done
  # Tear the temporary instance down to zero before declaring success: a
  # lingering listener would race (and mask) the real supervisor's instance.
  # Do not signal the recorded $! process group: setsid forks when the
  # background child already leads a group, so that pgid can be dead while
  # the instance lives on under a subreaper. The cwd-derived pid set is the
  # authoritative handle.
  fg_pids=$(fg_owner_pids)
  [ -z "$fg_pids" ] || kill $fg_pids 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    [ -z "$(fg_owner_pids)" ] && break
    sleep 1
  done
  fg_pids=$(fg_owner_pids)
  if [ -n "$fg_pids" ]; then
    kill -KILL $fg_pids 2>/dev/null || true
    sleep 1
  fi
  [ -z "$(fg_owner_pids)" ] || warn "temporary health-check instance did not exit; stop it before starting the supervisor"
  [ "$healthy" -eq 1 ] || rollback
  rm -rf "$backup"
  say "installed DuckTerm Web v$package_version (validated with a temporary foreground instance; log: $fg_log)"
  say "CLI: $cli_path"
  [ -z "$cli_profile_path" ] || say "PATH registration: $cli_profile_path (open a new shell)"
  say "PID 1 is $(cat /proc/1/comm 2>/dev/null || echo unknown), not systemd: boot persistence is delegated to your container supervisor"
  say "start now: setsid nohup $run_sh >/var/log/duckterm-web.log 2>&1 &"
  say "persist:   point the container supervisor (docker CMD / compose / s6) at $run_sh"
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
say "CLI: $cli_path"
[ -z "$cli_profile_path" ] || say "PATH registration: $cli_profile_path (open a new shell)"
say "installed DuckTerm Web v$package_version; service is healthy and auto-start is enabled"
"$NODE" "$APP_DIR/duckterm.mjs" status
