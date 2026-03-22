# Design Plan: Initialize rebar3 project structure (Issue #1)

> Parent issue: [#1 — P0-01: Initialize rebar3 project structure with standard OTP application layout](https://github.com/mohansharma-me/loom/issues/1)

## Overview

Bootstrap the Loom Erlang/OTP project with a rebar3 skeleton that compiles, runs, passes dialyzer, and provides a working release — with zero application logic beyond a running supervisor.

## Deviations from Issue #1

The following changes were discussed and approved during design brainstorming:

- **JSON library:** Issue specifies `jsx`. Replaced with OTP 27's built-in `json` module (fastest option, zero dependency). A thin `loom_json` wrapper provides the simple `encode/1` / `decode/1` API.
- **OTP version:** Issue does not specify a minimum. This design requires OTP 27+ to use the built-in `json` module, process labels, and improved supervisor error reporting.
- **`rebar.lock`:** Not mentioned in the issue. Will be committed for reproducible builds (standard rebar3 practice).

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| OTP version | 27+ minimum | Greenfield project; built-in `json` module replaces jsx, process labels aid observability, improved supervisor error reporting |
| JSON library | OTP 27 built-in `json` module | Fastest option (1.5–2.5x faster than jiffy in benchmarks), zero external dependency, standard going forward |
| JSON API | Thin `loom_json` wrapper | Isolates the `json` module's callback-based API behind `encode/1` / `decode/1`; single point to control decode behavior (binary keys) |
| Dependencies | `cowboy`, `prometheus` | Cowboy for HTTP/SSE API (P0-10); prometheus included early per issue spec, even though metrics are P1-09 |
| Project structure | Flat `src/` with `loom_` prefix | Standard OTP convention; umbrella rejected because Loom's single supervision tree design doesn't map to independent OTP applications |
| Release | relx with dev + prod profiles | Makefile specifies a `release` target; catches release-level config issues (sys.config, vm.args) early |
| Node naming | Long names (`-name loom@127.0.0.1`) | Avoids migration from short to long names when Phase 3 (multi-node) arrives |
| Compiler strictness | `warnings_as_errors` + `warn_missing_spec` | Enforces type specs on every exported function from day one; aligns with Dialyzer cross-cutting concern (#51) |

## Project Structure

```
loom/
├── rebar.config
├── Makefile
├── .gitignore
├── config/
│   ├── sys.config
│   └── vm.args
├── src/
│   ├── loom.app.src
│   ├── loom_app.erl
│   ├── loom_sup.erl
│   └── loom_json.erl
├── priv/                   # Empty (.gitkeep), for future Python adapters
└── test/                   # Empty, rebar3 eunit needs it
```

## File Specifications

### `rebar.config`

```erlang
{minimum_otp_vsn, "27"}.

{erl_opts, [
    debug_info,
    warnings_as_errors,
    warn_missing_spec
]}.

{deps, [
    {cowboy, "2.12.0"},
    {prometheus, "4.11.0"}
]}.

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
            {include_erts, true}
        ]}
    ]}
]}.

{dialyzer, [
    {warnings, [
        error_handling,
        underspecs,
        unmatched_returns
    ]}
]}.

{shell, [{apps, [loom]}]}.
```

- Pinned dependency versions for reproducible builds.
- `dev_mode` symlinks in default profile; full ERTS bundling in `prod`.
- SASL included in release for OTP crash reports.
- Exact dependency versions to be verified at implementation time.

### `src/loom.app.src`

```erlang
{application, loom, [
    {description, "Fault-tolerant inference orchestration on Erlang/OTP"},
    {vsn, "0.1.0"},
    {registered, [loom_sup]},
    {mod, {loom_app, []}},
    {applications, [
        kernel,
        stdlib,
        sasl,
        cowboy,
        prometheus
    ]},
    {env, []},
    {modules, []},
    {licenses, ["Apache-2.0"]},
    {links, [{"GitHub", "https://github.com/mohansharma-me/loom"}]}
]}.
```

- `{mod, {loom_app, []}}` tells OTP to call `loom_app:start/2` on boot.
- `{modules, []}` auto-populated by rebar3 at compile time.
- `registered` lists only `loom_sup` for now; future processes added as implemented.

### `src/loom_app.erl`

```erlang
-module(loom_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {ok, pid(), term()}.
start(_StartType, _StartArgs) ->
    loom_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
```

### `src/loom_sup.erl`

```erlang
-module(loom_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    {ok, {SupFlags, []}}.
```

- `one_for_one` matches KNOWLEDGE.md §4.2 top-level supervisor design.
- `intensity => 5, period => 10` — standard restart limits.
- Empty child list; children added as components are implemented.

### `src/loom_json.erl`

```erlang
-module(loom_json).

-export([encode/1, decode/1]).

-spec encode(term()) -> binary().
encode(Term) ->
    iolist_to_binary(json:encode(Term)).

-spec decode(binary()) -> term().
decode(Binary) ->
    json:decode(Binary).
```

- `encode/1` returns `binary()` (not `iodata()`) for simplicity at the wire protocol level.
- `decode/1` returns maps with binary keys — avoids atom table exhaustion from external input.
- Will grow as needed (error handling, custom encoders) but starts minimal.

### `config/vm.args`

```
-name loom@127.0.0.1
-setcookie loom_dev_cookie
+K true
+A 30
+P 1048576
+Q 1048576
```

- Long names from day one for Phase 3 readiness.
- `loom_dev_cookie` is development-only; production overrides via environment.
- `+K true` — kernel poll (epoll/kqueue).
- `+A 30` — async threads for file I/O and Port communication.
- `+P` / `+Q` 1M — headroom for process-per-request model.

### `config/sys.config`

```erlang
[
    {loom, []},
    {sasl, [
        {sasl_error_logger, {file, "log/sasl-error.log"}},
        {errlog_type, error}
    ]}
].
```

- Minimal config; application-specific entries added as components are built.
- SASL error logging to file.

### `Makefile`

```makefile
.PHONY: compile test shell release clean dialyzer

compile:
	rebar3 compile

test:
	rebar3 eunit

shell:
	rebar3 shell

release:
	rebar3 release

clean:
	rebar3 clean

dialyzer:
	rebar3 dialyzer
```

### `.gitignore`

```
_build/
*.beam
*.o
*.plt
erl_crash.dump
log/
.rebar3/
rebar3.crashdump
```

## Acceptance Criteria

All from issue #1:

- [ ] `rebar3 compile` succeeds with zero warnings
- [ ] `rebar3 shell` starts the application and the top-level supervisor is alive
- [ ] `rebar3 eunit` runs (even with no tests yet)
- [ ] `rebar3 dialyzer` runs cleanly
- [ ] Project structure follows standard OTP conventions

## Assumptions

- OTP 27 is installed in the development environment.
- rebar3 3.23+ is available (supports OTP 27).
- Pinned dependency versions (cowboy 2.12.0, prometheus 4.11.0) will be verified at implementation time against hex.pm.
- `priv/` committed with `.gitkeep`; populated when Python adapters arrive (P0-06).
- `log/` directory created at runtime by SASL, not checked into git.
- Binary keys (not atom keys) for all JSON decode operations.
- `loom_dev_cookie` is not a security boundary; production deployments override.
