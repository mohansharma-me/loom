#!/usr/bin/env python3
"""Mock inference engine adapter for GPU-free development.

Reads line-delimited JSON from stdin, writes responses to stdout.
Speaks the Loom wire protocol (see KNOWLEDGE.md section 4.4).

Startup protocol:
  1. Send one heartbeat immediately (status=loading).
  2. If --startup-delay > 0, loop sending periodic heartbeats until delay elapses.
  3. Send ready message.
  4. Enter command loop.

Stdin watchdog: daemon thread reads stdin byte-by-byte; on EOF calls os._exit(1).
This is the cross-platform force-kill mechanism when the Erlang port is closed.

Uses only Python stdlib — no external dependencies.
"""
import argparse
import json
import os
import queue
import sys
import threading
import time
import traceback


# ASSUMPTION: Fixed mock tokens simulate a generate response; real adapter will stream actual model output.
MOCK_TOKENS = ["Hello", "from", "Loom", "mock", "adapter"]

# ASSUMPTION: TOKEN_DELAY defaults to 0.0 (no delay) so existing tests pass unchanged.
# Set via --token-delay CLI argument in main() before the command loop starts.
TOKEN_DELAY = 0.0


def send_msg(msg):
    """Write a JSON message + newline to stdout and flush immediately."""
    sys.stdout.write(json.dumps(msg) + '\n')
    sys.stdout.flush()


# ASSUMPTION: Returns zeroed GPU metrics since no real GPU is present.
# ASSUMPTION: mem_total_gb fixed at 80.0 to approximate H100 GPU specs (see KNOWLEDGE.md).
def handle_health(_msg):
    return [{"type": "health", "status": "ok", "gpu_util": 0.0,
             "mem_used_gb": 0.0, "mem_total_gb": 80.0}]


# ASSUMPTION: Returns 80GB total to approximate H100 GPU specs (see KNOWLEDGE.md).
def handle_memory(_msg):
    return [
        {
            "type": "memory",
            "total_gb": 80.0,
            "used_gb": 0.0,
            "available_gb": 80.0,
        }
    ]


def handle_generate(msg):
    req_id = msg.get("id")
    if req_id is None:
        return [{"type": "error", "code": "missing_field",
                 "message": "generate request missing 'id' field"}]

    # ASSUMPTION: Tokens are sent inline (via send_msg) so that TOKEN_DELAY
    # can be applied between each token. The function returns [] so the
    # caller's response-sending loop has nothing extra to send.
    for i, token_text in enumerate(MOCK_TOKENS):
        if i > 0 and TOKEN_DELAY > 0:
            time.sleep(TOKEN_DELAY)
        send_msg({
            "type": "token",
            "id": req_id,
            "token_id": i + 1,
            "text": token_text,
            "finished": False,
        })
    send_msg({
        "type": "done",
        "id": req_id,
        "tokens_generated": len(MOCK_TOKENS),
        "time_ms": 0,
    })
    return []


def handle_cancel(msg):
    # Fire-and-forget: no response. In real adapter, would abort generation.
    return []


def handle_shutdown(_msg):
    print("[mock_adapter] shutdown requested, exiting", file=sys.stderr)
    sys.stderr.flush()
    sys.stdout.flush()
    # ASSUMPTION: os._exit(0) is used instead of sys.exit(0) to bypass Python's
    # atexit/thread cleanup, which can SIGABRT when daemon threads are blocked on I/O.
    os._exit(0)


# ASSUMPTION: Protocol matches KNOWLEDGE.md section 4.4 line-delimited JSON wire protocol.
HANDLERS = {
    "health": handle_health,
    "memory": handle_memory,
    "generate": handle_generate,
    "cancel": handle_cancel,
    "shutdown": handle_shutdown,
}


def process_line(line):
    """Parse a JSON line and return response dicts."""
    try:
        msg = json.loads(line)
    except json.JSONDecodeError as e:
        return [{"type": "error", "code": "invalid_json",
                 "message": f"invalid JSON: {e}"}]

    msg_type = msg.get("type")
    if msg_type is None:
        return [{"type": "error", "code": "missing_type",
                 "message": "message missing 'type' field"}]

    handler = HANDLERS.get(msg_type)
    if handler is None:
        return [{"type": "error", "code": "unknown_type",
                 "message": f"unknown message type: {msg_type}"}]

    return handler(msg)


