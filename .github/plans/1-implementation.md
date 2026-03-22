# P0-01: Initialize rebar3 Project — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bootstrap the Loom Erlang/OTP project with a compiling, running, dialyzer-clean rebar3 skeleton.

**Architecture:** Single OTP application with flat `src/` layout. `loom_app` starts `loom_sup` (empty supervisor). `loom_json` wraps OTP 27's built-in `json` module. relx produces a release.

**Tech Stack:** Erlang/OTP 27+, rebar3, Cowboy 2.x, prometheus.erl

**Spec:** [`.github/plans/1-design.md`](1-design.md)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `rebar.config` | Create | Build config: deps, compiler opts, relx, dialyzer, shell |
| `Makefile` | Create | Convenience targets: compile, test, shell, release, clean, dialyzer |
| `.gitignore` | Create | Exclude build artifacts, logs, crash dumps |
| `config/sys.config` | Create | Application environment and SASL logging config |
| `config/vm.args` | Create | BEAM VM flags: node name, cookie, scheduler tuning |
| `src/loom.app.src` | Create | OTP application resource file |
| `src/loom_app.erl` | Create | `application` behaviour — starts top-level supervisor |
| `src/loom_sup.erl` | Create | `supervisor` behaviour — empty child list, `one_for_one` |
| `src/loom_json.erl` | Create | Thin wrapper: `encode/1`, `decode/1` over OTP 27 `json` module |
| `priv/.gitkeep` | Create | Placeholder for future Python adapters |
| `test/.gitkeep` | Create | Placeholder for future tests |

---

## Task 1: Build Configuration

**Files:**
- Create: `rebar.config`
- Create: `Makefile`
- Create: `.gitignore`

- [ ] **Step 1: Create `rebar.config`**

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

Note: Verify cowboy and prometheus versions against hex.pm before writing. Use the latest stable versions.

- [ ] **Step 2: Create `Makefile`**

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

Important: Makefile targets must use actual tab characters for indentation, not spaces.

- [ ] **Step 3: Create `.gitignore`**

```
_build/
*.beam
*.o
*.plt
erl_crash.dump
rebar3.crashdump
log/
.rebar3/
```

- [ ] **Step 4: Commit**

```bash
git add rebar.config Makefile .gitignore
git commit -m "feat(p0-01): add rebar3 build configuration

Add rebar.config with cowboy/prometheus deps, OTP 27+ minimum,
warnings_as_errors, relx release config, and dialyzer settings.
Add Makefile with standard targets and .gitignore for build artifacts."
```

---

## Task 2: Config Files

**Files:**
- Create: `config/sys.config`
- Create: `config/vm.args`

- [ ] **Step 1: Create `config/` directory**

```bash
mkdir -p config
```

- [ ] **Step 2: Create `config/sys.config`**

```erlang
[
    {loom, []},
    {sasl, [
        {sasl_error_logger, {file, "log/sasl-error.log"}},
        {errlog_type, error}
    ]}
].
```

- [ ] **Step 3: Create `config/vm.args`**

```
-name loom@127.0.0.1
-setcookie loom_dev_cookie
+K true
+A 30
+P 1048576
+Q 1048576
```

- [ ] **Step 4: Commit**

```bash
git add config/
git commit -m "feat(p0-01): add BEAM VM and application config

Add sys.config with SASL error logging.
Add vm.args with long node name, kernel poll, async threads,
and 1M process/port limits for process-per-request headroom."
```

---

## Task 3: OTP Application Skeleton

**Files:**
- Create: `src/loom.app.src`
- Create: `src/loom_app.erl`
- Create: `src/loom_sup.erl`

- [ ] **Step 1: Create `src/` directory**

```bash
mkdir -p src
```

- [ ] **Step 2: Create `src/loom.app.src`**

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

- [ ] **Step 3: Create `src/loom_app.erl`**

```erlang
-module(loom_app).
-behaviour(application).

-export([start/2, stop/1]).

%% ASSUMPTION: Return type includes {ok, pid(), term()} for behaviour compliance
%% but loom_sup:start_link/0 will only return {ok, pid()} | ignore | {error, term()}.
-spec start(application:start_type(), term()) -> {ok, pid()} | {ok, pid(), term()}.
start(_StartType, _StartArgs) ->
    loom_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
```

- [ ] **Step 4: Create `src/loom_sup.erl`**

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

- [ ] **Step 5: Commit**

```bash
git add src/
git commit -m "feat(p0-01): add OTP application and supervisor skeleton

Add loom.app.src with application metadata and dependency ordering.
Add loom_app implementing application behaviour.
Add loom_sup implementing supervisor behaviour with empty child list
and one_for_one strategy."
```

---

## Task 4: JSON Wrapper Module

