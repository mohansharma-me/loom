# P0-02: GitHub Actions CI Pipeline — Design Spec

**Issue:** [#2](https://github.com/mohansharma-me/loom/issues/2)
**Date:** 2026-03-22
**Status:** Approved

---

## Overview

Set up a GitHub Actions CI workflow that runs on every push to `main` and every PR. The workflow uses a three-job architecture: `build` compiles the project and populates caches, then `test` and `analysis` run in parallel consuming those caches.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| OTP version | 27 only | Matches `minimum_otp_vsn` in `rebar.config` |
| Runner strategy | `erlef/setup-beam` on Ubuntu | Ecosystem standard, exact OTP/rebar3 version pinning |
| Job structure | 3 jobs: `build` → `test` + `analysis` | Parallel feedback for tests vs static analysis; scales as project grows |
| Cache targets | `_build/` + `~/.cache/rebar3/` | Fast builds; PLT cached inside `_build/` |
| Empty test suites | Run from day one | Infrastructure ready when tests are added |
| Path filter | Skip CI for docs-only changes | Avoid wasting CI minutes on markdown edits |

## Workflow Architecture

```
              ┌─────────┐
              │  build   │
              │ compile  │
              └────┬─────┘
                   │
          ┌────────┴────────┐
          ▼                 ▼
    ┌───────────┐    ┌────────────┐
    │   test    │    │  analysis  │
    │ eunit, ct │    │ dialyzer,  │
    │           │    │ xref       │
    └───────────┘    └────────────┘
```

### Job 1: `build`

**Purpose:** Compile the project, populate all caches.

**Steps:**
1. Checkout repository
2. Setup Erlang via `erlef/setup-beam` (OTP 27, rebar3 latest stable)
3. Restore cache (`_build/` + `~/.cache/rebar3/`, keyed on `runner.os-otp27-rebar.lock` hash)
4. `rebar3 compile`
5. Save cache

### Job 2: `test` (depends on: `build`)

**Purpose:** Run all test suites.

**Steps:**
1. Checkout repository
2. Setup Erlang via `erlef/setup-beam` (same versions)
3. Restore cache
4. `rebar3 eunit` — unit tests
5. `rebar3 ct` — common_test suites

Currently both will pass vacuously (no tests exist). As tests are added in future issues, this job catches regressions without CI modifications.

### Job 3: `analysis` (depends on: `build`)

**Purpose:** Run static analysis checks.

**Steps:**
1. Checkout repository
2. Setup Erlang via `erlef/setup-beam` (same versions)
3. Restore cache (includes Dialyzer PLT in `_build/`)
4. `rebar3 dialyzer` — type analysis (warnings configured in `rebar.config`: `error_handling`, `underspecs`, `unmatched_returns`)
5. `rebar3 xref` — cross-reference checking for undefined/unused functions

## Trigger Rules

```yaml
on:
  push:
    branches: [main]
    paths-ignore:
      - '**.md'
      - 'docs/**'
      - '!.github/**'
  pull_request:
    branches: [main]
    paths-ignore:
      - '**.md'
      - 'docs/**'
      - '!.github/**'
```

Skips CI for docs-only changes. The `!.github/**` negation ensures workflow file changes always trigger CI.

## Cache Strategy

- **Key:** `${{ runner.os }}-otp27-${{ hashFiles('rebar.lock') }}`
- **Restore keys:** `${{ runner.os }}-otp27-` (partial match for new deps)
- **Paths:** `_build/`, `~/.cache/rebar3/`
- **Shared across jobs:** All three jobs use the same cache key. `build` populates it; `test` and `analysis` restore it.

Dialyzer PLT is stored inside `_build/default/rebar3_*_plt` and is automatically cached. First run builds the PLT (~2-3 min); subsequent runs reuse it.

## CI Badge

Add a workflow status badge to `README.md` immediately after the `# Loom` title:

```markdown
[![CI](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml/badge.svg)](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml)
```

## Branch Protection (via `gh api`)

After the CI workflow is merged and has run at least once (so GitHub knows the check names), configure branch protection on `main` via `gh api`:

- **Require status checks to pass before merging:** enable
  - Required checks: `build`, `test`, `analysis`
- **Require branches to be up to date before merging:** enable
- **Require pull request reviews before merging:** already configured (per CONTRIBUTING.md)

Configured programmatically using `gh api repos/{owner}/{repo}/branches/main/protection`.

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `.github/workflows/ci.yml` | Create | The CI workflow |
| `README.md` | Edit | Add CI badge after title |

## Acceptance Criteria (from issue #2)

- [x] CI runs on push to `main` and on all PRs
- [x] All five checks (compile, eunit, ct, dialyzer, xref) run
- [x] Rebar3 deps are cached between runs
- [x] CI badge added to README.md