def startup_sequence(startup_delay, heartbeat_interval):
    """Send heartbeat(s) during loading, then send ready.

    Always sends at least one heartbeat before ready.
    If startup_delay > 0, sends periodic heartbeats every heartbeat_interval
    seconds until the delay elapses, then sends ready.
    """
    # ASSUMPTION: Initial heartbeat is always sent regardless of startup_delay,
    # so loom_port always sees at least one heartbeat before ready.
    send_msg({"type": "heartbeat", "status": "loading",
              "detail": "initializing mock engine"})

    if startup_delay > 0:
        deadline = time.monotonic() + startup_delay
        while time.monotonic() < deadline:
            sleep_time = min(heartbeat_interval, deadline - time.monotonic())
            if sleep_time <= 0:
                break
            time.sleep(sleep_time)
            if time.monotonic() < deadline:
                send_msg({"type": "heartbeat", "status": "loading",
                          "detail": "initializing mock engine"})

    send_msg({"type": "ready", "model": "mock", "backend": "mock"})


def stdin_watchdog(line_queue):
    """Daemon thread: read all stdin lines, detect EOF, and force-exit.

    Reads stdin line by line via sys.stdin.buffer.readline(). On EOF
    (empty bytes returned), calls os._exit(1) to force-terminate the process.
    This is the cross-platform mechanism used by loom_port's 3-level shutdown
    escalation: closing the Erlang port EOF's stdin which triggers this watchdog.

    Lines read are put into line_queue for the main command loop to process.

    ASSUMPTION: os._exit(1) is used (not sys.exit) to bypass Python cleanup
    and guarantee immediate termination even if the main thread is blocked.
    ASSUMPTION: This thread is the ONLY reader of sys.stdin so there is no
    race between it and the main loop.
    """
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            # EOF — stdin was closed; force-terminate immediately
            print("[mock_adapter] stdin closed (watchdog), force-exiting",
                  file=sys.stderr)
            os._exit(1)
        line_queue.put(line)


def main():
    parser = argparse.ArgumentParser(description="Loom mock inference adapter")
    parser.add_argument(
        '--startup-delay',
        type=float,
        default=0.0,
        help="Simulated model loading delay in seconds (default: 0)"
    )
    parser.add_argument(
        '--heartbeat-interval',
        type=float,
        default=5.0,
        help="Interval between heartbeats during startup delay in seconds (default: 5.0)"
    )
    parser.add_argument(
        '--token-delay',
        type=float,
        default=0.0,
        help="Delay in seconds between each generated token (default: 0.0)"
    )
    args = parser.parse_args()

    # Set module-level TOKEN_DELAY so handle_generate can use it.
    global TOKEN_DELAY
    TOKEN_DELAY = args.token_delay

    print("[mock_adapter] started, reading from stdin", file=sys.stderr)

    # ASSUMPTION: line_queue is the sole channel between the stdin watchdog thread
    # and the main command loop. The watchdog is the ONLY reader of sys.stdin.
    line_queue = queue.Queue()

    # Start stdin watchdog as a daemon thread (won't block process exit).
    # The watchdog is the sole stdin reader; it forwards lines to line_queue
    # and calls os._exit(1) on EOF.
    watchdog = threading.Thread(
        target=stdin_watchdog, args=(line_queue,), daemon=True, name="stdin-watchdog"
    )
    watchdog.start()

    # Send startup sequence (heartbeat + ready)
    startup_sequence(args.startup_delay, args.heartbeat_interval)

    # Enter command loop — reads lines from the queue fed by the watchdog thread
    while True:
        try:
            raw_line = line_queue.get()
        except Exception as e:
            print(f"[mock_adapter] ERROR: line_queue.get() failed: {e}",
                  file=sys.stderr)
            os._exit(2)
        line = raw_line.decode(errors='replace').strip()
        if not line:
            continue
        try:
            responses = process_line(line)
            for resp in responses:
                sys.stdout.write(json.dumps(resp) + '\n')
            sys.stdout.flush()
        except Exception as e:
            print(f"[mock_adapter] ERROR: {type(e).__name__}: {e}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            error_resp = {"type": "error", "code": "internal_error",
                          "message": f"internal adapter error: {type(e).__name__}: {e}"}
            try:
                sys.stdout.write(json.dumps(error_resp) + '\n')
                sys.stdout.flush()
            except Exception as write_err:
                print(f"[mock_adapter] FATAL: failed to write error response: {write_err}",
                      file=sys.stderr)
                sys.exit(1)


if __name__ == '__main__':
    main()
