#!/usr/bin/env sh
# DuckTerm Web — one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ducksee/duckterm-web-releases/main/install.sh | sh
#
# What it does:
#   1. Detects OS + arch.
#   2. Picks the smallest package that will run here:
#        - system node >= 22.5 present  → "tiny"  (~10MB, no bundled node)
#        - otherwise                     → "full-<os>-<arch>" (bundles node)
#      Override with DUCKTERM_FLAVOR=tiny|full.
#   3. Downloads + verifies (SHA256) + extracts to ~/.duckterm/app.
#   4. Installs a persistent service (systemd / launchd) and starts it.
#   5. Prints the URL + one-time token.
#
# Env knobs:
#   DUCKTERM_VERSION=0.1.0     pin a version (default: latest)
#   DUCKTERM_FLAVOR=tiny|full  force a package
#   DUCKTERM_EXPOSE=1          bind 0.0.0.0 + HTTPS (LAN/remote); else localhost+HTTP
#   DUCKTERM_PORT=1420
#   DUCKTERM_NO_SERVICE=1      just install, don't register a boot service
#   DUCKTERM_TARBALL=/path.tgz install from a local tarball (offline / testing)

set -eu

REPO="ducksee/duckterm-web-releases"
APP_DIR="${DUCKTERM_APP_DIR:-$HOME/.duckterm/app}"
PORT="${DUCKTERM_PORT:-1420}"
MIN_NODE_MAJOR=22
MIN_NODE_MINOR=5

say()  { printf '\033[1;36m[duckterm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[duckterm]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[duckterm]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- detect os/arch ----------------------------------------------------
uname_s=$(uname -s)
uname_m=$(uname -m)
case "$uname_s" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux ;;
  *) die "unsupported OS: $uname_s (macOS / Linux only)" ;;
esac
case "$uname_m" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x64 ;;
  *) die "unsupported arch: $uname_m" ;;
esac

# ---- find a usable node ------------------------------------------------
# Prefer PATH node, then nvm/brew common spots. Returns "" if none >= min.
find_node() {
  for cand in \
    "$(command -v node 2>/dev/null || true)" \
    /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node \
    "$HOME"/.nvm/versions/node/*/bin/node
  do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    v=$("$cand" -p 'process.versions.node' 2>/dev/null || echo 0.0.0)
    maj=$(echo "$v" | cut -d. -f1); min=$(echo "$v" | cut -d. -f2)
    if [ "${maj:-0}" -gt "$MIN_NODE_MAJOR" ] 2>/dev/null || \
       { [ "${maj:-0}" -eq "$MIN_NODE_MAJOR" ] && [ "${min:-0}" -ge "$MIN_NODE_MINOR" ]; } 2>/dev/null; then
      echo "$cand"; return 0
    fi
  done
  return 0
}

SYS_NODE=$(find_node)
FLAVOR="${DUCKTERM_FLAVOR:-}"
if [ -z "$FLAVOR" ]; then
  if [ -n "$SYS_NODE" ]; then FLAVOR=tiny; else FLAVOR=full; fi
fi
say "platform: $OS-$ARCH | node: ${SYS_NODE:-none (bundling)} | flavor: $FLAVOR"

# ---- resolve version + asset name -------------------------------------
if [ "$FLAVOR" = tiny ]; then ASSET_SUFFIX="tiny"; else ASSET_SUFFIX="full-$OS-$ARCH"; fi

# ---- download (or use local tarball) ----------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -n "${DUCKTERM_TARBALL:-}" ]; then
  say "using local tarball $DUCKTERM_TARBALL"
  cp "$DUCKTERM_TARBALL" "$tmp/pkg.tar.gz"
else
  VER="${DUCKTERM_VERSION:-}"
  if [ -z "$VER" ]; then
    VER=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/') \
      || die "could not resolve latest version"
  fi
  ASSET="duckterm-web-v${VER}-${ASSET_SUFFIX}.tar.gz"
  URL="https://github.com/$REPO/releases/download/v${VER}/${ASSET}"
  say "downloading $ASSET"
  curl -fsSL -o "$tmp/pkg.tar.gz" "$URL" || die "download failed: $URL"
  # verify sha256 if SHA256SUMS is published
  if curl -fsSL -o "$tmp/SHA256SUMS" "https://github.com/$REPO/releases/download/v${VER}/SHA256SUMS" 2>/dev/null; then
    want=$(grep " $ASSET\$" "$tmp/SHA256SUMS" | awk '{print $1}')
    if [ -n "$want" ]; then
      if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/pkg.tar.gz" | awk '{print $1}')
      else got=$(shasum -a 256 "$tmp/pkg.tar.gz" | awk '{print $1}'); fi
      [ "$want" = "$got" ] || die "sha256 mismatch (want $want got $got)"
      say "sha256 verified"
    fi
  fi
fi

# ---- extract -----------------------------------------------------------
say "installing to $APP_DIR"
rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"
tar -xzf "$tmp/pkg.tar.gz" -C "$APP_DIR"

# node to run with: bundled (full) or system (tiny)
if [ -x "$APP_DIR/node/node" ]; then NODE="$APP_DIR/node/node"; else NODE="$SYS_NODE"; fi
[ -n "$NODE" ] || die "no node available and package has no bundled node"

# ---- start / install service ------------------------------------------
LAUNCH_ARGS=""
[ "${DUCKTERM_EXPOSE:-}" = "1" ] && LAUNCH_ARGS="--lan"
LAUNCH_ARGS="$LAUNCH_ARGS --port $PORT"

if [ "${DUCKTERM_NO_SERVICE:-}" = "1" ]; then
  say "skipping service install (DUCKTERM_NO_SERVICE=1). Run manually:"
  say "  $NODE $APP_DIR/duckterm.mjs $LAUNCH_ARGS"
  exit 0
fi

# The launcher can install the persistent service itself via the bridge's
# /api/service/install, but at install time it's simplest to let the
# service-manager wire it directly. We start the launcher once (it also
# writes the token + cert) then the ServicePanel / CLI can 'install'.
# For a hands-off install we register the service now via a tiny node call.
say "registering persistent service + starting"
DUCKTERM_HOST="127.0.0.1"; SCHEME="http"
if [ "${DUCKTERM_EXPOSE:-}" = "1" ]; then DUCKTERM_HOST="0.0.0.0"; SCHEME="https"; fi

"$NODE" --input-type=module - "$APP_DIR" "$NODE" "$PORT" "$DUCKTERM_HOST" <<'NODEJS'
const [appDir, nodePath, port, host] = process.argv.slice(2);
const { installService } = await import(`${appDir}/service-manager.mjs`);
const r = installService({
  nodePath,
  bridgeEntry: `${appDir}/dev-bridge.mjs`,
  distPath: `${appDir}/dist`,
  workdir: appDir,
  port: Number(port),
  host,
});
console.log("[duckterm] service:", r.ok ? "installed" : "FAILED", r.error || "");
if (!r.ok) process.exit(1);
NODEJS

sleep 3
# print URL(s) + token
TOKEN=$(cat "$HOME/.duckterm/dev-bridge-token" 2>/dev/null || echo "")
say "─── DuckTerm Web is running ───"
if [ "${DUCKTERM_EXPOSE:-}" = "1" ]; then
  ip=$( (command -v hostname >/dev/null && hostname -I 2>/dev/null | awk '{print $1}') || echo "<lan-ip>" )
  say "  $SCHEME://$ip:$PORT/#token=$TOKEN"
fi
say "  $SCHEME://localhost:$PORT/#token=$TOKEN"
say "first visit → set up an admin account → then log in with a password."
