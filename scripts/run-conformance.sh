#!/bin/bash
set -euo pipefail

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Configuration ──────────────────────────────────────────────────────────
# PINNED. An unpinned suite is a moving target: scenario sets shift between
# releases, so a number from one run is not comparable to the next. Pin both
# the suite and the spec revision, or the harness cannot detect spec drift.
#
# Override the suite when measuring a revision the default pin does not know:
# 0.1.16 knows 2025-03-26 / 2025-06-18 / 2025-11-25 only, and answers
# "Unknown spec version: 2026-07-28" otherwise. Newer revisions live in a
# prerelease tag whose scenario set is still moving — label those figures
# provisional.
SUITE_VERSION="${SUITE_VERSION:-0.1.16}"
CONFORMANCE_PKG="@modelcontextprotocol/conformance@${SUITE_VERSION}"
SPEC_VERSION="${SPEC_VERSION:-2025-11-25}"
SERVER_URL="${SERVER_URL:-http://127.0.0.1:3001/mcp}"
SERVER_PORT="${SERVER_PORT:-3001}"

CLIENT_EXEC="mcp-everything-client"
SERVER_EXEC="mcp-everything-server"
BASELINE_FILE="${BASELINE_FILE:-conformance-baseline.yml}"
MODE="${MODE:-both}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)      MODE="$2"; shift 2 ;;
    --baseline)  BASELINE_FILE="$2"; shift 2 ;;
    --spec)      SPEC_VERSION="$2"; shift 2 ;;
    --url)       SERVER_URL="$2"; SERVER_PORT="${2##*:}"; SERVER_PORT="${SERVER_PORT%%/*}"; shift 2 ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ ! "$MODE" =~ ^(client|server|both)$ ]]; then
  log_error "Invalid mode: $MODE. Must be one of: client, server, both"
  exit 1
fi

SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log_info "Stopping server (PID $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ── Build ──────────────────────────────────────────────────────────────────
# Each product is built and then VERIFIED. `swift build --product a --product b`
# can succeed while emitting only one of them, which then surfaces as a
# conformance failure rather than a build failure.
log_info "Building Swift executables..."
for product in "$CLIENT_EXEC" "$SERVER_EXEC"; do
  swift build --product "$product" || { log_error "Failed to build $product"; exit 1; }
done

BIN_DIR="$(swift build --show-bin-path)"
CLIENT_PATH="$BIN_DIR/$CLIENT_EXEC"
SERVER_PATH="$BIN_DIR/$SERVER_EXEC"

for exe in "$CLIENT_PATH" "$SERVER_PATH"; do
  if [[ ! -x "$exe" ]]; then
    log_error "Expected binary missing after build: $exe"
    log_error "A build that reports success but emits no binary is a build failure, not a conformance result."
    exit 1
  fi
done
log_info "Client executable: $CLIENT_PATH"
log_info "Server executable: $SERVER_PATH"

# ── Baseline ───────────────────────────────────────────────────────────────
BASELINE_ARG=()
if [[ -f "$BASELINE_FILE" ]]; then
  log_info "Using baseline file: $BASELINE_FILE"
  BASELINE_ARG=(--expected-failures "$BASELINE_FILE")
else
  log_warn "No baseline file found at $BASELINE_FILE"
fi

# ── Scenario inventory ─────────────────────────────────────────────────────
# The suite has no --list flag, but an unknown scenario makes it print every
# scenario it knows. That is the inventory, and it stays correct as the suite
# grows instead of going stale like a hardcoded list.
list_scenarios() {
  local side="$1"
  npx "$CONFORMANCE_PKG" "$side" --url "$SERVER_URL" --scenario __invalid__ 2>&1 \
    | awk '/^Available .* scenarios:/{f=1;next} /^Available suites:/{f=0} f && /^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}'
}

