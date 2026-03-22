# CLAUDE.md

Loom — Fault-tolerant inference orchestration on Erlang/OTP.
Repo: https://github.com/mohansharma-me/loom

## Rules (non-negotiable)

### 1. Surface All Assumptions

- **In conversation:** Include an `## Assumptions` section in every response that involves a decision or implementation.
- **In code:** Use `%% ASSUMPTION:` (Erlang) or `# ASSUMPTION:` (Python) comments.
- If an assumption turns out wrong, flag it immediately.

### 2. Keep ROADMAP.md Updated

- Mark `[x]` on completed items. Update the Progress Summary table.
- Add new items under the correct phase with a GitHub issue link.
- Roadmap updates go in the same commit/PR that completes the work.
- **Before opening a PR**, verify that `ROADMAP.md` has been updated if any roadmap item was completed. This is a blocking requirement — do not open the PR without it.

### 3. Use GitHub Issues for All Work

- Every task needs an issue before work starts. Create one if missing.
- PRs reference issues via `Fixes #N` or `Closes #N`.
- Do not close issues/PRs without explicit user approval.

### 4. Post Plans as Sub-Issues

- Every plan (design or implementation) MUST be tracked as a **sub-issue** on the target GitHub issue.
- Create up to two sub-issues per work issue:
  - **`Design Plan: <parent title>`** — design spec, architecture, decisions.
  - **`Implementation Plan: <parent title>`** — step-by-step execution plan.
- Plan content goes in `.github/plans/<issue-number>-<design|implementation>.md` in the repo.
- The sub-issue body contains a summary and links to the full spec file.
- Plan file updates are committed alongside the implementation work.
- **When a parent issue is closed**, close all its sub-issues (design plan, implementation plan) as well. GitHub does not auto-close sub-issues — you must close them explicitly.
- **Do NOT read `.github/plans/` during general codebase exploration.** Only read a plan file when the current task is scoped to its parent issue. When working on an issue, reading and updating its plan files is expected.

## Key Files

| File | Purpose |
|------|---------|
| `KNOWLEDGE.md` | **Read first.** Architecture, design decisions, component specs, BEAM/GPU boundary. |
| `ROADMAP.md` | **Source of truth for progress.** Phase-wise tracking with GitHub issue links. |
| `CONTRIBUTING.md` | PR workflow, branch naming (`feature/`, `fix/`, `docs/`). |
| `.github/pull_request_template.md` | Required PR template. |

## Workflow

1. Check/create GitHub issue
2. Create sub-issues for Design Plan and/or Implementation Plan (store in `.github/plans/`)
3. Branch from `main` (`feature/`, `fix/`, `docs/`)
4. Implement with `ASSUMPTION:` comments in code
5. Update `ROADMAP.md` if a roadmap item was completed
6. Commit referencing the issue, open PR with `Fixes #N`

## Constraints

- **Erlang only** — no Elixir. OTP conventions, `loom_` module prefix, behaviours.
- **Python adapters** are thin protocol wrappers only.
- **BEAM/GPU boundary is sacred** — orchestration in Erlang, computation delegated to engines via Port/gRPC protocol.
