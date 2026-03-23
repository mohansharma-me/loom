#!/usr/bin/env python3
"""Mock inference engine adapter for Loom CI testing.

Subclasses LoomAdapterBase and implements all five abstract methods using
fixed, deterministic behavior -- no GPU or model files required.

Supports:
  --startup-delay FLOAT   Sleep this many seconds inside load_model() to
                          simulate slow model loading (default: 0.0).
  --fail-on-load          Raise RuntimeError from load_model() to test the
                          os._exit(2) error path (default: off).

Wire protocol is handled entirely by LoomAdapterBase.  This file only
contains mock-specific logic.
"""

import asyncio
import os
import sys
import time

# ASSUMPTION: The base module lives in the same directory as this file.
# Using sys.path.insert keeps the import self-contained without requiring
# an installed package or PYTHONPATH configuration.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from loom_adapter_base import LoomAdapterBase  # noqa: E402

# ASSUMPTION: Five fixed tokens are enough to exercise the full streaming
# path (multiple token messages + one done message) in CI without any
# dependency on a real model or tokenizer.
MOCK_TOKENS = ["Hello", "from", "Loom", "mock", "adapter"]


class LoomAdapterMock(LoomAdapterBase):
    """Mock Loom adapter -- deterministic, no GPU, no model files.

    Intended for CI pipelines and protocol integration tests.
    All heavy-compute methods are replaced with lightweight stubs.
    """

    def __init__(self, args):
        super().__init__(args)
        # ASSUMPTION: cancelled_requests is a plain set rather than a
        # thread-safe structure because it is only accessed from the
        # asyncio event loop (single thread).  cancel_request() adds an
        # ID here; generate() checks it between tokens.
        self.cancelled_requests: set = set()

    # -------------------------------------------------------------------------
    # CLI args
    # -------------------------------------------------------------------------

    @classmethod
    def add_args(cls, parser) -> None:
        """Add mock-specific CLI flags to the shared argument parser."""
        parser.add_argument(
            "--startup-delay",
            type=float,
            default=0.0,
            help=(
                "Seconds to sleep inside load_model() to simulate slow "
                "model loading (default: 0.0)."
            ),
        )
        parser.add_argument(
            "--fail-on-load",
            action="store_true",
            default=False,
            help=(
                "Raise RuntimeError from load_model() to exercise the "
                "os._exit(2) fatal-error path (default: off)."
            ),
        )

    # -------------------------------------------------------------------------
    # Abstract method implementations
    # -------------------------------------------------------------------------

    async def load_model(self) -> tuple:
        """Simulate model loading.

        Raises RuntimeError if --fail-on-load was passed (tests exit code 2).
        Otherwise sleeps for --startup-delay seconds then returns fixed names.

        Returns:
            ("mock", "mock")
        """
        # ASSUMPTION: --fail-on-load is checked before the sleep so the
        # error is raised immediately, not after an artificial delay.
        if self.args.fail_on_load:
            raise RuntimeError(
                "load_model() intentionally failed (--fail-on-load set)"
            )

        if self.args.startup_delay > 0.0:
            await asyncio.sleep(self.args.startup_delay)

        return ("mock", "mock")

    async def generate(self, request_id: str, prompt: str, params: dict) -> None:
        """Stream MOCK_TOKENS to the client, respecting max_tokens and cancel.

        Sends each token with send_token(finished=False), yields to the event
        loop between tokens, and finishes with send_done.  Stops early if the
        request_id appears in self.cancelled_requests or if max_tokens is
        reached.

        Args:
            request_id: Unique ID for this generate request.
            prompt: Input prompt (ignored by the mock).
            params: Generation parameters; only max_tokens is inspected.
        """
        # ASSUMPTION: max_tokens=0 or negative means "no limit" and is treated
        # the same as "use all MOCK_TOKENS".  None is also treated as no limit.
        max_tokens = params.get("max_tokens")
        if max_tokens is not None and max_tokens > 0:
            tokens_to_send = MOCK_TOKENS[:max_tokens]
        else:
            tokens_to_send = MOCK_TOKENS

        start = time.monotonic()
        tokens_sent = 0

        for token_text in tokens_to_send:
            # Check cancellation before each token
            if request_id in self.cancelled_requests:
                break

            self.send_token(
                request_id=request_id,
                token_id=tokens_sent + 1,  # 1-based sequence counter
                text=token_text,
                finished=False,
            )
            tokens_sent += 1

            # Yield to the event loop so other coroutines (health, cancel,
            # additional generate requests) can run between tokens.
            await asyncio.sleep(0)

        elapsed_ms = int((time.monotonic() - start) * 1000)
        self.send_done(
            request_id=request_id,
            tokens_generated=tokens_sent,
            time_ms=elapsed_ms,
        )

    async def get_health(self) -> dict:
        """Return zeroed health stats -- mock has no real GPU.

        Returns:
            Dict with status ok and all numeric metrics set to zero
            (except mem_total_gb which is set to a plausible 80.0 GB).
        """
        # ASSUMPTION: mem_total_gb=80.0 and mem_used_gb=0.0 are chosen to
        # represent a typical high-end GPU node without requiring real
        # hardware queries.  The exact values are arbitrary for CI purposes.
        return {
            "status": "ok",
            "gpu_util": 0.0,
            "mem_used_gb": 0.0,
            "mem_total_gb": 80.0,
        }

    async def get_memory(self) -> dict:
        """Return zeroed memory stats -- mock has no real GPU.

        Returns:
            Dict with total_gb=80.0, used_gb=0.0, available_gb=80.0.
        """
        return {
            "total_gb": 80.0,
            "used_gb": 0.0,
            "available_gb": 80.0,
        }

    async def cancel_request(self, request_id: str) -> None:
        """Record request_id in cancelled_requests (fire-and-forget).

        generate() polls this set between tokens and stops early when it
        finds the request_id present.

        Args:
            request_id: The ID of the request to cancel.
        """
        self.cancelled_requests.add(request_id)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """Parse CLI args and run the mock adapter."""
    LoomAdapterMock.main()


if __name__ == "__main__":
    main()
