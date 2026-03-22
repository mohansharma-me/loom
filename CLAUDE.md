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

### 3. Use GitHub Issues for All Work

- Every task needs an issue before work starts. Create one if missing.
- PRs reference issues via `Fixes #N` or `Closes #N`.
- Do not close issues/PRs without explicit user approval.

## Key Files

| File | Purpose |
|------|---------|
| `KNOWLEDGE.md` | **Read first.** Architecture, design decisions, component specs, BEAM/GPU boundary. |
| `ROADMAP.md` | **Source of truth for progress.** Phase-wise tracking with GitHub issue links. |
| `CONTRIBUTING.md` | PR workflow, branch naming (`feature/`, `fix/`, `docs/`). |
| `.github/pull_request_template.md` | Required PR template. |

## Workflow

1. Check/create GitHub issue
2. Branch from `main` (`feature/`, `fix/`, `docs/`)
3. Implement with `ASSUMPTION:` comments in code
4. Update `ROADMAP.md` if a roadmap item was completed
5. Commit referencing the issue, open PR with `Fixes #N`

## Constraints

- **Erlang only** — no Elixir. OTP conventions, `loom_` module prefix, behaviours.
- **Python adapters** are thin protocol wrappers only.
- **BEAM/GPU boundary is sacred** — orchestration in Erlang, computation delegated to engines via Port/gRPC protocol.
