#!/usr/bin/env bash
# Environment startup for the "Garmin Swim 100" Chrome extension.
#
# The project is a TypeScript + webpack MV3 extension: there is no server and no
# test suite, so the development loop is `npm ci` -> `tsc --noEmit` -> `webpack`.
# Everything expensive here (npm cache, node_modules, first webpack build) is
# bytes on disk, so it is captured by the warmup snapshot and free for real tasks.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$HOME/.air-env.sh"
ENV_MARKER="# air-env: garmin-100"

if [ "${AIR_STARTUP_MODE:-}" = warmup ]; then WARMUP=1; else WARMUP=; fi

log() { echo "[startup] $*"; }

# --- environment variables -------------------------------------------------
# Exports from this script die with it, so persist them in a file that the
# agent's login shell and interactive shells both source.
persist_env() {
  cat >"$ENV_FILE" <<EOF
$ENV_MARKER
# Locally installed CLIs (webpack, tsc, ...) without npx indirection.
case ":\$PATH:" in
  *":$REPO_DIR/node_modules/.bin:"*) ;;
  *) PATH="$REPO_DIR/node_modules/.bin:\$PATH"; export PATH ;;
esac
EOF

  local profile
  for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$candidate" ]; then profile="$candidate"; break; fi
  done
  profile="${profile:-$HOME/.profile}"

  # A login shell reads only the first of those files, so hook that one and
  # ~/.bashrc for non-login interactive shells. The marker keeps it idempotent.
  for rc in "$profile" "$HOME/.bashrc"; do
    touch "$rc"
    if ! grep -qF "$ENV_MARKER" "$rc"; then
      printf '\n%s\n[ -f "%s" ] && . "%s"\n' "$ENV_MARKER" "$ENV_FILE" "$ENV_FILE" >>"$rc"
      log "hooked $ENV_FILE into $rc"
    fi
  done
}

# --- dependencies ----------------------------------------------------------
install_deps() {
  log "node $(node --version), npm $(npm --version)"
  log "installing npm dependencies (npm ci) ..."

  # npm ci is the only network step; give a flaky registry a few chances.
  local attempt
  for attempt in 1 2 3; do
    if npm ci --no-audit --fund=false; then
      log "npm ci succeeded (attempt $attempt)"
      return 0
    fi
    log "npm ci failed (attempt $attempt); retrying in $((attempt * 5))s"
    sleep $((attempt * 5))
  done

  log "ERROR: npm ci failed after 3 attempts - see the output above."
  return 1
}

# --- health check ----------------------------------------------------------
# Asserts the environment can actually do what a task needs: type-check the
# sources and produce the extension bundles that manifest.json ships.
healthcheck() {
  log "healthcheck: verifying the extension toolchain"
  cd "$REPO_DIR"

  for tool in node npm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "healthcheck FAILED: $tool is not on PATH"
      return 1
    fi
  done

  # node_modules must be usable, not merely present.
  log "healthcheck: waiting for a usable node_modules ..."
  while true; do
    if [ -x node_modules/.bin/tsc ] && [ -x node_modules/.bin/webpack ]; then
      log "healthcheck: node_modules ready"
      break
    fi
    log "healthcheck: node_modules incomplete (tsc/webpack missing); installing"
    install_deps || return 1
  done

  log "healthcheck: type-checking (tsc --noEmit) ..."
  if ! node_modules/.bin/tsc --noEmit; then
    log "healthcheck FAILED: tsc --noEmit reported errors"
    return 1
  fi
  log "healthcheck: type-check clean"

  log "healthcheck: production build (npm run build) ..."
  if ! npm run build; then
    log "healthcheck FAILED: npm run build did not succeed"
    return 1
  fi

  # webpack can exit 0 while emitting nothing useful, so assert the artifacts
  # really landed: every webpack entry bundle, plus every script manifest.json
  # ships. (package.json "main" is stale - it names dist/background.js while
  # webpack emits dist/background.bundle.js - so it is deliberately not used.)
  local expected
  expected="$(node -e '
    const path = require("path");
    const cfg = require("./webpack.config.js");
    const outDir = path.relative(process.cwd(), cfg.output.path);
    const template = cfg.output.filename;
    const files = Object.keys(cfg.entry || {})
      .map((name) => path.join(outDir, template.replace("[name]", name)));
    for (const cs of require("./manifest.json").content_scripts || []) {
      files.push(...(cs.js || []));
    }
    console.log([...new Set(files.filter(Boolean))].join("\n"));
  ')"

  local missing=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -s "$f" ]; then
      log "healthcheck: built $f ($(wc -c <"$f" | tr -d ' ') bytes)"
    else
      log "healthcheck FAILED: expected bundle $f is missing or empty"
      missing=1
    fi
  done <<<"$expected"
  [ "$missing" -eq 0 ] || return 1

  log "healthcheck: OK - dependencies, type-check and extension bundles all good"
}

# --- main ------------------------------------------------------------------
log "mode=${AIR_STARTUP_MODE:-task} repo=$REPO_DIR"
cd "$REPO_DIR"

persist_env
install_deps

if [ -n "${WARMUP:-}" ]; then
  # Warmup bakes the snapshot: block here so the primed npm cache,
  # node_modules and dist/ bundles land on disk before teardown.
  healthcheck
else
  # Real task run: dependencies are already in the snapshot, so return
  # immediately and let the agent drive builds itself.
  log "task mode: skipping build smoke, run 'npm run build' as needed"
fi

log "startup complete"
