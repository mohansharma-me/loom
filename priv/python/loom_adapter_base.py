#!/usr/bin/env python3
"""Abstract base class for Loom inference engine adapters.

Owns the protocol I/O layer (line-delimited JSON on stdio), stdin watchdog,
asyncio event loop, startup heartbeat sequence, and command dispatch.
Subclasses implement 5 abstract async methods for engine-specific behavior.

Uses only Python stdlib -- no external dependencies.

Wire protocol (see KNOWLEDGE.md section 4.4):

  Inbound (Erlang -> adapter stdin):
    {"type": "generate", "id": "<req>", "prompt": "...", "params": {...}}
    {"type": "health"}
    {"type": "memory"}
    {"type": "cancel", "id": "<req>"}
    {"type": "shutdown"}

  Outbound (adapter stdout -> Erlang):
    {"type": "heartbeat", "status": "loading", "detail": "..."}
    {"type": "ready", "model": "...", "backend": "..."}
    {"type": "token", "id": "<req>", "token_id": N, "text": "...", "finished": false}
    {"type": "done", "id": "<req>", "tokens_generated": N, "time_ms": N}
    {"type": "health", "status": "ok", "gpu_util": 0.0, "mem_used_gb": 0.0, "mem_total_gb": 0.0}
    {"type": "memory", "total_gb": 0.0, "used_gb": 0.0, "available_gb": 0.0}
    {"type": "error", "id": null, "code": "...", "message": "..."}

Exit codes:
  0 -- clean shutdown (shutdown command)
  1 -- stdin EOF (watchdog detected port closed)
  2 -- load_model() failure (unrecoverable)
"""
import abc
import argparse
import asyncio
import json
import logging
import os
import queue
import sys
import threading
import time
import traceback

logger = logging.getLogger("loom_adapter")

# ASSUMPTION: Heartbeat interval default is 5s to stay well below loom_port's
# default heartbeat_timeout_ms of 15s. Adapters must send heartbeats during
# model loading to prevent loom_port from killing the subprocess.
_DEFAULT_HEARTBEAT_INTERVAL = 5.0

# ASSUMPTION: loom_port default heartbeat_timeout_ms is 15s. If the adapter's
# heartbeat interval >= this threshold, loom_port will kill the subprocess during
# model loading. We warn the user at startup if the configured interval is too high.
_HEARTBEAT_TIMEOUT_WARNING_THRESHOLD = 15.0


