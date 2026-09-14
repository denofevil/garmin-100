#!/usr/bin/env bash
# Environment startup for the garmin-100 Chrome extension.
#
# Does two things, both of which are cached into the warm-up snapshot:
#   1. npm dependencies + a production webpack build (dist/*.bundle.js).
#   2. A userspace Chrome (Chrome for Testing + the shared libraries this slim
#      image is missing) so the documented verification loop -- load the
#      unpacked extension in Chrome, drive it over CDP / chrome-devtools-mcp --
#      actually works here. There is no sudo, so everything lands under $HOME.
set -euo pipefail

log() { printf '[startup] %s\n' "$*"; }
warn() { printf '[startup][warn] %s\n' "$*" >&2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [ "${AIR_STARTUP_MODE:-}" = warmup ]; then WARMUP=1; else WARMUP=; fi

CHROME_DEPS_DIR="$HOME/.cache/chrome-deps"
CHROME_DEPS_MARKER="$CHROME_DEPS_DIR/.installed-v1"
PUPPETEER_CACHE="$HOME/.cache/puppeteer"
BIN_DIR="$HOME/.local/bin"
ENV_FILE="$HOME/.air-env-garmin100.sh"
CDP_PORT=9333
BUILD_OK=1
CHROME_BIN=""

# Shared libraries Chrome for Testing needs that the base image does not ship.
# Only the ones actually missing are kept (see prune below) so nothing shadows
# a system library.
CHROME_LIB_PACKAGES="
libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64
libcups2t64 libdrm2 libgbm1 libasound2t64 libexpat1 libglib2.0-0t64
libdbus-1-3 libsystemd0 libcap2 libgcrypt20 libgpg-error0
liblzma5 libzstd1 libavahi-common3 libavahi-client3
libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0 libcairo2
libcairo-gobject2 libpixman-1-0 libharfbuzz0b libgraphite2-3 libthai0
libdatrie1 libfribidi0 libfontconfig1 libfreetype6
libx11-6 libx11-xcb1 libxau6 libxdmcp6 libbsd0 libmd0 libxcb1 libxcb-dri2-0
libxcb-dri3-0 libxcb-glx0 libxcb-present0 libxcb-randr0 libxcb-render0
libxcb-shape0 libxcb-shm0 libxcb-sync1 libxcb-util1 libxcb-xfixes0
libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6
libxinerama1 libxkbcommon0 libxrandr2 libxrender1 libxshmfence1 libxtst6
libwayland-client0 libwayland-egl1 libwayland-server0
fonts-liberation fontconfig-config
"

# ---------------------------------------------------------------- node deps --
install_node_deps() {
  if [ -d node_modules ] && [ node_modules -nt package-lock.json ]; then
    log "node_modules is up to date, skipping install"
    return
  fi
  log "installing npm dependencies (npm ci)"
  if ! npm ci; then
    warn "npm ci failed, falling back to npm install"
    npm install
  fi
  touch node_modules
  log "npm dependencies installed"
}

# --------------------------------------------------------- chrome libraries --
install_chrome_libs() {
  if [ -f "$CHROME_DEPS_MARKER" ]; then
    log "chrome shared libraries already present in $CHROME_DEPS_DIR"
    return 0
  fi

  log "downloading chrome shared libraries from the ubuntu archive (no sudo, extracted into \$HOME)"
  local tmp staging deb base
  tmp="$(mktemp -d)"
  staging="$tmp/root"
  mkdir -p "$staging"

  # shellcheck disable=SC2086
  if ! (cd "$tmp" && apt-get download $CHROME_LIB_PACKAGES 2>&1 | tail -n 3); then
    warn "apt-get download failed; some packages may be unavailable, continuing with what was fetched"
  fi

  if ! ls "$tmp"/*.deb >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  for deb in "$tmp"/*.deb; do
    dpkg -x "$deb" "$staging"
  done

  # Never shadow a library the image already provides: LD_LIBRARY_PATH wins over
  # the system cache, so drop every file that also exists in the system libdir.
  local dir sysdir
  for dir in "$staging/usr/lib/x86_64-linux-gnu" "$staging/lib/x86_64-linux-gnu"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      base="$(basename "$f")"
      for sysdir in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
        if [ -e "$sysdir/$base" ]; then rm -f "$f"; break; fi
      done
    done
  done

  rm -rf "$CHROME_DEPS_DIR"
  mkdir -p "$(dirname "$CHROME_DEPS_DIR")"
  mv "$staging" "$CHROME_DEPS_DIR"
  rm -rf "$tmp"
  touch "$CHROME_DEPS_MARKER"
  log "chrome shared libraries installed ($(find "$CHROME_DEPS_DIR" -name '*.so*' | wc -l) libraries kept)"
}

# ------------------------------------------------------------ chrome binary --
find_chrome() {
  ls -d "$PUPPETEER_CACHE"/chrome/*/chrome-linux64/chrome 2>/dev/null | sort -V | tail -n 1
}

install_chrome() {
  if [ -n "$(find_chrome)" ]; then
    log "chrome for testing already downloaded"
  else
    log "downloading chrome for testing into $PUPPETEER_CACHE (this is cached in the snapshot)"
    npx --yes puppeteer@24 browsers install chrome 2>&1 | tail -n 2
  fi
  CHROME_BIN="$(find_chrome)"
  [ -n "$CHROME_BIN" ]
}

chrome_env_exports() {
  cat <<EOF
export CHROME_DEPS_DIR="$CHROME_DEPS_DIR"
export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}$CHROME_DEPS_DIR/usr/lib/x86_64-linux-gnu:$CHROME_DEPS_DIR/lib/x86_64-linux-gnu"
export FONTCONFIG_PATH="$CHROME_DEPS_DIR/etc/fonts"
export XDG_DATA_DIRS="$CHROME_DEPS_DIR/usr/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export CHROME_PATH="$CHROME_BIN"
export PUPPETEER_EXECUTABLE_PATH="$CHROME_BIN"
export PUPPETEER_CACHE_DIR="$PUPPETEER_CACHE"
export PATH="$BIN_DIR:\$PATH"
EOF
}

