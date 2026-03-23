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

        # ASSUMPTION: cancelled_requests is a plain set (not thread-safe)
        # because it is accessed only from the asyncio event loop (single
        # thread).  cancel_request() adds an ID here; generate() checks it
        # between token yields.
        self.cancelled_requests: set = set()

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
        # ASSUMPTION: mlx_lm imports are deferred to keep the module-level
        # import graph clean.  mlx.core is needed to build the input_ids
        # array and to call .item() on the output token tensor.
        import mlx.core as mx  # noqa: PLC0415
        from mlx_lm.utils import generate_step  # noqa: PLC0415

        max_tokens = params.get("max_tokens", self.args.max_tokens)
        loop = asyncio.get_event_loop()

        # Tokenize prompt synchronously (fast, no Metal ops).
        # ASSUMPTION: tokenizer.encode() returns a Python list of int token IDs.
        # We wrap it in mx.array for mlx_lm compatibility.
        input_ids = mx.array(self.tokenizer.encode(prompt))

        # Build the synchronous generator.  generate_step yields
        # (token_tensor, logprobs) tuples; logprobs are not used here.
        # ASSUMPTION: generate_step accepts (prompt_tokens, model) as positional
        # args per the mlx-lm 0.20.x public API.
        gen = generate_step(input_ids, self.model)

        start = time.monotonic()
        tokens_sent = 0

        for _ in range(max_tokens):
            # Check cancellation before each token.
            if request_id in self.cancelled_requests:
                logger.info("request %s cancelled, stopping generation", request_id)
                break

            # Advance the generator by one step in a thread executor so we
            # don't block the event loop during the Metal forward pass.
            # ASSUMPTION: StopIteration from the generator is caught here and
            # treated as end-of-generation (generator exhausted early).
            try:
                result = await loop.run_in_executor(None, next, gen, None)
            except StopIteration:
                break

            if result is None:
                # Generator exhausted (next() returned sentinel).
                break

            token_tensor, _logprobs = result

            # ASSUMPTION: .item() converts the mlx scalar tensor to a Python int.
            # We store it in a local variable to avoid calling .item() twice.
            token_int = token_tensor.item()

            # Check for EOS token.
            # ASSUMPTION: tokenizer.eos_token_id may be None for models that do
            # not define an EOS token; we only break on it when it is set.
            if (
                self.tokenizer.eos_token_id is not None
                and token_int == self.tokenizer.eos_token_id
            ):
                break

            # Decode single token to text.
            # ASSUMPTION: tokenizer.decode([token_int]) produces the text fragment
            # for one token.  skip_special_tokens=True avoids emitting BOS/EOS
            # markers as text in the output stream.
            token_text = self.tokenizer.decode(
                [token_int], skip_special_tokens=True
            )

            tokens_sent += 1
            self.send_token(
                request_id=request_id,
                token_id=tokens_sent,  # 1-based sequence counter
                text=token_text,
                finished=False,
            )

            # Yield control to the event loop so health/cancel/other commands
            # can be serviced between tokens.
            await asyncio.sleep(0)

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

    async def get_memory(self) -> dict:
        """Return memory stats using psutil for unified memory on Apple Silicon.

        Returns:
            Dict with keys: total_gb, used_gb, available_gb.
        """
        # ASSUMPTION: psutil.virtual_memory() reports unified system RAM on
        # Apple Silicon.  available is the OS-reported immediately usable RAM
        # (includes reclaimable cache), which is the right value for "how much
        # memory can we use for another model?".
        import psutil  # noqa: PLC0415
        vm = psutil.virtual_memory()
        return {
            "total_gb": vm.total / (1024 ** 3),
            "used_gb": vm.used / (1024 ** 3),
            "available_gb": vm.available / (1024 ** 3),
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
