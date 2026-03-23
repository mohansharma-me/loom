# P0-03 Design: Dev Environment with Docker Compose and Developer Documentation

**Issue:** [#3](https://github.com/mohansharma-me/loom/issues/3)
**Status:** Approved
**Date:** 2026-03-23

---

## Overview

Create a containerized development environment that builds an immutable OTP release image and a mock Python adapter for GPU-free development. Developers can clone the repo and have a working environment with `docker compose build && docker compose up`.

## Architecture

```
Dockerfile.dev (multi-stage, Alpine)
├── Stage 1: builder (erlang:27-alpine + rebar3 + python3)
│   ├── Copy project source (filtered by .dockerignore)
│   ├── rebar3 as prod release
│   └── Full build toolchain retained (used by `test` service)
└── Stage 2: runtime (alpine + python3)
    ├── Copy OTP release from builder
    └── CMD: bin/loom foreground

docker-compose.yml
├── dev service (runtime stage)
│   ├── Env vars: SERVER_PORT, LOOM_NODE_NAME, LOOM_COOKIE, LOOM_LOG_DIR
│   ├── Port mapping: ${SERVER_PORT}:${SERVER_PORT}
│   └── No volume mounts (immutable container)
└── test service (builder stage)
    └── For running rebar3 eunit, Python tests, etc.
```

## Files to Create

### 1. `Dockerfile.dev`

Multi-stage Alpine build:

- **Builder stage (`builder`):** `erlang:27-alpine`. Downloads and installs rebar3 (not included in base image). Installs `python3`. Copies project source (filtered by `.dockerignore`). Runs `rebar3 as prod release`. Retains full toolchain — the `test` service targets this stage.
- **Runtime stage:** `alpine:3.21`. Installs `python3` (for mock adapter). Copies only the built release from builder (`_build/prod/rel/loom/`). No rebar3, no compiler, no build tools.
- **CMD:** `bin/loom foreground`

### 2. `docker-compose.yml`

Two services:

**`dev` service (runtime):**
- Builds from `Dockerfile.dev` (final stage)
- Environment variables with defaults:
  - `SERVER_PORT=8080`
  - `LOOM_NODE_NAME=loom@127.0.0.1`
  - `LOOM_COOKIE=loom_dev_cookie`
- Port mapping: `${SERVER_PORT:-8080}:${SERVER_PORT:-8080}`
- No volume mounts — container is immutable
- Note: port 8080 is reserved for the future Cowboy HTTP listener (P0-10). Nothing listens on it yet.

**`test` service (builder stage):**
- Builds from `Dockerfile.dev`, targets the `builder` stage
- Has rebar3, Erlang compiler, Python 3, and full source tree
- Used for: `docker compose run test rebar3 eunit`, `docker compose run test python3 -m unittest test.mock_adapter_test`
- No port mapping, no env var templating needed

### 3. `.dockerignore`

Prevents copying build artifacts and VCS history into the Docker context:

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
```

### 4. `priv/scripts/mock_adapter.py`

Stdin/stdout mock that speaks the line-delimited JSON protocol defined in KNOWLEDGE.md section 4.4.

Runs in an infinite read loop until stdin closes (EOF = Port closed = adapter exits).

**Message handling:**

| Input Type | Response |
|-----------|----------|
| `generate` | 5 token messages ("Hello", "from", "Loom", "mock", "adapter") + 1 done message |
| `health` | `{"type": "health", "status": "ok", "gpu_util": 0.0, "mem_used_gb": 0.0}` |
| `memory` | `{"type": "memory", "total_gb": 80.0, "used_gb": 0.0, "available_gb": 80.0}` |
| unknown | `{"type": "error", "message": "unknown message type: <type>"}` |

Protocol details:
- One JSON object per line (newline-delimited)
- Input must have a `"type"` field
- `generate` input must have `"id"` field; tokens echo it back
- Token messages: `{"type": "token", "id": "<id>", "token_id": <n>, "text": "<word>", "finished": false}`
- Done message: `{"type": "done", "id": "<id>", "tokens_generated": 5, "time_ms": 0}`
- Uses only Python stdlib (`json`, `sys`)

### 5. `test/mock_adapter_test.py`

Python unittest exercising all three message types plus unknown type error:
- Spawns `mock_adapter.py` as a subprocess
- Writes JSON lines to stdin, reads JSON lines from stdout
- Asserts correct response structure and values for each message type
- Uses only `unittest`, `subprocess`, `json` from stdlib

### 6. `config/vm.args.src`

New file for prod release. Uses rebar3 release template substitution:

```
-name ${LOOM_NODE_NAME}
-setcookie ${LOOM_COOKIE}
+K true
+A 30
+P 1048576
+Q 1048576
```

### 7. `config/sys.config.src`

New file for prod release. Uses rebar3 release template substitution. Logs to stdout (`tty`) for container-friendly observability:

```erlang
[
    {loom, []},
    {sasl, [
        {sasl_error_logger, tty},
        {errlog_type, error}
    ]}
].
```

## Files to Modify

### 8. `.github/workflows/ci.yml`

Add a new `docker` job that runs in parallel with the existing `test` and `analysis` jobs (all depend on `build`). This job:

- Builds the Docker image using `docker compose build`
- Runs mock adapter Python tests: `docker compose run test python3 -m unittest test.mock_adapter_test`
- Does NOT push the image — build-only validation

The job uses GitHub Actions' built-in Docker support (ubuntu runners have Docker pre-installed). No Docker layer caching needed for now — the build is infrequent and Alpine + Erlang compile is fast enough.

```yaml
  docker:
    name: Docker
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

      - name: Build Docker image
        run: docker compose build

      - name: Run mock adapter tests
        run: docker compose run test python3 -m unittest test.mock_adapter_test
```

### 9. `rebar.config`

Keep existing `sys_config`/`vm_args` in the default profile (for local `rebar3 shell`). Add `.src` variants to the prod profile only:

```erlang
{relx, [
    {release, {loom, "0.1.0"}, [loom, sasl]},
    {dev_mode, true},
    {include_erts, false},
    {sys_config, "config/sys.config"},
    {vm_args, "config/vm.args"}
]}.

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

This preserves non-Docker local development (`rebar3 shell` still works with the original config files).

### 10. `CONTRIBUTING.md`

Add "Development Setup" section after intro, before "How to Contribute":

- Prerequisites: Docker, Docker Compose
- Quick start: `docker compose build && docker compose up`
- Running Erlang tests: `docker compose run test rebar3 eunit`
- Running mock adapter tests: `docker compose run test python3 -m unittest test.mock_adapter_test`
- Rebuild after code changes: `docker compose build && docker compose up`
- Environment variables table (SERVER_PORT, LOOM_NODE_NAME, LOOM_COOKIE, LOOM_LOG_DIR with defaults)
- Note that port 8080 is reserved for the future HTTP API (P0-10)

## Files NOT Deleted

`config/vm.args` and `config/sys.config` are **kept** — they serve local non-Docker development via `rebar3 shell`. The `.src` variants are used only by the prod release profile.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SERVER_PORT` | `8080` | Docker port mapping + future Cowboy HTTP listener (P0-10) |
| `LOOM_NODE_NAME` | `loom@127.0.0.1` | BEAM node name for distribution |
| `LOOM_COOKIE` | `loom_dev_cookie` | Erlang distribution cookie |
| `LOOM_LOG_DIR` | `log` | SASL log file directory (local dev only; Docker uses stdout via `tty`) |

## Design Decisions

1. **Alpine throughout** — `erlang:27-alpine` for builder, `alpine` for runtime. No glibc/musl mismatch since both stages use musl.
2. **Immutable container** — No volume mounts. Code changes require `docker compose build`. Like a Java build producing a JAR.
3. **Multi-stage build** — Builder has full toolchain. Runtime has only release + Python. `test` service targets builder stage for running tests.
4. **Dual config approach** — Plain `vm.args`/`sys.config` for local dev, `.src` variants for prod release in Docker. Avoids breaking non-Docker workflows.
5. **Mock adapter is stdlib-only** — No pip, no requirements.txt. Keeps the image simple and the adapter portable.
6. **No GPU dependencies** — Per issue requirement: dev environment works without GPU. Mock adapter substitutes for real inference engine.
7. **Two docker-compose services** — `dev` (lean runtime) for running the app, `test` (full toolchain) for running tests. Clean separation.
8. **SASL to stdout in Docker** — Container logs go to stdout (`tty`) for `docker compose logs` compatibility. Local dev retains file-based logging.
9. **rebar3 installed explicitly** — The `erlang:27-alpine` base image does not include rebar3. Downloaded and installed in the builder stage.
10. **Docker build in CI** — Separate `docker` job validates Dockerfile and runs Python mock adapter tests. Runs in parallel with existing `test`/`analysis` jobs. Build-only, no push.

## Assumptions

- `erlang:27-alpine` image exists and is current on Docker Hub
- Alpine's `python3` package provides Python 3.11+
- rebar3 `.src` template substitution uses `${VAR}` syntax and works at release boot
- rebar3 packages `priv/` directory into releases automatically
- rebar3 can be downloaded as a standalone escript for the builder stage
- rebar3 profile merging: when prod profile sets `sys_config_src`, it takes precedence over the default profile's `sys_config` (needs verification during implementation; if not, prod profile must explicitly unset `sys_config`)
