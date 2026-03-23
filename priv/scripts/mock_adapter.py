#!/usr/bin/env python3
"""Mock inference engine adapter for GPU-free development.

Reads line-delimited JSON from stdin, writes responses to stdout.
Speaks the Loom wire protocol (see KNOWLEDGE.md section 4.4).
Runs until stdin is closed (EOF).

Uses only Python stdlib — no external dependencies.
"""
import json
import sys


MOCK_TOKENS = ["Hello", "from", "Loom", "mock", "adapter"]


def handle_health(_msg):
    return [{"type": "health", "status": "ok", "gpu_util": 0.0, "mem_used_gb": 0.0}]


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
        return [{"type": "error", "message": "generate request missing 'id' field"}]

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


HANDLERS = {
    "health": handle_health,
    "memory": handle_memory,
    "generate": handle_generate,
}


def process_line(line):
    """Parse a JSON line and return response dicts."""
    try:
        msg = json.loads(line)
    except json.JSONDecodeError as e:
        return [{"type": "error", "message": f"invalid JSON: {e}"}]

    msg_type = msg.get("type")
    if msg_type is None:
        return [{"type": "error", "message": "message missing 'type' field"}]

    handler = HANDLERS.get(msg_type)
    if handler is None:
        return [{"type": "error", "message": f"unknown message type: {msg_type}"}]

    return handler(msg)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        responses = process_line(line)
        for resp in responses:
            sys.stdout.write(json.dumps(resp) + '\n')
        sys.stdout.flush()


if __name__ == '__main__':
    main()