class LoomAdapterBase(abc.ABC):
    """Abstract base class for all Loom inference engine adapters.

    Provides:
    - Protocol I/O helpers (send_msg, send_token, send_done, send_error)
    - CLI arg parsing with subclass extensibility
    - Stdin watchdog daemon thread
    - asyncio event loop with run() entry point
    - Startup heartbeat sequence (_startup_sequence)
    - Command dispatch loop (_command_loop, _dispatch_command)

    Subclasses must implement 5 abstract async methods:
      load_model, generate, get_health, get_memory, cancel_request
    """

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        # ASSUMPTION: _line_queue is the sole channel between the stdin watchdog
        # thread and the asyncio command loop. The watchdog is the ONLY reader
        # of sys.stdin -- no other code reads stdin.
        self._line_queue: queue.Queue = queue.Queue()
        # ASSUMPTION: _active_requests tracks in-flight generate request IDs.
        # generate() adds the request_id on entry and removes it in a finally
        # block to guarantee cleanup even on exception or cancellation.
        self._active_requests: set = set()

    # -------------------------------------------------------------------------
    # Abstract methods -- subclasses must implement all five
    # -------------------------------------------------------------------------

    @abc.abstractmethod
    async def load_model(self) -> tuple:
        """Load the inference model and return (model_name, backend_name).

        Called once during startup, after the first heartbeat is sent.
        Heavy imports (vllm, mlx_lm, etc.) should happen inside this method
        so that the first heartbeat reaches loom_port before any slow operations.

        Returns:
            (model_name, backend_name) -- used in the ready message.

        Raises:
            Any exception causes os._exit(2).
        """

    @abc.abstractmethod
    async def generate(self, request_id: str, prompt: str, params: dict) -> None:
        """Stream generated tokens to the client.

        Must call self.send_token() for each token with finished=False,
        then call self.send_done() once after the last token.

        The finished field on token messages is always False -- the done
        message is the authoritative end-of-generation signal.

        The request_id is tracked in self._active_requests; base class manages
        insertion and removal around this call.

        Args:
            request_id: Unique ID from the generate command.
            prompt: Input prompt string.
            params: Generation parameters dict (temperature, max_tokens, etc.).
        """

    @abc.abstractmethod
    async def get_health(self) -> dict:
        """Return current health metrics.

        Returns:
            Dict with keys: status, gpu_util, mem_used_gb, mem_total_gb.
        """

    @abc.abstractmethod
    async def get_memory(self) -> dict:
        """Return current memory usage.

        Returns:
            Dict with keys: total_gb, used_gb, available_gb.
        """

    @abc.abstractmethod
    async def cancel_request(self, request_id: str) -> None:
        """Cancel an in-progress generation request (fire-and-forget).

        Args:
            request_id: The ID of the request to cancel.
        """

    # -------------------------------------------------------------------------
    # CLI argument parsing
    # -------------------------------------------------------------------------

    @classmethod
    def build_arg_parser(cls) -> argparse.ArgumentParser:
        """Build the argument parser with base args.

        Subclasses should override add_args(cls, parser) to add backend-specific
        arguments rather than overriding this method.

        Returns:
            ArgumentParser with base arguments registered.
        """
        parser = argparse.ArgumentParser(
            description="Loom inference engine adapter"
        )
        # Common args used by all adapters
        parser.add_argument(
            "--model",
            type=str,
            default=None,
            help="Model name or path to load (backend-specific format)",
        )
        parser.add_argument(
            "--heartbeat-interval",
            type=float,
            default=_DEFAULT_HEARTBEAT_INTERVAL,
            help=(
                f"Interval in seconds between heartbeats during model loading "
                f"(default: {_DEFAULT_HEARTBEAT_INTERVAL}). "
                f"MUST be less than loom_port heartbeat_timeout_ms (default 15s). "
                f"A value >= {_HEARTBEAT_TIMEOUT_WARNING_THRESHOLD}s will cause a warning."
            ),
        )
        parser.add_argument(
            "--log-level",
            type=str,
            default="INFO",
            choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
            help="Logging level for stderr output (default: INFO)",
        )
        # Allow subclasses to register additional arguments
        cls.add_args(parser)
        return parser

    @classmethod
    def add_args(cls, parser: argparse.ArgumentParser) -> None:
        """Hook for subclasses to add backend-specific CLI arguments.

        Override this classmethod to add arguments without overriding
        build_arg_parser(). The base implementation does nothing.

        Args:
            parser: The ArgumentParser to add arguments to.
        """

    # -------------------------------------------------------------------------
    # Protocol I/O helpers -- only called from the asyncio event loop
    # -------------------------------------------------------------------------

    def send_msg(self, msg: dict) -> None:
        """Serialize msg as JSON and write to stdout with a trailing newline.

        Flushes immediately so loom_port receives the message without buffering.
        All protocol output MUST go through this method -- never write to stdout
        directly from adapter code.

        Args:
            msg: Dict to serialize as JSON. Must be JSON-serializable.
        """
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

    def send_token(
        self,
        request_id: str,
        token_id: int,
        text: str,
        finished: bool = False,
    ) -> None:
        """Send a token message to loom_port.

        Per the streaming contract, finished is always False for token messages.
        The done message is the authoritative end-of-generation signal.

        ASSUMPTION: token_id is a 1-based sequence counter per request, not a
        vocabulary token ID. This is sufficient for Phase 0 and matches the
        mock_adapter.py convention.

        Args:
            request_id: The generate request ID this token belongs to.
            token_id: 1-based sequence counter for this token.
            text: Decoded text for this token increment.
            finished: Always False per streaming contract.
        """
        # ASSUMPTION: finished is included in the message per the wire protocol
        # spec but is always False for token messages. The done message signals
        # end-of-generation. This matches mock_adapter.py behavior.
        self.send_msg({
            "type": "token",
            "id": request_id,
            "token_id": token_id,
            "text": text,
            "finished": finished,
        })

    def send_done(
        self,
        request_id: str,
        tokens_generated: int,
        time_ms: int,
    ) -> None:
        """Send a done message signaling end-of-generation for a request.

        Must be called exactly once per generate request, after all send_token
        calls. This is the authoritative end signal -- loom_port will not
        expect any further messages for this request_id.

        Args:
            request_id: The generate request ID that completed.
            tokens_generated: Total number of tokens generated.
            time_ms: Total generation time in milliseconds.
        """
        self.send_msg({
            "type": "done",
            "id": request_id,
            "tokens_generated": tokens_generated,
            "time_ms": time_ms,
        })

    def send_error(
        self,
        request_id,
        code: str,
        message: str,
    ) -> None:
        """Send an error message to loom_port.

        When request_id is None, the id field serializes as JSON null (not the
        string "None"). loom_protocol.erl decodes JSON null as Erlang undefined.

        Args:
            request_id: The request ID associated with this error, or None for
                        protocol-level errors not tied to a specific request.
            code: Short machine-readable error code (e.g. "invalid_json").
            message: Human-readable error description.
        """
        # ASSUMPTION: When request_id is None, json.dumps serializes it as null,
        # which loom_protocol.erl decodes as the Erlang atom undefined. This is
        # correct behavior. Never convert None to the string "None".
        self.send_msg({
            "type": "error",
            "id": request_id,
            "code": code,
            "message": message,
        })

    # -------------------------------------------------------------------------
    # Stdin watchdog -- daemon thread, sole reader of sys.stdin
    # -------------------------------------------------------------------------

    def _stdin_watchdog(self) -> None:
        """Daemon thread: read stdin lines, detect EOF, force-exit on close.

        This is the sole reader of sys.stdin. Lines are placed into
        self._line_queue for the asyncio command loop to process.

        On EOF (empty bytes from readline), calls os._exit(1) to force-terminate
        the entire process immediately, bypassing Python cleanup. This is the
        cross-platform mechanism triggered by loom_port's shutdown escalation:
        closing the Erlang port causes stdin EOF on the Python side.

        ASSUMPTION: os._exit(1) is used (not sys.exit) to bypass atexit
        handlers and thread cleanup, which can SIGABRT when daemon threads
        are blocked on I/O.
        ASSUMPTION: This thread is the ONLY reader of sys.stdin. No other code
        reads stdin -- doing so would race with this thread.
        """
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                # EOF -- stdin was closed; force-terminate immediately
                logger.info("stdin closed (watchdog), force-exiting with code 1")
                os._exit(1)
            self._line_queue.put(line)

    # -------------------------------------------------------------------------
    # Entry point
    # -------------------------------------------------------------------------

    def run(self) -> None:
        """Configure and start the adapter event loop.

        This is the main entry point. It:
        1. Configures logging to stderr at the requested level
        2. Reconfigures stdout for line-buffered output
        3. Validates the heartbeat interval
        4. Starts the stdin watchdog daemon thread
        5. Runs the asyncio event loop with _async_main()

        This method does not return under normal operation. It exits via:
          os._exit(0) -- shutdown command
          os._exit(1) -- stdin EOF (watchdog)
          os._exit(2) -- load_model() failure
        """
        # Configure logging to stderr -- stdout is the protocol channel
        logging.basicConfig(
            stream=sys.stderr,
            level=getattr(logging, self.args.log_level, logging.INFO),
            format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
        )

        # ASSUMPTION: sys.stdout.reconfigure(line_buffering=True) is defense-in-depth.
        # All protocol output goes through send_msg() which flushes explicitly, but
        # this prevents interleaved/delayed output if a subclass accidentally writes
        # to stdout outside the helper methods.
        try:
            sys.stdout.reconfigure(line_buffering=True)
        except AttributeError:
            # Python < 3.7 fallback -- reconfigure not available
            pass

        # ASSUMPTION: Warn if heartbeat interval >= loom_port timeout threshold.
        # loom_port's default heartbeat_timeout_ms is 15000ms (15s). If the adapter
        # interval is >= 15s, loom_port may kill the subprocess during model loading
        # before receiving the next heartbeat.
        interval = self.args.heartbeat_interval
        if interval >= _HEARTBEAT_TIMEOUT_WARNING_THRESHOLD:
            logger.warning(
                "heartbeat-interval %.1fs is >= loom_port heartbeat_timeout_ms "
                "default (%.1fs). loom_port may kill the subprocess during model "
                "loading before the next heartbeat arrives. Consider using a "
                "lower value (default: %.1fs).",
                interval,
                _HEARTBEAT_TIMEOUT_WARNING_THRESHOLD,
                _DEFAULT_HEARTBEAT_INTERVAL,
            )

        logger.info("adapter starting, model=%s", self.args.model)

        # Start stdin watchdog daemon thread before the event loop.
        # The watchdog is the sole stdin reader; it forwards lines to
        # self._line_queue and calls os._exit(1) on EOF.
        watchdog = threading.Thread(
            target=self._stdin_watchdog,
            daemon=True,
            name="stdin-watchdog",
        )
        watchdog.start()
        logger.debug("stdin watchdog thread started")

        # Run the asyncio event loop
        asyncio.run(self._async_main())

    # -------------------------------------------------------------------------
    # Async main and startup sequence
    # -------------------------------------------------------------------------

    async def _async_main(self) -> None:
        """Top-level async coroutine: startup sequence then command loop.

        If load_model() raises any exception, logs the traceback to stderr and
        calls os._exit(2). This prevents the adapter from entering the command
        loop in a broken state.
        """
        try:
            await self._startup_sequence()
        except Exception:
            logger.critical(
                "load_model() failed -- unrecoverable, exiting with code 2",
                exc_info=True,
            )
            sys.stderr.flush()
            os._exit(2)

        await self._command_loop()

    async def _startup_sequence(self) -> None:
        """Send initial heartbeat, load model with periodic heartbeats, send ready.

        Sequence:
        1. Send heartbeat with status=loading BEFORE calling load_model().
           This is critical: the first heartbeat must reach loom_port before
           any heavy imports (vllm, mlx_lm) slow down the process. Heavy
           imports happen inside load_model(), which is called AFTER this
           first heartbeat is sent.
        2. Start load_model() as an asyncio task.
        3. While load_model() is running, send periodic heartbeats at the
           configured interval so loom_port's heartbeat_timeout_ms doesn't fire.
        4. When load_model() completes, send the ready message with the
           (model_name, backend_name) it returned.

        Raises:
            Any exception from load_model() propagates to _async_main() which
            handles it as a fatal error (os._exit(2)).
        """
        interval = self.args.heartbeat_interval

        # ASSUMPTION: The first heartbeat is always sent before load_model() to
        # ensure loom_port transitions from spawning to loading state before the
        # spawn_timeout_ms (default 5s) fires. Do not defer this.
        logger.debug("sending initial heartbeat (status=loading)")
        self.send_msg({
            "type": "heartbeat",
            "status": "loading",
            "detail": "starting model load",
        })

        # Run load_model() concurrently with the heartbeat loop.
        load_task = asyncio.create_task(self.load_model())

        # Send periodic heartbeats while load_model() runs.
        while not load_task.done():
            try:
                await asyncio.wait_for(
                    asyncio.shield(load_task),
                    timeout=interval,
                )
                # load_task completed before the timeout
            except asyncio.TimeoutError:
                # Interval elapsed, model still loading -- send another heartbeat
                if not load_task.done():
                    logger.debug("sending heartbeat (status=loading, model still loading)")
                    self.send_msg({
                        "type": "heartbeat",
                        "status": "loading",
                        "detail": "model loading in progress",
                    })
            except Exception:
                # load_task raised -- let it propagate after await
                break

        # Await the task to surface any exception (or get the return value).
        # If load_task raised, this re-raises the exception.
        model_name, backend_name = await load_task

        logger.info(
            "model loaded successfully: model=%s backend=%s",
            model_name,
            backend_name,
        )
        self.send_msg({
            "type": "ready",
            "model": model_name,
            "backend": backend_name,
        })

    # -------------------------------------------------------------------------
    # Command loop
    # -------------------------------------------------------------------------

    async def _command_loop(self) -> None:
        """Read commands from the queue and dispatch until shutdown or error.

        Uses loop.run_in_executor to read from the blocking queue without
        blocking the asyncio event loop. Each line is decoded, parsed as JSON,
        and passed to _dispatch_command().

        Blank lines are silently ignored. JSON parse errors and unknown message
        types produce error responses but do not terminate the loop.
        """
        loop = asyncio.get_event_loop()
        logger.info("entering command loop")

        while True:
            # ASSUMPTION: queue.Queue.get() is a blocking call. We run it in the
            # default thread pool executor so the asyncio event loop remains free
            # to process other coroutines (e.g., concurrent generate requests).
            raw_line = await loop.run_in_executor(
                None, self._line_queue.get
            )

            # Decode bytes to str, stripping trailing newline/whitespace
            try:
                line = raw_line.decode(errors="replace").strip()
            except Exception as exc:
                logger.error("failed to decode line from queue: %s", exc)
                continue

            if not line:
                # Blank line -- silently ignore per spec
                continue

            # Parse JSON
            try:
                msg = json.loads(line)
            except json.JSONDecodeError as exc:
                logger.warning("invalid JSON received: %s", exc)
                self.send_error(None, "invalid_json", f"invalid JSON: {exc}")
                continue

            # Dispatch the command
            await self._dispatch_command(msg)

    async def _dispatch_command(self, msg: dict) -> None:
        """Route a parsed command message to the appropriate handler.

        Handles: generate, health, memory, cancel, shutdown, and unknown types.
        All handler invocations are wrapped in try/except so a single-request
        failure sends an error response without crashing the adapter.

        The shutdown command calls os._exit(0) directly.

        Args:
            msg: Parsed JSON command dict. Must contain a "type" field.
        """
        msg_type = msg.get("type")

        if msg_type is None:
            self.send_error(None, "missing_type", "message missing 'type' field")
            return

        if msg_type == "shutdown":
            logger.info("shutdown command received, exiting with code 0")
            sys.stdout.flush()
            sys.stderr.flush()
            # ASSUMPTION: os._exit(0) bypasses Python atexit/thread cleanup,
            # which can SIGABRT when daemon threads are blocked on I/O.
            os._exit(0)

        elif msg_type == "generate":
            request_id = msg.get("id")
            if request_id is None:
                self.send_error(
                    None,
                    "missing_field",
                    "generate request missing 'id' field",
                )
                return
            prompt = msg.get("prompt", "")
            params = msg.get("params", {})
            # ASSUMPTION: generate() tracks request_id in _active_requests.
            # The base class manages insertion before calling generate() and
            # removal in a finally block to guarantee cleanup.
            self._active_requests.add(request_id)
            try:
                await self.generate(request_id, prompt, params)
            except Exception as exc:
                logger.error(
                    "generate failed for request_id=%s: %s: %s",
                    request_id,
                    type(exc).__name__,
                    exc,
                    exc_info=True,
                )
                self.send_error(
                    request_id,
                    "internal_error",
                    f"{type(exc).__name__}: {exc}",
                )
            finally:
                self._active_requests.discard(request_id)

        elif msg_type == "health":
            try:
                health = await self.get_health()
                self.send_msg({"type": "health", **health})
            except Exception as exc:
                logger.error("get_health failed: %s", exc, exc_info=True)
                self.send_error(None, "internal_error", f"{type(exc).__name__}: {exc}")

        elif msg_type == "memory":
            try:
                mem = await self.get_memory()
                self.send_msg({"type": "memory", **mem})
            except Exception as exc:
                logger.error("get_memory failed: %s", exc, exc_info=True)
                self.send_error(None, "internal_error", f"{type(exc).__name__}: {exc}")

        elif msg_type == "cancel":
            request_id = msg.get("id")
            if request_id is None:
                # ASSUMPTION: cancel without id is a no-op with no response,
                # consistent with fire-and-forget cancel semantics.
                logger.warning("cancel command missing 'id' field, ignoring")
                return
            try:
                await self.cancel_request(request_id)
            except Exception as exc:
                # ASSUMPTION: If cancel_request() raises, send an error response
                # as a safety net. Cancel is fire-and-forget from the caller's
                # perspective but we don't silently swallow unexpected errors.
                logger.error(
                    "cancel_request failed for request_id=%s: %s",
                    request_id,
                    exc,
                    exc_info=True,
                )
                self.send_error(
                    request_id,
                    "internal_error",
                    f"{type(exc).__name__}: {exc}",
                )

        else:
            logger.warning("unknown message type: %s", msg_type)
            self.send_error(
                msg.get("id"),
                "unknown_type",
                f"unknown message type: {msg_type}",
            )

    # -------------------------------------------------------------------------
    # Convenience class method for subclass entry points
    # -------------------------------------------------------------------------

    @classmethod
    def main(cls) -> None:
        """Parse CLI args, instantiate the adapter, and call run().

        Subclasses should use this as their __main__ entry point:

            if __name__ == "__main__":
                MyAdapter.main()

        This handles arg parsing via build_arg_parser() (which calls add_args()
        for subclass-specific arguments) and constructs the adapter instance.
        """
        parser = cls.build_arg_parser()
        args = parser.parse_args()
        adapter = cls(args)
        adapter.run()