write_chrome_wrappers() {
  mkdir -p "$BIN_DIR"
  # chrome-devtools-mcp / puppeteer look for a "system" chrome by name; give
  # them one that pulls in the userspace libraries first.
  cat > "$BIN_DIR/google-chrome" <<EOF
#!/bin/sh
. "$ENV_FILE"
exec "$CHROME_BIN" "\$@"
EOF
  chmod +x "$BIN_DIR/google-chrome"
  ln -sf "$BIN_DIR/google-chrome" "$BIN_DIR/google-chrome-stable"
  ln -sf "$BIN_DIR/google-chrome" "$BIN_DIR/chrome"
}

# ----------------------------------------------------------- login-shell env --
install_env_file() {
  chrome_env_exports > "$ENV_FILE"

  local marker="# >>> air garmin-100 env >>>"
  local line=". \"$ENV_FILE\""
  local profile=""
  local f
  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$f" ]; then profile="$f"; break; fi
  done
  if [ -z "$profile" ]; then profile="$HOME/.profile"; touch "$profile"; fi

  for f in "$profile" "$HOME/.bashrc"; do
    [ -f "$f" ] || touch "$f"
    if ! grep -qF "$marker" "$f"; then
      printf '\n%s\n%s\n# <<< air garmin-100 env <<<\n' "$marker" "$line" >> "$f"
    fi
  done
  log "environment exports written to $ENV_FILE and sourced from $profile and ~/.bashrc"
}

# ------------------------------------------------------------------- build ---
build_extension() {
  log "building the extension (webpack --mode production)"
  if npm run build; then
    log "build finished: $(ls dist/*.bundle.js 2>/dev/null | tr '\n' ' ')"
  else
    BUILD_OK=0
    warn "npm run build FAILED (see the webpack/ts-loader output above)"
  fi
}

# prime the npx cache for the MCP servers declared in .mcp.json, so the first
# real task does not pay the download. Best effort only.
prime_mcp_servers() {
  log "priming npx cache for the .mcp.json servers"
  npx --yes chrome-devtools-mcp@latest --version >/dev/null 2>&1 || warn "could not prime chrome-devtools-mcp"
  npx --yes @mizchi/lsmcp@latest --help >/dev/null 2>&1 || warn "could not prime lsmcp"
}

