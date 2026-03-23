#!/usr/bin/env python3
"""Mock inference engine adapter for GPU-free development.

Reads line-delimited JSON from stdin, writes responses to stdout.
Speaks the Loom wire protocol (see KNOWLEDGE.md section 4.4).
Runs until stdin is closed (EOF).

Uses only Python stdlib — no external dependencies.
"""
import json
import sys


# ASSUMPTION: Fixed mock tokens simulate a generate response; real adapter will stream actual model output.
MOCK_TOKENS = ["Hello", "from", "Loom", "mock", "adapter"]


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

    responses = []
    for i, token_text in enumerate(MOCK_TOKENS):
        responses.append(
            {
                "type": "token",
                "id": req_id,
                "token_id": i + 1,
                "text": token_text,
                "finished": False,
            }
        )
    responses.append(
        {
            "type": "done",
            "id": req_id,
            "tokens_generated": len(MOCK_TOKENS),
            "time_ms": 0,
        }
    )
    return responses


def handle_cancel(msg):
    # Fire-and-forget: no response. In real adapter, would abort generation.
    return []


def handle_shutdown(_msg):
    print("[mock_adapter] shutdown requested, exiting", file=sys.stderr)
    sys.exit(0)


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


def main():
    print("[mock_adapter] started, reading from stdin", file=sys.stderr)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            responses = process_line(line)
            for resp in responses:
                sys.stdout.write(json.dumps(resp) + '\n')
            sys.stdout.flush()
        except Exception as e:
            error_resp = {"type": "error", "code": "internal_error",
                          "message": f"internal adapter error: {e}"}
            try:
                sys.stdout.write(json.dumps(error_resp) + '\n')
                sys.stdout.flush()
            except Exception:
                pass
            print(f"[mock_adapter] ERROR: {e}", file=sys.stderr)
    print("[mock_adapter] stdin closed, shutting down", file=sys.stderr)


if __name__ == '__main__':
    main()
