#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Loom Interactive Demo
# =============================================================================
#
# Walks through Loom's key capabilities using the mock backend (no GPU needed).
#
# Demonstrates:
#   1. Health check endpoint
#   2. OpenAI-compatible chat completions
#   3. Server-Sent Events (SSE) streaming
#   4. Anthropic Messages API compatibility
#   5. Engine crash simulation (kill -9)
#   6. Automatic OTP supervisor recovery
#   7. Post-recovery request verification
#
# Prerequisites: erl, rebar3, compiled project (_build/), port 8080 free.
# The mock adapter (priv/scripts/mock_adapter.py) responds instantly with
# canned tokens — no GPU or model weights required.
#
# Usage:
#   ./priv/scripts/demo.sh          # normal run
#   NO_COLOR=1 ./priv/scripts/demo.sh  # disable colored output
# =============================================================================

# ---------------------------------------------------------------------------
# Color setup (respects NO_COLOR convention: https://no-color.org)
# ---------------------------------------------------------------------------
if [ -z "${NO_COLOR:-}" ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  CYAN='\033[0;36m'
  RESET='\033[0m'
else
  GREEN=''
  YELLOW=''
  RED=''
  BOLD=''
  CYAN=''
  RESET=''
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

press_enter() {
  printf "\n${CYAN}Press Enter to continue...${RESET}"
  read -r
}

step_header() {
  local num="$1"
  local title="$2"
  local color="${3:-$BOLD}"
  printf "\n${color}════════════════════════════════════════════════════════════${RESET}\n"
  printf "${color}  Step %s: %s${RESET}\n" "$num" "$title"
  printf "${color}════════════════════════════════════════════════════════════${RESET}\n\n"
}

info() {
  printf "${YELLOW}▸ %s${RESET}\n" "$1"
}

success() {
  printf "${GREEN}✓ %s${RESET}\n" "$1"
}

# ---------------------------------------------------------------------------
# Navigate to project root (two levels up from priv/scripts/)
# ---------------------------------------------------------------------------
cd "$(dirname "$0")/../.." || exit 1

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
printf "${BOLD}Checking prerequisites...${RESET}\n\n"

errors=0

if ! command -v erl >/dev/null 2>&1; then
  printf "${RED}✗ 'erl' not found on PATH. Install Erlang/OTP 27+.${RESET}\n"
  errors=$((errors + 1))
else
  success "'erl' found: $(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell)"
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  printf "${RED}✗ 'rebar3' not found on PATH. See https://rebar3.org${RESET}\n"
  errors=$((errors + 1))
else
  success "'rebar3' found"
fi

if [ ! -d "_build" ]; then
  printf "${RED}✗ '_build/' directory not found. Run 'rebar3 compile' first.${RESET}\n"
  errors=$((errors + 1))
else
  success "'_build/' directory exists"
fi

# ASSUMPTION: python3 is required for JSON formatting (python3 -m json.tool)
# and is also required by Loom itself to run the mock adapter.
if ! command -v python3 >/dev/null 2>&1; then
  printf "${RED}✗ 'python3' not found on PATH. Required for JSON formatting and adapters.${RESET}\n"
  errors=$((errors + 1))
else
  success "'python3' found"
fi

# ASSUMPTION: Checking port 8080 via lsof; falls back to curl if lsof is unavailable.
if command -v lsof >/dev/null 2>&1; then
  if lsof -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then
    printf "${RED}✗ Port 8080 is already in use. Stop the conflicting process first.${RESET}\n"
    errors=$((errors + 1))
  else
    success "Port 8080 is available"
  fi
elif curl -s --connect-timeout 1 http://localhost:8080/ >/dev/null 2>&1; then
  printf "${RED}✗ Port 8080 appears to be in use. Stop the conflicting process first.${RESET}\n"
  errors=$((errors + 1))
else
  success "Port 8080 appears available"
fi

if [ "$errors" -gt 0 ]; then
  printf "\n${RED}%d prerequisite(s) failed. Fix them and try again.${RESET}\n" "$errors"
  exit 1
fi

printf "\n${GREEN}All prerequisites passed!${RESET}\n"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
printf "\n${BOLD}"
printf "  ╔══════════════════════════════════════════════════╗\n"
printf "  ║          Loom Interactive Demo                   ║\n"
printf "  ║  Fault-tolerant inference on Erlang/OTP          ║\n"
printf "  ║  Mock backend — no GPU required                  ║\n"
printf "  ╚══════════════════════════════════════════════════╝${RESET}\n"

press_enter

# ---------------------------------------------------------------------------
# Start Loom in background
# ---------------------------------------------------------------------------
info "Starting Loom (rebar3 shell) in background..."

rebar3 shell --sname loom_demo --setcookie loom_demo < /dev/null > /tmp/loom_demo.log 2>&1 &
LOOM_PID=$!

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
  printf "\n${YELLOW}Stopping Loom...${RESET}\n"
  kill $LOOM_PID 2>/dev/null || true
  wait $LOOM_PID 2>/dev/null || true
  printf "${GREEN}Done.${RESET}\n"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Wait for Loom to be ready (poll /health, timeout 30s)
# ---------------------------------------------------------------------------
info "Waiting for Loom to become ready (timeout: 30s)..."

elapsed=0
timeout=30
while [ "$elapsed" -lt "$timeout" ]; do
  if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
    printf "\n"
    success "Loom is ready! (took ~${elapsed}s)"
    break
  fi
  # Print a dot for each poll attempt (spinner effect)
  printf "."
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ "$elapsed" -ge "$timeout" ]; then
  printf "\n${RED}✗ Timed out waiting for Loom to start.${RESET}\n"
  printf "${YELLOW}Check /tmp/loom_demo.log for details.${RESET}\n"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Health Check