**Files:**
- Create: `src/loom_json.erl`

- [ ] **Step 1: Create `src/loom_json.erl`**

```erlang
-module(loom_json).

-export([encode/1, decode/1]).

%% @doc Encode an Erlang term to a JSON binary.
%% Supports maps, lists, binaries, numbers, and booleans.
-spec encode(term()) -> binary().
encode(Term) ->
    iolist_to_binary(json:encode(Term)).

%% @doc Decode a JSON binary to an Erlang term.
%% ASSUMPTION: Returns maps with binary keys for all JSON objects.
%% This avoids atom table exhaustion from untrusted external input.
-spec decode(binary()) -> term().
decode(Binary) ->
    json:decode(Binary).
```

- [ ] **Step 2: Commit**

```bash
git add src/loom_json.erl
git commit -m "feat(p0-01): add loom_json wrapper over OTP 27 json module

Thin encode/1 and decode/1 API. Returns binary from encode,
maps with binary keys from decode. Replaces jsx dependency."
```

---

## Task 5: Placeholder Directories

**Files:**
- Create: `priv/.gitkeep`
- Create: `test/.gitkeep`

- [ ] **Step 1: Create directories and placeholder files**

```bash
mkdir -p priv test
touch priv/.gitkeep test/.gitkeep
```

- [ ] **Step 2: Commit**

```bash
git add priv/ test/
git commit -m "feat(p0-01): add priv/ and test/ placeholder directories

priv/ for future Python adapter scripts.
test/ for future eunit test modules."
```

---

## Task 6: Verify All Acceptance Criteria

This task verifies the full project against every acceptance criterion from issue #1.

- [ ] **Step 1: Fetch dependencies**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 get-deps`
Expected: Dependencies downloaded successfully.

- [ ] **Step 2: Verify `rebar3 compile` succeeds with zero warnings**

Run: `rebar3 compile`
Expected: No warnings, no errors. Output shows compilation of loom modules.

If warnings appear from `warn_missing_spec`, add missing `-spec` annotations to the flagged functions. If warnings come from dependencies, consider adding `{erl_opts, [{platform_define, ...}]}` or check if the dependency version needs adjustment.

- [ ] **Step 3: Verify `rebar3 eunit` runs**

Run: `rebar3 eunit`
Expected: Runs successfully with zero tests (no test modules exist yet). Should NOT fail.

- [ ] **Step 4: Verify `rebar3 dialyzer` runs cleanly**

Run: `rebar3 dialyzer`
Expected: First run builds PLT (may take a few minutes). No warnings on project code.

If `underspecs` warnings appear, fix the type specs in the flagged modules to match the actual return types of the called functions.

- [ ] **Step 5: Verify `rebar3 release` builds**

Run: `rebar3 release`
Expected: Release built successfully in `_build/default/rel/loom/`.

- [ ] **Step 6: Verify application starts and supervisor is alive**

Run: `rebar3 shell` (then in the Erlang shell):
```erlang
whereis(loom_sup).
%% Expected: Returns a pid (e.g., <0.XXX.0>), NOT undefined

supervisor:which_children(loom_sup).
%% Expected: [] (empty list — no children yet)
```

Exit shell with `q().`

- [ ] **Step 7: Verify `loom_json` works**

Run in `rebar3 shell`:
```erlang
loom_json:encode(#{<<"key">> => <<"value">>, <<"num">> => 42}).
%% Expected: <<"{\"key\":\"value\",\"num\":42}">> (or similar JSON binary)

loom_json:decode(<<"{\"key\":\"value\",\"num\":42}">>).
%% Expected: #{<<"key">> => <<"value">>, <<"num">> => 42}
```

Exit shell with `q().`

- [ ] **Step 8: Commit rebar.lock**

After successful `rebar3 compile`, a `rebar.lock` file will be generated.

```bash
git add rebar.lock
git commit -m "feat(p0-01): add rebar.lock for reproducible builds"
```

- [ ] **Step 9: Final verification commit**

Only if any fixes were needed during steps 2-7:

```bash
git add -A
git commit -m "fix(p0-01): address compilation/dialyzer issues from verification"
```

---

## Completion Checklist

After all tasks are complete, verify:

- [ ] `rebar3 compile` — zero warnings
- [ ] `rebar3 shell` — `whereis(loom_sup)` returns a pid
- [ ] `rebar3 eunit` — runs, zero tests
- [ ] `rebar3 dialyzer` — clean
- [ ] `rebar3 release` — builds successfully
- [ ] `loom_json:encode/1` and `decode/1` work correctly
- [ ] All files from the design spec are present
- [ ] `rebar.lock` is committed
- [ ] Project structure follows OTP conventions

When all criteria pass, the branch is ready for PR against `main` referencing `Fixes #1`.
