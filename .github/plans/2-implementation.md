# P0-02: GitHub Actions CI Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up a three-job GitHub Actions CI workflow (build, test, analysis) with caching and branch protection on `main`.

**Architecture:** Single workflow file with three jobs. `build` compiles and populates caches. `test` and `analysis` run in parallel consuming those caches. Branch protection configured via `gh api` after the workflow has run.

**Tech Stack:** GitHub Actions, `erlef/setup-beam`, rebar3, OTP 27

**Spec:** [`.github/plans/2-design.md`](2-design.md)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `.github/workflows/ci.yml` | Create | CI workflow: build, test, analysis jobs |
| `README.md` | Modify | Add CI status badge after title |

---

## Task 1: Create the CI Workflow File

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 0: Create feature branch**

```bash
git checkout -b feature/ci-pipeline
```

- [ ] **Step 1: Create the workflow file with triggers and build job**

```yaml
name: CI

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

permissions:
  contents: read

env:
  OTP_VERSION: '27'
  REBAR3_VERSION: '3.24'

jobs:
  build:
    name: Build
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Set up Erlang/OTP
        uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          rebar3-version: ${{ env.REBAR3_VERSION }}

      - name: Restore cache
        uses: actions/cache@v4
        with:
          path: |
            _build
            ~/.cache/rebar3
          key: ${{ runner.os }}-otp${{ env.OTP_VERSION }}-${{ hashFiles('rebar.lock') }}
          restore-keys: |
            ${{ runner.os }}-otp${{ env.OTP_VERSION }}-

      - name: Compile
        run: rebar3 compile
```

- [ ] **Step 2: Add the test job**

Append the `test` job to the `jobs:` section of `.github/workflows/ci.yml`:

```yaml
  test:
    name: Test
    runs-on: ubuntu-24.04
    needs: build
    steps:
      - uses: actions/checkout@v4

      - name: Set up Erlang/OTP
        uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          rebar3-version: ${{ env.REBAR3_VERSION }}

      - name: Restore cache
        uses: actions/cache@v4
        with:
          path: |
            _build
            ~/.cache/rebar3
          key: ${{ runner.os }}-otp${{ env.OTP_VERSION }}-${{ hashFiles('rebar.lock') }}
          restore-keys: |
            ${{ runner.os }}-otp${{ env.OTP_VERSION }}-

      - name: EUnit
        run: rebar3 eunit

      - name: Common Test
        run: rebar3 ct --verbose
```

- [ ] **Step 3: Add the analysis job**

Append the `analysis` job to the `jobs:` section of `.github/workflows/ci.yml`:

```yaml
  analysis:
    name: Analysis
    runs-on: ubuntu-24.04
    needs: build
    steps:
      - uses: actions/checkout@v4

      - name: Set up Erlang/OTP
        uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          rebar3-version: ${{ env.REBAR3_VERSION }}

      - name: Restore cache
        uses: actions/cache@v4
        with:
          path: |
            _build
            ~/.cache/rebar3
          key: ${{ runner.os }}-otp${{ env.OTP_VERSION }}-${{ hashFiles('rebar.lock') }}
          restore-keys: |
            ${{ runner.os }}-otp${{ env.OTP_VERSION }}-

      - name: Dialyzer
        run: rebar3 dialyzer

      - name: Xref
        run: rebar3 xref
```

- [ ] **Step 4: Validate the workflow file locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`

If `pyyaml` is not available, use: `cat .github/workflows/ci.yml | python3 -c "import sys,json; __import__('yaml').safe_load(sys.stdin)" 2>/dev/null || echo "Install pyyaml or verify YAML manually"`

Alternatively, verify with: `gh workflow list` after push (Task 3).

Expected: Valid YAML, no parse errors.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions workflow with build, test, analysis jobs

Three-job pipeline: build compiles and caches, test (eunit + ct) and
analysis (dialyzer + xref) run in parallel.

Refs #2"
```

---

## Task 2: Add CI Badge to README

**Files:**
- Modify: `README.md` (line 1 — add badge after title)

- [ ] **Step 1: Add the badge**

Insert on line 2 of `README.md`, immediately after `# Loom`:

```markdown
[![CI](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml/badge.svg)](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml)
```

Result:
```markdown
# Loom
[![CI](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml/badge.svg)](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml)

**Fault-tolerant inference orchestration, woven on BEAM.**
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add CI status badge to README

Refs #2"
```

---

## Task 3: Push and Verify CI Passes

- [ ] **Step 1: Push the feature branch**

```bash
git push -u origin feature/ci-pipeline
```

- [ ] **Step 2: Verify the workflow runs**

```bash
gh run list --branch feature/ci-pipeline --limit 5
```

Expected: A CI run appears with status `in_progress` or `completed`.

- [ ] **Step 3: Wait for CI and check results**

```bash
gh run watch --exit-status
```

Expected: All three jobs (`Build`, `Test`, `Analysis`) pass with green checkmarks.

If any job fails, inspect logs:
```bash
gh run view --log-failed
```

- [ ] **Step 4: Open PR**

```bash
gh pr create --title "P0-02: Add GitHub Actions CI pipeline" --body "$(cat <<'EOF'
## Summary

- Three-job CI pipeline: `build` → `test` + `analysis` (parallel)
- Build job: compiles with rebar3, caches `_build/` and deps
- Test job: runs `rebar3 eunit` and `rebar3 ct`
- Analysis job: runs `rebar3 dialyzer` and `rebar3 xref`
- CI badge added to README.md
- Triggered on push to `main` and all PRs (skips docs-only changes)

Fixes #2

## Test plan

- [ ] All three CI jobs pass on this PR
- [ ] Badge renders correctly on README
- [ ] Verify cache is populated (check build logs for cache hit/miss)
EOF
)"
```

---

## Task 4: Configure Branch Protection

**Note:** This must be done after the CI workflow has run at least once, so GitHub recognizes the check names.

- [ ] **Step 1: Configure branch protection on `main`**

```bash
gh api repos/mohansharma-me/loom/branches/main/protection \
  --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Build", "Test", "Analysis"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1
  },
  "restrictions": null
}
EOF
```

Expected: 200 OK response with the protection rule details.

- [ ] **Step 2: Verify protection is active**

```bash
gh api repos/mohansharma-me/loom/branches/main/protection/required_status_checks
```

Expected: JSON showing `"contexts": ["Build", "Test", "Analysis"]` and `"strict": true`.

---

## Task 5: Update ROADMAP.md

**Files:**
- Modify: `ROADMAP.md`

- [ ] **Step 1: Mark P0-02 as done in ROADMAP.md**

Change line 26:
```markdown
- [ ] Set up GitHub Actions CI (build, test, Dialyzer) — [#2](https://github.com/mohansharma-me/loom/issues/2) `P0-02`
```
To:
```markdown
- [x] Set up GitHub Actions CI (build, test, Dialyzer) — [#2](https://github.com/mohansharma-me/loom/issues/2) `P0-02`
```

Update the Progress Summary table — Phase 0 row:
```markdown
| Phase 0 | 15 | 2 | 0 | 13 |
```

Update the Total row:
```markdown
| **Total** | **50** | **2** | **0** | **48** |
```

Update "What's Next" — strike through #2:
```markdown
2. ~~**#2 — P0-02:** CI pipeline (enables quality gates early)~~ ✓
```

- [ ] **Step 2: Commit**

```bash
git add ROADMAP.md
git commit -m "docs: update ROADMAP.md for completed P0-02

Refs #2"
```

- [ ] **Step 3: Push and verify PR is updated**

```bash
git push
```