# ------------------------------------------------------------- healthcheck ---
# Asserts the environment can do what a real task on this repo needs:
#   * the extension builds and the bundle Chrome is asked to load is valid JS,
#   * every file manifest.json references exists,
#   * Chrome starts headless here and executes that content bundle in a page
#     without throwing (this is the loop chrome-devtools-mcp automates).
healthcheck() {
  log "healthcheck: verifying the build output"

  if [ "$BUILD_OK" != "1" ]; then
    warn "healthcheck: the webpack build failed"
    return 1
  fi

  local bundle="$REPO_ROOT/dist/content.bundle.js"
  if [ ! -s "$bundle" ]; then
    warn "healthcheck: $bundle is missing or empty"
    return 1
  fi
  if ! node --check "$bundle"; then
    warn "healthcheck: $bundle is not valid javascript"
    return 1
  fi

  # every path manifest.json points at must exist on disk, otherwise Chrome
  # silently refuses to load the unpacked extension.
  local missing
  missing="$(node -e '
    const fs = require("fs"), path = require("path");
    const root = process.argv[1];
    const m = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"));
    const files = [
      ...Object.values(m.icons || {}),
      ...(m.content_scripts || []).flatMap(cs => [...(cs.js || []), ...(cs.css || [])]),
    ];
    console.log(files.filter(f => !fs.existsSync(path.join(root, f))).join(" "));
  ' "$REPO_ROOT")"
  if [ -n "$missing" ]; then
    warn "healthcheck: manifest.json references missing files: $missing"
    return 1
  fi
  log "healthcheck: dist/content.bundle.js is valid and manifest.json resolves"

  if [ -z "$CHROME_BIN" ]; then
    warn "healthcheck: no chrome binary available"
    return 1
  fi

  # shellcheck disable=SC1090
  . "$ENV_FILE"

  log "healthcheck: starting headless chrome with the unpacked extension"
  rm -rf /tmp/air-chrome-profile /tmp/air-chrome.log
  "$CHROME_BIN" \
    --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --user-data-dir=/tmp/air-chrome-profile \
    --remote-debugging-port="$CDP_PORT" \
    --load-extension="$REPO_ROOT" \
    about:blank > /tmp/air-chrome.log 2>&1 &
  local chrome_pid=$!
  # shellcheck disable=SC2064
  trap "kill $chrome_pid 2>/dev/null || true" RETURN

  local i=0
  until curl -s --noproxy '*' "http://127.0.0.1:$CDP_PORT/json/version" > /tmp/air-cdp-version.json 2>/dev/null; do
    if ! kill -0 "$chrome_pid" 2>/dev/null; then
      warn "healthcheck: chrome exited before the devtools endpoint came up:"
      tail -n 20 /tmp/air-chrome.log >&2
      return 1
    fi
    i=$((i + 1))
    [ $((i % 10)) -eq 0 ] && log "healthcheck: still waiting for chrome devtools on port $CDP_PORT (${i}s)"
    sleep 1
  done
  log "healthcheck: chrome is up -- $(node -e 'console.log(JSON.parse(require("fs").readFileSync("/tmp/air-cdp-version.json","utf8")).Browser)')"

  log "healthcheck: executing dist/content.bundle.js in a page over CDP"
  local smoke=/tmp/air-cdp-smoke.mjs
  cat > "$smoke" <<'SMOKE'
// Opens a blank page in the running chrome and evaluates the built content
// bundle in it: proves the browser works and the bundle is executable there.
import { readFileSync } from 'node:fs';

const port = process.env.CDP_PORT;
const source = readFileSync(process.env.BUNDLE, 'utf8');
const base = `http://127.0.0.1:${port}`;

const target = await (await fetch(`${base}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
const pending = new Map();
const logs = [];
let nextId = 0;

ws.addEventListener('message', (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  } else if (msg.method === 'Runtime.consoleAPICalled') {
    logs.push((msg.params.args || []).map((a) => a.value).join(' '));
  } else if (msg.method === 'Runtime.exceptionThrown') {
    logs.push(`EXCEPTION ${msg.params.exceptionDetails?.text}`);
  }
});

const send = (method, params = {}) =>
  new Promise((resolve) => {
    const id = ++nextId;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });

await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, { once: true });
  ws.addEventListener('error', reject, { once: true });
});

await send('Runtime.enable');
const evaluated = await send('Runtime.evaluate', { expression: source, returnByValue: true });
const details = evaluated.result?.exceptionDetails;

await fetch(`${base}/json/close/${target.id}`);
ws.close();

if (details) {
  console.error(`content bundle threw: ${details.text} ${details.exception?.description ?? ''}`);
  process.exit(1);
}
console.log(`content bundle executed in chrome; console output: ${JSON.stringify(logs)}`);
SMOKE
  if ! CDP_PORT="$CDP_PORT" BUNDLE="$bundle" NO_PROXY='*' no_proxy='*' node "$smoke"; then
    warn "healthcheck: the content bundle did not run cleanly in chrome"
    tail -n 20 /tmp/air-chrome.log >&2
    return 1
  fi

  log "healthcheck: OK"
}

# ------------------------------------------------------------------- main ----
log "mode=${AIR_STARTUP_MODE:-task} repo=$REPO_ROOT"

install_node_deps

if install_chrome_libs && install_chrome; then
  write_chrome_wrappers
  install_env_file
  log "chrome available at $CHROME_BIN (also on PATH as google-chrome)"
else
  CHROME_BIN=""
  chrome_env_exports > "$ENV_FILE"
  install_env_file
  if [ -n "$WARMUP" ]; then
    warn "could not provision chrome; the extension verification loop would not work"
    exit 1
  fi
  warn "could not provision chrome; continuing (build-only environment)"
fi

build_extension
prime_mcp_servers

if [ -n "$WARMUP" ]; then
  healthcheck
fi

log "startup finished"
