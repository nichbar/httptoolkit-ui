#!/usr/bin/env bash
#
# dev.sh - One-command launcher for the HTTP Toolkit UI dev environment.
#
# Usage:
#   ./dev.sh                      Start everything (installs deps on first run)
#   ./dev.sh start [--force]      Same; --force kills whatever holds port 8080 first
#   ./dev.sh stop [--all]         Stop the web UI + any server started from THIS repo.
#                                 (--all: also stop any HTTP Toolkit server, even one
#                                  started elsewhere, e.g. the sibling server repo)
#   ./dev.sh restart [flags...]   stop + start
#
# Start works around three known issues:
#
#   1. Install: `npm ci` rolls back completely when puppeteer's Chromium
#      download fails on Apple Silicon, so deps are installed with
#      `--ignore-scripts` (fine for running the app, only affects tests).
#      Also re-installs if @httptoolkit/accounts is stale (< 3.x), which
#      breaks typechecking.
#
#   2. Notify crash: fork-ts-checker-notifier calls node-notifier after each
#      compile, and its bundled terminal-notifier can fail to spawn
#      (errno -86), whose uncaught error kills webpack-dev-server. The script
#      patches node-notifier in node_modules (idempotent, reapplied after
#      reinstalls).
#
#   3. Server: the UI talks to the HTTP Toolkit server on 127.0.0.1:45457
#      (mockttp proxy on 45456). If one is already running and healthy (e.g.
#      your dev server from the sibling httptoolkit-server repo), it is
#      reused and only the web UI is started; otherwise both are started.
#
# Stop only kills processes owned by this repo (matched by working directory),
# so a separately-started server elsewhere is left alone unless --all is given.
#
# UI: http://localhost:8080

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(pwd -P)"

log() { printf '\n[dev] %s\n' "$*"; }

port_in_use() {
    lsof -iTCP:"$1" -sTCP:LISTEN -P >/dev/null 2>&1
}

pids_on_port() {
    lsof -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
}

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CMD=start
FORCE=false
ALL=false
for arg in "$@"; do
    case "$arg" in
        start|stop|restart) CMD="$arg" ;;
        --force) FORCE=true ;;
        --all) ALL=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------

# Server processes that belong to this repo: the renamed "HTTP Toolkit Server"
# main process, its wrappers, and the setup/downloader - filtered by cwd so
# identical servers started from other checkouts are spared (unless --all).
repo_server_pids() {
    local pid cwd
    for pid in $(pgrep -f 'HTTP Toolkit Server|httptoolkit-server/bin/run|automation/setup-server.ts' 2>/dev/null || true); do
        if $ALL; then
            printf '%s\n' "$pid"
            continue
        fi
        cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)"
        if [ "$cwd" = "$REPO_ROOT" ]; then
            printf '%s\n' "$pid"
        fi
    done
}

kill_and_wait() {
    local pids="$1" label="$2" waited any pid
    if [ -z "${pids// /}" ]; then return 0; fi

    log "Stopping ${label}: $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true

    waited=0
    while [ "$waited" -lt 20 ]; do
        any=false
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && any=true
        done
        $any || return 0
        sleep 0.5
        waited=$((waited + 1))
    done

    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    log "${label} did not exit cleanly - force-killed."
}

do_stop() {
    local web_pids server_pids
    web_pids="$(pids_on_port 8080)"
    server_pids="$(repo_server_pids | sort -u | tr '\n' ' ')"

    if [ -z "${web_pids}" ] && [ -z "${server_pids// /}" ]; then
        log "Nothing to stop: no web UI on port 8080, no server from this repo."
    else
        kill_and_wait "$web_pids" "web UI"
        kill_and_wait "$server_pids" "local server"
        log "Stopped."
    fi

    if ! $ALL && port_in_use 45457; then
        log "Note: a server on 127.0.0.1:45457 is still running (not started from this repo)."
        log "      Stop it in its own terminal, or run: ./dev.sh stop --all"
    fi
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
do_start() {
    # 1. Dependencies
    local accounts_major
    accounts_major="$(node -p "require('./node_modules/@httptoolkit/accounts/package.json').version.split('.')[0]" 2>/dev/null || echo 0)"
    if [ ! -x node_modules/.bin/webpack-dev-server ] || [ "${accounts_major:-0}" -lt 3 ]; then
        log "Installing dependencies (npm ci --ignore-scripts)..."
        npm ci --no-audit --no-fund --ignore-scripts
    fi

    # 2. node-notifier spawn-crash workaround (idempotent)
    local notifier_file="node_modules/node-notifier/notifiers/notificationcenter.js"
    if [ -f "$notifier_file" ] && ! grep -q 'Disabled locally' "$notifier_file"; then
        log "Patching node-notifier (spawn crash workaround)..."
        NOTIFIER_FILE="$notifier_file" node <<'EOF'
const fs = require('fs');
const file = process.env.NOTIFIER_FILE;
const needle = 'function notifyRaw(options, callback) {';
let src = fs.readFileSync(file, 'utf8');
if (!src.includes(needle)) {
    console.error(`[dev] Warning: pattern not found in ${file}, skipping patch`);
    process.exit(0);
}
src = src.replace(needle, `${needle}
  // Disabled locally: the bundled terminal-notifier fails to spawn on this
  // machine (errno -86), and its uncaught error crashes webpack-dev-server.
  if (typeof callback === 'function') callback(null);
  return this;
`);
fs.writeFileSync(file, src);
EOF
    fi

    # 3. Port 8080: web UI already running?
    if port_in_use 8080; then
        if $FORCE; then
            kill_and_wait "$(pids_on_port 8080)" "web UI (restarting)"
        else
            echo "[dev] Port 8080 is already in use - the UI is probably running at http://localhost:8080" >&2
            echo "      Re-run with --force to restart it, or run './dev.sh stop' first." >&2
            exit 1
        fi
    fi

    # 4. Start: reuse an existing server if healthy, otherwise run both
    local server_version
    server_version="$(curl -sf --max-time 2 -H 'Origin: http://localhost:8080' \
        http://127.0.0.1:45457/version 2>/dev/null || true)"

    if printf '%s' "$server_version" | grep -q '"version"'; then
        log "Reusing existing HTTP Toolkit server on 127.0.0.1:45457 (${server_version})"
        log "Starting web UI only -> http://localhost:8080  (Ctrl+C to stop)"
        exec npm run start:web
    elif port_in_use 45457; then
        echo "[dev] Port 45457 is in use, but that process did not answer /version." >&2
        echo "      It is not a working HTTP Toolkit server - stop it and re-run." >&2
        exit 1
    else
        log "No server on 127.0.0.1:45457 - starting web UI + local server"
        log "First run also downloads/sets up httptoolkit-server (can take a few minutes)"
        log "Web UI -> http://localhost:8080  (Ctrl+C to stop)"
        exec npm start
    fi
}

case "$CMD" in
    stop)    do_stop ;;
    start)   do_start ;;
    restart) do_stop; do_start ;;
esac
