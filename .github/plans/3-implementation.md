# P0-03 Implementation Plan: Dev Environment with Docker Compose

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a containerized dev environment with Docker Compose, a mock Python adapter for GPU-free development, and env-var-driven configuration.

**Architecture:** Multi-stage Alpine Docker build (builder + runtime). Mock Python adapter speaks line-delimited JSON on stdin/stdout. rebar3 `.src` config templates for env var substitution in prod releases. Two docker-compose services: `dev` (runtime) and `test` (builder with full toolchain).

**Tech Stack:** Erlang/OTP 27, rebar3, Python 3 (stdlib only), Docker, Docker Compose, Alpine Linux

**Spec:** `.github/plans/3-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `priv/scripts/mock_adapter.py` | Create | Stdin/stdout JSON protocol mock for generate/health/memory |
| `test/mock_adapter_test.py` | Create | Python unittest for mock adapter (subprocess-based) |
| `config/vm.args.src` | Create | Prod release VM args with env var placeholders |
| `config/sys.config.src` | Create | Prod release sys config with stdout logging |
| `rebar.config` | Modify | Add `.src` config to prod profile, keep originals in default |
| `.dockerignore` | Create | Exclude _build/, .git/, etc. from Docker context |
| `Dockerfile.dev` | Create | Multi-stage Alpine build (builder + runtime) |
| `docker-compose.yml` | Create | Two services: dev (runtime) and test (builder) |
| `.github/workflows/ci.yml` | Modify | Add docker build + test job |
| `CONTRIBUTING.md` | Modify | Add Development Setup section |

---

## Task 1: Mock Adapter — Tests

Write the Python tests first. The mock adapter doesn't exist yet, so these tests will fail.

**Files:**
- Create: `test/mock_adapter_test.py`

- [ ] **Step 1: Create test file**

```python
"""Tests for the mock inference engine adapter.

Spawns mock_adapter.py as a subprocess and exercises the line-delimited
JSON protocol: generate, health, memory, and unknown message types.
"""
import json
import os
import subprocess
import unittest

ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'priv', 'scripts', 'mock_adapter.py'
)