# ═══════════════════════════════════════════════════════════════════════════
step_header 1 "Health Check"
info "Querying the /health endpoint..."
printf "\n"

curl -s http://localhost:8080/health | python3 -m json.tool

success "Health check passed"
press_enter

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Chat Completion (non-streaming)
# ═══════════════════════════════════════════════════════════════════════════
step_header 2 "Chat Completion (Non-Streaming)"
info "Sending an OpenAI-compatible chat completion request..."
printf "\n"

curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "engine_0", "messages": [{"role": "user", "content": "Hello from the demo!"}]}' \
  | python3 -m json.tool

success "Chat completion received"
press_enter

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Streaming (SSE)
# ═══════════════════════════════════════════════════════════════════════════
step_header 3 "Streaming (Server-Sent Events)"
info "Sending a streaming request — tokens arrive as SSE events..."
printf "\n"

curl -sN http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "engine_0", "messages": [{"role": "user", "content": "Tell me about BEAM"}], "stream": true}'

printf "\n"
success "Streaming complete"
press_enter

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Anthropic Messages API
# ═══════════════════════════════════════════════════════════════════════════
step_header 4 "Anthropic Messages API"
info "Sending an Anthropic-compatible /v1/messages request..."
printf "\n"

curl -s http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model": "engine_0", "max_tokens": 64, "messages": [{"role": "user", "content": "Hello from Anthropic API!"}]}' \
  | python3 -m json.tool

success "Anthropic Messages API response received"
press_enter

# ═══════════════════════════════════════════════════════════════════════════
# Step 5: Kill the Engine (dramatic!)
# ═══════════════════════════════════════════════════════════════════════════
step_header 5 "Simulating Engine Crash" "$RED"
info "This is where Loom's fault tolerance shines."
info "We will kill the mock adapter process with SIGKILL (kill -9)."
info "The OTP supervisor should detect the crash and restart it automatically."
printf "\n"

ADAPTER_PID=$(pgrep -f "mock_adapter" 2>/dev/null || true)
if [ -n "$ADAPTER_PID" ]; then
  printf "${RED}  Killing adapter process (PID: %s) with SIGKILL...${RESET}\n" "$ADAPTER_PID"
  kill -9 "$ADAPTER_PID"
  printf "${RED}  ✗ Adapter killed!${RESET}\n"
else
  printf "${YELLOW}  Could not find mock_adapter process — it may have a different name.${RESET}\n"
  printf "${YELLOW}  Continuing with recovery check anyway...${RESET}\n"
fi

press_enter

# ═══════════════════════════════════════════════════════════════════════════
# Step 6: Watch Recovery
# ═══════════════════════════════════════════════════════════════════════════
step_header 6 "Watching Supervisor Recovery"
info "Polling /health every 0.5s to watch the supervisor restart the engine..."
printf "\n"

recovery_start=$(date +%s)
attempts=0
max_attempts=60  # 30 seconds at 0.5s intervals

while [ "$attempts" -lt "$max_attempts" ]; do
  attempts=$((attempts + 1))
  timestamp=$(date +"%H:%M:%S")

  if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
    recovery_end=$(date +%s)
    recovery_time=$((recovery_end - recovery_start))
    printf "  ${GREEN}[%s] Attempt %d: ✓ Engine is back!${RESET}\n" "$timestamp" "$attempts"
    printf "\n"
    success "Engine recovered in ~${recovery_time}s (${attempts} poll attempts)"
    break
  else
    printf "  ${YELLOW}[%s] Attempt %d: ✗ Not ready yet...${RESET}\n" "$timestamp" "$attempts"
  fi

  sleep 0.5
done

if [ "$attempts" -ge "$max_attempts" ]; then
  printf "\n${RED}✗ Engine did not recover within 30 seconds.${RESET}\n"
  printf "${YELLOW}Check /tmp/loom_demo.log for details.${RESET}\n"
  exit 1
fi

press_enter

# ═══════════════════════════════════════════════════════════════════════════
# Step 7: Post-Recovery Request
# ═══════════════════════════════════════════════════════════════════════════
step_header 7 "Post-Recovery Request" "$GREEN"
info "Sending the same chat completion request to prove the system recovered..."
printf "\n"

curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "engine_0", "messages": [{"role": "user", "content": "Hello from the demo!"}]}' \
  | python3 -m json.tool

printf "\n"
success "The system is fully operational after the crash. OTP supervision works!"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
printf "${BOLD}═══════════════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}  === Demo Complete ===${RESET}\n"
printf "${BOLD}═══════════════════════════════════════════════════════════${RESET}\n"
printf "\n"
printf "  Loom demonstrated:\n"
printf "    ${GREEN}✓${RESET} Health monitoring\n"
printf "    ${GREEN}✓${RESET} OpenAI-compatible chat completions\n"
printf "    ${GREEN}✓${RESET} Server-Sent Events streaming\n"
printf "    ${GREEN}✓${RESET} Anthropic Messages API compatibility\n"
printf "    ${GREEN}✓${RESET} Automatic crash recovery via OTP supervision\n"
printf "    ${GREEN}✓${RESET} Zero-downtime fault tolerance\n"
printf "\n"
printf "  ${YELLOW}Learn more: https://github.com/mohansharma-me/loom${RESET}\n"
printf "\n"
