#!/usr/bin/env python3
"""vLLM inference engine adapter for Loom.

Wraps vLLM's AsyncLLMEngine to provide the Loom line-delimited JSON
wire protocol.  Subclasses LoomAdapterBase and implements all five
abstract methods using vLLM's native async API.

Requirements: vllm>=0.6.0,<0.7.0  (see priv/python/requirements-vllm.txt)
pynvml is installed transitively with vllm and used for GPU metrics.

Wire protocol is handled entirely by LoomAdapterBase.  This file only
contains vLLM-specific logic.
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


class VllmAdapter(LoomAdapterBase):
    """Loom adapter backed by vLLM AsyncLLMEngine.

    Targets vLLM 0.6.x.  Heavy imports (vllm, pynvml) are deferred to
    load_model() so the first heartbeat reaches loom_port before any
    slow initialization begins.
    """

    def __init__(self, args):
        super().__init__(args)
        # ASSUMPTION: self.engine is None until load_model() succeeds.
        # generate() and cancel_request() guard against None before use.
        self.engine = None

        # ASSUMPTION: self._nvml_handle is initialized once in load_model()
        # and reused by get_health() / get_memory() to avoid repeated
        # nvmlDeviceGetHandleByIndex calls.  None means NVML is unavailable
        # (no CUDA, pynvml missing) and callers fall back to zeroed stats.
        self._nvml_handle = None

        # ASSUMPTION: cancelled_requests is inherited from LoomAdapterBase
        # and cleaned up centrally in _dispatch_command's finally block.

    # -------------------------------------------------------------------------
    # CLI args
    # -------------------------------------------------------------------------

    @classmethod
    def add_args(cls, parser) -> None:
        """Add vLLM-specific CLI flags to the shared argument parser."""
        parser.add_argument(
            "--tensor-parallel-size",
            type=int,
            default=1,
            help=(
                "Number of tensor-parallel GPUs for distributed inference "
                "(default: 1)."
            ),
        )
        parser.add_argument(
            "--dtype",
            type=str,
            default="auto",
            help=(
                "Model weight dtype passed to AsyncEngineArgs "
                "(default: auto)."
            ),
        )
        parser.add_argument(
            "--gpu-memory-utilization",
            type=float,
            default=0.9,
            help=(
                "Fraction of total GPU memory vLLM is allowed to use "
                "(for model weights, KV cache, and overheads) (default: 0.9)."
            ),
        )
        parser.add_argument(
            "--max-model-len",
            type=int,
            default=None,
            help=(
                "Override the maximum sequence length supported by the model "
                "(default: None, use model config)."
            ),
        )

    # -------------------------------------------------------------------------
    # Abstract method implementations
    # -------------------------------------------------------------------------

    async def load_model(self) -> tuple:
        """Load the vLLM AsyncLLMEngine and initialize pynvml.

        Imports are deferred to this method so the first heartbeat reaches
        loom_port before any heavy initialization begins.

        Returns:
            (model_name, "vllm")

        Raises:
            Any exception (e.g. CUDA OOM, model not found) causes os._exit(2).
        """
        # ASSUMPTION: vLLM imports are deferred here so the first heartbeat
        # is sent before slow CUDA/model initialization starts.
        from vllm import AsyncEngineArgs, AsyncLLMEngine  # noqa: PLC0415

        engine_args = AsyncEngineArgs(
            model=self.args.model,
            tensor_parallel_size=self.args.tensor_parallel_size,
            dtype=self.args.dtype,
            gpu_memory_utilization=self.args.gpu_memory_utilization,
            max_model_len=self.args.max_model_len,
        )
        logger.info(
            "initializing AsyncLLMEngine: model=%s tensor_parallel_size=%d "
            "dtype=%s gpu_memory_utilization=%.2f",
            self.args.model,
            self.args.tensor_parallel_size,
            self.args.dtype,
            self.args.gpu_memory_utilization,
        )
        self.engine = AsyncLLMEngine.from_engine_args(engine_args)
        logger.info("AsyncLLMEngine initialized")

        # Initialize pynvml once at startup and cache the device handle.
        # ASSUMPTION: We initialize pynvml here (after vLLM init) because
        # vLLM may also call nvmlInit internally; initializing afterward is
        # safe since nvmlInit is idempotent for the process.
        # ASSUMPTION: GPU index 0 is used for all health/memory metrics.
        # For tensor_parallel_size > 1, reporting GPU 0 only is a known
        # limitation; multi-GPU aggregation is out of scope for P0-06 and
        # will be addressed in P0-07 (loom_gpu_monitor).
        try:
            import pynvml  # noqa: PLC0415
            pynvml.nvmlInit()
            self._nvml_handle = pynvml.nvmlDeviceGetHandleByIndex(0)
            logger.info("pynvml initialized, monitoring GPU 0")
        except Exception as exc:  # pylint: disable=broad-except
            logger.warning(
                "pynvml initialization failed -- health/memory will return "
                "zeroed stats: %s",
                exc,
            )
            self._nvml_handle = None

        return (self.args.model, "vllm")

    async def generate(self, request_id: str, prompt: str, params: dict) -> None:
        """Stream generated tokens to the client using vLLM's async generator.

        Imports SamplingParams lazily.  Iterates the async generator returned
        by engine.generate(), diffs successive cumulative text outputs to
        extract incremental token text, and sends each increment via
        send_token().  Sends send_done() once after the last token.

        Checks cancelled_requests between yields; if the request was
        cancelled, breaks early and still sends send_done() for the tokens
        already generated.

        Args:
            request_id: Unique ID for this generate request.
            prompt: Input prompt string.
            params: Generation parameters dict.  Recognised keys:
                max_tokens (int), temperature (float), top_p (float),
                top_k (int), presence_penalty (float), frequency_penalty (float).
        """
        # ASSUMPTION: SamplingParams is imported lazily here so load_model()
        # is the only place vllm must be imported at the top-level, keeping
        # the import graph predictable.
        from vllm import SamplingParams  # noqa: PLC0415

        sampling_params = SamplingParams(
            max_tokens=params.get("max_tokens", 256),
            temperature=params.get("temperature", 1.0),
            top_p=params.get("top_p", 1.0),
            top_k=params.get("top_k", -1),
            presence_penalty=params.get("presence_penalty", 0.0),
            frequency_penalty=params.get("frequency_penalty", 0.0),
        )

        if self.engine is None:
            self.send_error(request_id, "engine_not_ready",
                            "engine not yet initialized")
            return

        start = time.monotonic()
        tokens_sent = 0
        prev_text = ""

        # ASSUMPTION: engine.generate() returns an async generator of
        # RequestOutput objects.  Each RequestOutput has outputs[0].text
        # containing the CUMULATIVE decoded text so far.  We diff consecutive
        # values to produce incremental token text for the wire protocol.
        #
        # ASSUMPTION: tokens_sent counts the number of non-empty incremental
        # text diffs, which may differ from the actual model-level token count
        # when vLLM batches multiple tokens in a single RequestOutput. For P0
        # this is acceptable; P1+ can use request_output.outputs[0].token_ids
        # for accurate token counting.
        try:
            async for request_output in self.engine.generate(
                prompt, sampling_params, request_id
            ):
                # Cooperative cancellation: check before processing each output.
                if request_id in self.cancelled_requests:
                    logger.info("request %s cancelled, stopping generation",
                                request_id)
                    break

                if not request_output.outputs:
                    continue

                current_text = request_output.outputs[0].text
                # Compute the new text since the last output (incremental diff).
                incremental = current_text[len(prev_text):]
                prev_text = current_text

                if incremental:
                    tokens_sent += 1
                    self.send_token(
                        request_id=request_id,
                        token_id=tokens_sent,
                        text=incremental,
                    )
        finally:
            elapsed_ms = int((time.monotonic() - start) * 1000)
            self.send_done(
                request_id=request_id,
                tokens_generated=tokens_sent,
                time_ms=elapsed_ms,
            )

    async def get_health(self) -> dict:
        """Return GPU health metrics using cached pynvml handle.

        Uses self._nvml_handle (cached in load_model()).  Falls back to
        zeroed stats if NVML is unavailable.

        Returns:
            Dict with keys: status, gpu_util, mem_used_gb, mem_total_gb.
        """
        if self._nvml_handle is not None:
            try:
                import pynvml  # noqa: PLC0415
                util = pynvml.nvmlDeviceGetUtilizationRates(self._nvml_handle)
                mem = pynvml.nvmlDeviceGetMemoryInfo(self._nvml_handle)
                return {
                    "status": "ok",
                    "gpu_util": float(util.gpu) / 100.0,
                    "mem_used_gb": mem.used / (1024 ** 3),
                    "mem_total_gb": mem.total / (1024 ** 3),
                }
            except Exception as exc:  # pylint: disable=broad-except
                logger.warning("pynvml health query failed: %s", exc)
                return {
                    "status": "degraded",
                    "gpu_util": 0.0,
                    "mem_used_gb": 0.0,
                    "mem_total_gb": 0.0,
                }

        # ASSUMPTION: Zeroed stats with status "ok" returned when NVML was
        # never available (no CUDA). "degraded" is used when NVML was available
        # but a runtime query failed.
        return {
            "status": "ok",
            "gpu_util": 0.0,
            "mem_used_gb": 0.0,
            "mem_total_gb": 0.0,
        }

    async def get_memory(self) -> dict:
        """Return GPU memory stats using cached pynvml handle.

        Uses self._nvml_handle (cached in load_model()).  Falls back to
        zeroed stats if NVML is unavailable.

        Returns:
            Dict with keys: total_gb, used_gb, available_gb.
        """
        if self._nvml_handle is not None:
            try:
                import pynvml  # noqa: PLC0415
                mem = pynvml.nvmlDeviceGetMemoryInfo(self._nvml_handle)
                return {
                    "total_gb": mem.total / (1024 ** 3),
                    "used_gb": mem.used / (1024 ** 3),
                    "available_gb": mem.free / (1024 ** 3),
                }
            except Exception as exc:  # pylint: disable=broad-except
                logger.warning("pynvml memory query failed: %s", exc)

        return {
            "total_gb": 0.0,
            "used_gb": 0.0,
            "available_gb": 0.0,
        }

    async def cancel_request(self, request_id: str) -> None:
        """Cancel an in-progress generation request.

        Adds request_id to cancelled_requests (checked cooperatively by
        generate()) and calls engine.abort() if the engine is running and
        the request is still active.

        Args:
            request_id: The ID of the request to cancel.
        """
        self.cancelled_requests.add(request_id)

        if self.engine is not None and request_id in self._active_requests:
            try:
                await self.engine.abort(request_id)
                logger.debug("engine.abort() called for request_id=%s", request_id)
            except Exception as exc:  # pylint: disable=broad-except
                # ASSUMPTION: abort() failures are logged but not re-raised
                # because cancel is fire-and-forget from the caller's perspective.
                logger.warning(
                    "engine.abort() failed for request_id=%s: %s",
                    request_id,
                    exc,
                )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """Parse CLI args and run the vLLM adapter."""
    VllmAdapter.main()


if __name__ == "__main__":
    main()
