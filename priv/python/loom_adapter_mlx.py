#!/usr/bin/env python3
"""MLX inference engine adapter for Loom.

Wraps mlx-lm for Apple Silicon (M-series) inference.  Subclasses
LoomAdapterBase and implements all five abstract methods using the
mlx_lm.load / mlx_lm.utils.generate_step API.

Requirements: mlx-lm>=0.20.0, psutil
  (see priv/python/requirements-mlx.txt)

Wire protocol is handled entirely by LoomAdapterBase.  This file only
contains MLX-specific logic.

IMPORTANT NOTE on MLX concurrency:
  MLX runs a single request at a time -- there is no continuous batching
  support in mlx-lm (unlike vLLM).  Concurrent generate requests will be
  serialised by the asyncio event loop's single-thread execution.  This is
  an mlx-lm limitation, not a Loom limitation.  Future work (P1+) can add
  a request queue with backpressure if needed.
"""

import asyncio
import logging
import os
import sys
import time

# ASSUMPTION: The base module lives in the same directory as this file.
# Using sys.path.insert keeps the import self-contained without requiring
# an installed package or PYTHONPATH configuration.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from loom_adapter_base import LoomAdapterBase  # noqa: E402

logger = logging.getLogger("loom_adapter")


class MlxAdapter(LoomAdapterBase):
    """Loom adapter backed by mlx-lm on Apple Silicon.

    Targets mlx-lm>=0.20.0.  Heavy imports (mlx_lm, mlx.core) are
    deferred to load_model() so the first heartbeat reaches loom_port
    before any slow initialisation begins.

    MLX runs single-request at a time (no continuous batching).
    See module docstring for details.
    """

    def __init__(self, args):
        super().__init__(args)
        # ASSUMPTION: self.model and self.tokenizer are None until load_model()
        # succeeds.  generate() guards against None before use.
        self.model = None
        self.tokenizer = None

        # ASSUMPTION: cancelled_requests is inherited from LoomAdapterBase
        # and cleaned up centrally in _dispatch_command's finally block.

    # -------------------------------------------------------------------------
    # CLI args
    # -------------------------------------------------------------------------

    @classmethod
    def add_args(cls, parser) -> None:
        """Add MLX-specific CLI flags to the shared argument parser."""
        parser.add_argument(
            "--max-tokens",
            type=int,
            default=256,
            help=(
                "Maximum number of tokens to generate per request "
                "(default: 256)."
            ),
        )
        parser.add_argument(
            "--dtype",
            type=str,
            default="float16",
            help=(
                "Hint for model weight dtype (default: float16). "
                "NOTE: mlx_lm.load() determines dtype from the model config "
                "rather than this CLI argument.  This flag is accepted for "
                "interface symmetry with the vLLM adapter but has no effect "
                "on the loaded model precision."
            ),
        )

    # -------------------------------------------------------------------------
    # Abstract method implementations
    # -------------------------------------------------------------------------

    async def load_model(self) -> tuple:
        """Load the mlx-lm model and tokenizer in a thread executor.

        Imports are deferred to this method so the first heartbeat reaches
        loom_port before any heavy initialisation begins.

        mlx_lm.load() is a synchronous call that may download weights from
        the Hub on first use, so it is wrapped in run_in_executor to avoid
        blocking the asyncio event loop (and therefore the heartbeat loop in
        _startup_sequence).

        NOTE: mlx_lm.load() determines dtype from the model config, not from
        the --dtype CLI argument.  The --dtype flag is accepted for interface
        symmetry with the vLLM adapter but is intentionally not passed to
        mlx_lm.load().

        Returns:
            (model_name, "mlx")

        Raises:
            Any exception (e.g. model not found, out of memory) causes
            os._exit(2) in _async_main().
        """
        # ASSUMPTION: mlx_lm imports are deferred here so the first heartbeat
        # is sent before slow model download / Metal shader compilation starts.
        loop = asyncio.get_event_loop()

        def _load_sync():
            from mlx_lm import load  # noqa: PLC0415
            return load(self.args.model)

        logger.info("loading mlx-lm model: %s", self.args.model)
        self.model, self.tokenizer = await loop.run_in_executor(None, _load_sync)
        logger.info("mlx-lm model loaded: %s", self.args.model)

        return (self.args.model, "mlx")

    async def generate(self, request_id: str, prompt: str, params: dict) -> None:
        """Stream generated tokens to the client using mlx_lm.utils.generate_step.

        mlx_lm.utils.generate_step is a synchronous generator.  Each call to
        next() on it produces one (token_id_tensor, logprobs) tuple and
        performs one forward pass on the Metal GPU.  We wrap each next() call
        in run_in_executor so the asyncio event loop remains responsive to
        health/cancel commands between tokens.

        Checks cancelled_requests between tokens; if the request was cancelled,
        breaks early and sends send_done() for tokens already generated.

        Args:
            request_id: Unique ID for this generate request.
            prompt: Input prompt string.
            params: Generation parameters dict.  Recognised keys:
                max_tokens (int).
        """
        # ASSUMPTION: mlx_lm >= 0.29.0 provides stream_generate as the
        # public API for token-by-token generation.  The older generate_step
        # was removed in 0.29.x.
        from mlx_lm import stream_generate  # noqa: PLC0415

        max_tokens = params.get("max_tokens", self.args.max_tokens)
        loop = asyncio.get_event_loop()

        start = time.monotonic()
        tokens_sent = 0

        # ASSUMPTION: stream_generate is a synchronous generator that yields
        # GenerationResponse objects with .text attribute (cumulative or delta
        # depending on version).  We use it in a thread executor to avoid
        # blocking the event loop during Metal forward passes.
        gen = stream_generate(
            model=self.model,
            tokenizer=self.tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
        )

        # Unique sentinel for generator exhaustion.
        _EXHAUSTED = object()

        try:
            for _ in range(max_tokens):
                # Check cancellation before each token.
                if request_id in self.cancelled_requests:
                    logger.info("request %s cancelled, stopping generation",
                                request_id)
                    break

                # Advance the generator by one step in a thread executor so we
                # don't block the event loop during the Metal forward pass.
                result = await loop.run_in_executor(
                    None, next, gen, _EXHAUSTED
                )

                if result is _EXHAUSTED:
                    break

                # ASSUMPTION: GenerationResponse has a .text attribute containing
                # the token text fragment for this step.
                token_text = result.text

                if not token_text:
                    continue

                tokens_sent += 1
                self.send_token(
                    request_id=request_id,
                    token_id=tokens_sent,
                    text=token_text,
                )

                # Yield control to the event loop so health/cancel/other
                # commands can be serviced between tokens.
                await asyncio.sleep(0)
        finally:
            elapsed_ms = int((time.monotonic() - start) * 1000)
            self.send_done(
                request_id=request_id,
                tokens_generated=tokens_sent,
                time_ms=elapsed_ms,
            )

    async def get_health(self) -> dict:
        """Return health metrics using psutil for unified memory on Apple Silicon.

        Apple Silicon uses unified memory shared between CPU and GPU.  There
        is no Metal public API for per-process GPU VRAM utilisation, so
        gpu_util is always reported as 0.0 (not measurable without private
        frameworks).  System RAM is used as a proxy for available memory.

        Returns:
            Dict with keys: status, gpu_util, mem_used_gb, mem_total_gb.
        """
        # ASSUMPTION: psutil.virtual_memory() reports unified system RAM on
        # Apple Silicon, which is the correct proxy for model memory since
        # MLX allocates from unified memory.
        try:
            import psutil  # noqa: PLC0415
            vm = psutil.virtual_memory()
            return {
                "status": "ok",
                # ASSUMPTION: gpu_util is always 0.0 because Apple Silicon has no
                # public Metal API for GPU utilisation percentage.  This is a known
                # limitation of the MLX adapter -- not a Loom bug.
                "gpu_util": 0.0,
                "mem_used_gb": vm.used / (1024 ** 3),
                "mem_total_gb": vm.total / (1024 ** 3),
            }
        except Exception as exc:
            logger.warning("psutil health query failed: %s", exc)
            return {
                "status": "degraded",
                "gpu_util": 0.0,
                "mem_used_gb": 0.0,
                "mem_total_gb": 0.0,
            }

    async def get_memory(self) -> dict:
        """Return memory stats using psutil for unified memory on Apple Silicon.

        Returns:
            Dict with keys: total_gb, used_gb, available_gb.
        """
        # ASSUMPTION: psutil.virtual_memory() reports unified system RAM on
        # Apple Silicon.  available is the OS-reported immediately usable RAM
        # (includes reclaimable cache), which is the right value for "how much
        # memory can we use for another model?".
        try:
            import psutil  # noqa: PLC0415
            vm = psutil.virtual_memory()
            return {
                "total_gb": vm.total / (1024 ** 3),
                "used_gb": vm.used / (1024 ** 3),
                "available_gb": vm.available / (1024 ** 3),
            }
        except Exception as exc:
            logger.warning("psutil memory query failed: %s", exc)
            return {
                "total_gb": 0.0,
                "used_gb": 0.0,
                "available_gb": 0.0,
            }

    async def cancel_request(self, request_id: str) -> None:
        """Record request_id in cancelled_requests (fire-and-forget).

        generate() polls this set between token steps and stops early when
        it finds the request_id present.

        NOTE: MLX has no mid-generation abort API (unlike vLLM's engine.abort).
        Cancellation takes effect only at the next token boundary -- the
        current Metal forward pass completes before the cancellation is seen.

        Args:
            request_id: The ID of the request to cancel.
        """
        # ASSUMPTION: Adding to a set is thread-safe in CPython (GIL-protected)
        # but cancelled_requests is only accessed from the asyncio event loop
        # so thread safety is not actually needed here.
        self.cancelled_requests.add(request_id)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """Parse CLI args and run the MLX adapter."""
    MlxAdapter.main()


if __name__ == "__main__":
    main()