class MockAdapterTest(unittest.TestCase):
    """Test the mock adapter's JSON protocol responses."""

    def _send_receive(self, message):
        """Send a JSON message to the adapter and return parsed responses."""
        proc = subprocess.Popen(
            ['python3', ADAPTER_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = proc.communicate(
            input=json.dumps(message) + '\n', timeout=5
        )
        lines = [l for l in stdout.strip().split('\n') if l]
        return [json.loads(line) for line in lines]

    def _send_receive_multi(self, messages):
        """Send multiple JSON messages in one session, return all responses."""
        proc = subprocess.Popen(
            ['python3', ADAPTER_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        input_data = '\n'.join(json.dumps(m) for m in messages) + '\n'
        stdout, stderr = proc.communicate(input=input_data, timeout=5)
        lines = [l for l in stdout.strip().split('\n') if l]
        return [json.loads(line) for line in lines]

    def test_health(self):
        responses = self._send_receive({"type": "health"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")
        self.assertEqual(resp["gpu_util"], 0.0)
        self.assertEqual(resp["mem_used_gb"], 0.0)

    def test_memory(self):
        responses = self._send_receive({"type": "memory"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "memory")
        self.assertEqual(resp["total_gb"], 80.0)
        self.assertEqual(resp["used_gb"], 0.0)
        self.assertEqual(resp["available_gb"], 80.0)

    def test_generate(self):
        responses = self._send_receive(
            {"type": "generate", "id": "req-001", "prompt": "Hello", "params": {}},
        )
        self.assertEqual(len(responses), 6)

        # First 5 are token messages
        expected_tokens = ["Hello", "from", "Loom", "mock", "adapter"]
        for i, token_text in enumerate(expected_tokens):
            resp = responses[i]
            self.assertEqual(resp["type"], "token")
            self.assertEqual(resp["id"], "req-001")
            self.assertEqual(resp["token_id"], i + 1)
            self.assertEqual(resp["text"], token_text)
            self.assertFalse(resp["finished"])

        # Last is done message
        done = responses[5]
        self.assertEqual(done["type"], "done")
        self.assertEqual(done["id"], "req-001")
        self.assertEqual(done["tokens_generated"], 5)
        self.assertIn("time_ms", done)

    def test_unknown_type(self):
        responses = self._send_receive({"type": "bogus"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")
        self.assertIn("bogus", resp["message"])

    def test_missing_type(self):
        responses = self._send_receive({"no_type_field": True})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")

    def test_generate_missing_id(self):
        responses = self._send_receive({"type": "generate", "prompt": "Hi"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")

    def test_multiple_messages_in_session(self):
        """Verify the adapter handles multiple messages in a single session."""
        responses = self._send_receive_multi([
            {"type": "health"},
            {"type": "memory"},
            {"type": "health"},
        ])
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0]["type"], "health")
        self.assertEqual(responses[1]["type"], "memory")
        self.assertEqual(responses[2]["type"], "health")


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && python3 -m unittest test.mock_adapter_test -v`

Expected: FAIL — `mock_adapter.py` does not exist, subprocess will fail.

- [ ] **Step 3: Commit test file**

```bash
git add test/mock_adapter_test.py
git commit -m "test: add Python tests for mock adapter protocol (P0-03)

Tests exercise generate, health, memory, unknown type, missing type,
and missing id error cases. Tests fail until mock_adapter.py is created.

Refs #3"
```

---

## Task 2: Mock Adapter — Implementation

Write the minimal mock adapter to make all tests pass.

**Files:**
- Create: `priv/scripts/mock_adapter.py`

- [ ] **Step 1: Create mock adapter**

```python
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
```

- [ ] **Step 2: Delete the `.gitkeep` placeholder**

```bash
rm priv/.gitkeep
```

`priv/scripts/mock_adapter.py` now provides content in `priv/`.

- [ ] **Step 3: Run tests to verify they pass**

Run: `cd /Users/mohansharma/Projects/loom && python3 -m unittest test.mock_adapter_test -v`

Expected: All 7 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add priv/scripts/mock_adapter.py
git rm priv/.gitkeep
git commit -m "feat: add mock Python adapter for GPU-free development (P0-03)

Stdin/stdout adapter speaking line-delimited JSON protocol.
Handles generate (fixed tokens), health, and memory messages.
Uses only Python stdlib.

Refs #3"
```

---

## Task 3: Release Config Templates

Create `.src` config files for env var substitution in prod releases. Update `rebar.config` to use them in the prod profile.

**Files:**
- Create: `config/vm.args.src`
- Create: `config/sys.config.src`
- Modify: `rebar.config`

- [ ] **Step 1: Create `config/vm.args.src`**

```
-name ${LOOM_NODE_NAME}
-setcookie ${LOOM_COOKIE}
+K true
+A 30
+P 1048576
+Q 1048576
```

- [ ] **Step 2: Create `config/sys.config.src`**

```erlang
[
    {loom, []},
    {sasl, [
        {sasl_error_logger, tty},
        {errlog_type, error}
    ]}
].
```

- [ ] **Step 3: Update `rebar.config`**

Replace the `relx` and `profiles` sections. Keep `sys_config`/`vm_args` in default profile for local dev. Add `.src` variants to prod profile:

Current `relx` section (lines 14-20):
```erlang
{relx, [
    {release, {loom, "0.1.0"}, [loom, sasl]},
    {dev_mode, true},
    {include_erts, false},
    {sys_config, "config/sys.config"},
    {vm_args, "config/vm.args"}
]}.
```

Current `profiles` section (lines 22-29):
```erlang
{profiles, [
    {prod, [
        {relx, [
            {dev_mode, false},
            {include_erts, true}
        ]}
    ]}
]}.
```

New `profiles` section:
```erlang
{profiles, [
    {prod, [
        {relx, [
            {dev_mode, false},
            {include_erts, true},
            {sys_config_src, "config/sys.config.src"},
            {vm_args_src, "config/vm.args.src"}
        ]}
    ]}
]}.
```

Note: The default relx section already has `sys_config` and `vm_args` — leave those unchanged.

- [ ] **Step 4: Verify prod release builds and uses .src configs**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 as prod release`

Expected: Success, no errors. Then verify the release uses `.src` configs:

Run: `ls _build/prod/rel/loom/releases/0.1.0/`

Expected: Should contain `vm.args.src` and `sys.config.src` (not the non-`.src` variants). If both `.src` and non-`.src` files appear, the prod profile must explicitly suppress the defaults — add `{sys_config, undefined}` and `{vm_args, undefined}` to the prod profile's relx config.

Also verify default profile still works:

Run: `rebar3 compile`

Expected: Success.

- [ ] **Step 5: Commit**

```bash
git add config/vm.args.src config/sys.config.src rebar.config
git commit -m "feat: add .src config templates for prod release env vars (P0-03)

vm.args.src uses LOOM_NODE_NAME and LOOM_COOKIE env vars.
sys.config.src logs to stdout (tty) for container environments.
Prod profile uses .src variants; default profile keeps original
config files for local rebar3 shell development.

Refs #3"
```

---

## Task 4: Docker Files

Create the Dockerfile, .dockerignore, and docker-compose.yml.

**Files:**
- Create: `.dockerignore`
- Create: `Dockerfile.dev`
- Create: `docker-compose.yml`

- [ ] **Step 1: Create `.dockerignore`**

```
_build/
.git/
log/
*.plt
erl_crash.dump
rebar3.crashdump
.rebar3/
.vscode/
.claude/
Dockerfile.dev
docker-compose.yml
```

- [ ] **Step 2: Create `Dockerfile.dev`**

```dockerfile
# Stage 1: Builder — full toolchain for compiling and testing
FROM erlang:27-alpine AS builder

RUN apk add --no-cache python3 git

# Install rebar3
RUN wget https://s3.amazonaws.com/rebar3/rebar3 -O /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

WORKDIR /app

# Copy project source
COPY . .

# Fetch deps and build prod release
RUN rebar3 as prod release

# Stage 2: Runtime — minimal image with just the release + Python
FROM alpine:3.21

RUN apk add --no-cache libstdc++ ncurses-libs python3

WORKDIR /app

# Copy the built release from the builder stage
COPY --from=builder /app/_build/prod/rel/loom ./

# ASSUMPTION: rebar3 packages priv/ into the release automatically,
# so mock_adapter.py is available at lib/loom-0.1.0/priv/scripts/

ENV SERVER_PORT=8080
ENV LOOM_NODE_NAME=loom@127.0.0.1
ENV LOOM_COOKIE=loom_dev_cookie

EXPOSE 8080

CMD ["bin/loom", "foreground"]
```

- [ ] **Step 3: Create `docker-compose.yml`**

```yaml
services:
  dev:
    build:
      context: .
      dockerfile: Dockerfile.dev
    environment:
      - SERVER_PORT=${SERVER_PORT:-8080}
      - LOOM_NODE_NAME=${LOOM_NODE_NAME:-loom@127.0.0.1}
      - LOOM_COOKIE=${LOOM_COOKIE:-loom_dev_cookie}
    ports:
      # Reserved for future Cowboy HTTP listener (P0-10)
      - "${SERVER_PORT:-8080}:${SERVER_PORT:-8080}"

  test:
    build:
      context: .
      dockerfile: Dockerfile.dev
      target: builder
    working_dir: /app
```

- [ ] **Step 4: Build Docker image**

Run: `cd /Users/mohansharma/Projects/loom && docker compose build`

Expected: Both `dev` and `test` images build successfully. Watch for:
- rebar3 download succeeds
- `rebar3 as prod release` succeeds
- Runtime stage copies release correctly

- [ ] **Step 5: Verify `dev` service starts**

Run: `docker compose up dev -d && sleep 3 && docker compose logs dev && docker compose down`

Expected: BEAM node starts in foreground mode. Logs show application startup. The node may print warnings about no HTTP listener — that's expected (P0-10 will add it).

- [ ] **Step 6: Verify `test` service can run Python tests**

Run: `docker compose run --rm test python3 -m unittest test.mock_adapter_test -v`

Expected: All 7 mock adapter tests pass inside the container.

- [ ] **Step 7: Verify `test` service can run Erlang tests**

Run: `docker compose run --rm test rebar3 eunit`

Expected: Erlang tests pass (currently minimal but should compile and run).

- [ ] **Step 8: Commit**

```bash
git add .dockerignore Dockerfile.dev docker-compose.yml
git commit -m "feat: add Docker dev environment with multi-stage Alpine build (P0-03)

Multi-stage Dockerfile: builder (erlang:27-alpine + rebar3 + python3)
and runtime (alpine + python3 + OTP release only).

docker-compose.yml provides two services:
- dev: runs the OTP release in foreground mode
- test: targets builder stage for rebar3/Python test execution

Environment variables: SERVER_PORT, LOOM_NODE_NAME, LOOM_COOKIE.

Refs #3"
```

---

## Task 5: CI Pipeline Update

Add the Docker build + test job to the GitHub Actions workflow.

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add `docker` job to CI**

Append the following job after the existing `analysis` job in `.github/workflows/ci.yml`:

```yaml
  docker:
    name: Docker
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

      - name: Build Docker image
        run: docker compose build

      - name: Run mock adapter tests
        run: docker compose run --rm test python3 -m unittest test.mock_adapter_test -v
```

This job has no `needs:` — it runs in parallel with `build`, `test`, and `analysis`.

- [ ] **Step 2: Verify CI YAML is valid**

Run: `cd /Users/mohansharma/Projects/loom && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`

If `yaml` module is not available, verify manually that the YAML structure is correct (proper indentation, job is under `jobs:` key).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add Docker build and mock adapter test job (P0-03)

New 'docker' job builds the multi-stage Docker image and runs
Python mock adapter tests inside the test container. Runs in
parallel with existing build/test/analysis jobs.

Refs #3"
```

---

## Task 6: Update CONTRIBUTING.md

Add development setup documentation.

**Files:**
- Modify: `CONTRIBUTING.md`

- [ ] **Step 1: Add Development Setup section**

Insert after the intro paragraph ("Thank you for your interest...") and before "## How to Contribute":

```markdown
## Development Setup

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose

### Quick Start

```bash
git clone https://github.com/mohansharma-me/loom.git
cd loom
docker compose build
docker compose up
```

The `dev` service builds an immutable OTP release image. Code changes require a rebuild:

```bash
docker compose build && docker compose up
```

### Running Tests

Erlang tests:

```bash
docker compose run --rm test rebar3 eunit
```

Mock adapter tests (Python):

```bash
docker compose run --rm test python3 -m unittest test.mock_adapter_test -v
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SERVER_PORT` | `8080` | Docker port mapping (future HTTP API) |
| `LOOM_NODE_NAME` | `loom@127.0.0.1` | BEAM node name |
| `LOOM_COOKIE` | `loom_dev_cookie` | Erlang distribution cookie |
| `LOOM_LOG_DIR` | `log` | SASL log directory (local `rebar3 shell` only; Docker logs to stdout) |

Override via environment or a `.env` file:

```bash
SERVER_PORT=9090 docker compose up
```
```

- [ ] **Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: add Docker dev setup instructions to CONTRIBUTING.md (P0-03)

Covers prerequisites, quick start, running tests, and
environment variable configuration.

Refs #3"
```

---

## Task 7: Final Verification and ROADMAP Update

End-to-end validation and roadmap update.

**Files:**
- Modify: `ROADMAP.md`

- [ ] **Step 1: Clean rebuild and full test**

```bash
cd /Users/mohansharma/Projects/loom
docker compose down --rmi all 2>/dev/null
docker compose build
docker compose up dev -d
sleep 3
docker compose logs dev
docker compose run --rm test rebar3 eunit
docker compose run --rm test python3 -m unittest test.mock_adapter_test -v
docker compose down
```

Expected: Image builds from scratch, dev service starts, all tests pass.

- [ ] **Step 2: Verify acceptance criteria**

Checklist from issue #3:
- [ ] `docker compose up` starts a working dev environment
- [ ] Mock adapter responds to all three message types on stdin/stdout
- [ ] Developer can clone repo and have working environment within 5 minutes
- [ ] Mock adapter is tested independently (Python unittest)

- [ ] **Step 3: Update ROADMAP.md**

Change P0-03 line from:
```markdown
- [ ] Dev environment with Docker Compose and docs — [#3](https://github.com/mohansharma-me/loom/issues/3) `P0-03`
```

To:
```markdown
- [x] Dev environment with Docker Compose and docs — [#3](https://github.com/mohansharma-me/loom/issues/3) `P0-03`
```

Update Progress Summary table — Phase 0 Done: 2 → 3, Pending: 13 → 12. Total Done: 2 → 3, Total Pending: 48 → 47.

- [ ] **Step 4: Commit**

```bash
git add ROADMAP.md
git commit -m "docs: mark P0-03 complete in ROADMAP.md

Refs #3"
```

- [ ] **Step 5: Open PR**

Branch: `feature/dev-environment`
PR title: `P0-03: Add Docker dev environment with mock adapter`
Body references: `Fixes #3`