# ── Run one scenario in isolation ──────────────────────────────────────────
# The suite executes scenarios in PARALLEL and exposes no serial flag. Under
# load the server's server-to-client round trips time out, and a DIFFERENT
# subset of scenarios fails on each run — a varying failure set that reads as
# a spec defect but is a harness artifact. Every scenario that fails here
# passes when run alone. Running them one at a time is what makes the result
# deterministic; a scenario failing ALONE is a real finding.
FAILED_SCENARIOS=()
SKIPPED_SCENARIOS=()
run_scenario() {
  local side="$1" scenario="$2"
  # The two sides take different options and reject the other's: client mode
  # takes --command, server mode takes --url. Passing both fails with
  # "unknown option '--command'" and every scenario errors out identically.
  local out
  local -a args
  if [[ "$side" == "client" ]]; then
    args=(--command "$CLIENT_PATH")
  else
    args=(--url "$SERVER_URL")
  fi

  out="$(npx "$CONFORMANCE_PKG" "$side" \
      "${args[@]}" \
      --scenario "$scenario" \
      --spec-version "$SPEC_VERSION" \
      "${BASELINE_ARG[@]+"${BASELINE_ARG[@]}"}" 2>&1)" || true

  # Single-scenario runs report "Passed: N/N, X failed", NOT the "Total: ..." line
  # that a multi-scenario suite run prints. Matching only the suite form makes
  # every scenario look like a failure.
  #
  # SKIPPED must be classified before either verdict. The suite skips a scenario
  # whose applicability window excludes the requested spec ("SKIPPED: scenario
  # 'ping' is not applicable at spec version 2026-07-28 (introduced in
  # 2025-06-18, removed in 2026-07-28)") and prints no Passed: line at all.
  # Counting that as a failure inflates the total with scenarios the
  # implementation is not even asked to support.
  if grep -qE '^SKIPPED: scenario' <<<"$out"; then
    SKIPPED_SCENARIOS+=("$scenario")
    log_info "  SKIP  $scenario  (not applicable at $SPEC_VERSION)"
  elif grep -qE '^Passed: [0-9]+/[0-9]+, 0 failed' <<<"$out"; then
    log_info "  PASS  $scenario"
  else
    log_warn "  FAIL  $scenario"
    FAILED_SCENARIOS+=("$scenario")
    grep -E 'FAILURE|Error:' <<<"$out" | head -3 | sed 's/^/          /' || true
  fi
}

# ── Client ─────────────────────────────────────────────────────────────────
if [[ "$MODE" == "client" || "$MODE" == "both" ]]; then
  log_info "Client conformance @ $SPEC_VERSION (suite: $CONFORMANCE_PKG)"
  for scenario in $(list_scenarios client); do
    run_scenario client "$scenario"
  done
fi

# ── Server ─────────────────────────────────────────────────────────────────
if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
  # An exclusive port. A second server on the same port logs "Address already
  # in use" and still starts in a degraded state, turning into phantom
  # conformance failures that look like spec bugs.
  if command -v lsof >/dev/null 2>&1 && lsof -ti:"$SERVER_PORT" >/dev/null 2>&1; then
    log_error "Port $SERVER_PORT is already in use — another conformance server may be running."
    log_error "Stop it first:  pkill -f $SERVER_EXEC"
    exit 1
  fi

  log_info "Starting server for conformance testing..."
  "$SERVER_PATH" >/tmp/conformance-server.log 2>&1 &
  SERVER_PID=$!

  # Health check instead of a blind sleep.
  READY=0
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 1 "$SERVER_URL" 2>/dev/null; then READY=1; break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    sleep 0.5
  done

  if [[ "$READY" -ne 1 ]]; then
    log_error "Server did not become ready on $SERVER_URL"
    log_error "--- server log ---"; tail -20 /tmp/conformance-server.log || true
    exit 1
  fi
  log_info "Server ready (PID $SERVER_PID)"

  log_info "Server conformance @ $SPEC_VERSION, one scenario at a time"
  for scenario in $(list_scenarios server); do
    run_scenario server "$scenario"
  done

  cleanup
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
log_info "=== $SPEC_VERSION | $CONFORMANCE_PKG ==="
if [[ ${#SKIPPED_SCENARIOS[@]} -gt 0 ]]; then
  log_info "${#SKIPPED_SCENARIOS[@]} scenario(s) skipped — not applicable at $SPEC_VERSION"
fi
if [[ ${#FAILED_SCENARIOS[@]} -eq 0 ]]; then
  log_info "All applicable scenarios passed at $SPEC_VERSION"
  exit 0
fi

log_error "${#FAILED_SCENARIOS[@]} scenario(s) failed at $SPEC_VERSION:"
for s in "${FAILED_SCENARIOS[@]}"; do
  log_error "  - $s"
done
echo
log_warn "Scenarios here run one at a time, so each failure is a real finding."
log_warn "Cross-check a failure against its single-scenario log above before calling it a bug."
exit 1
