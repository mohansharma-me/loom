# Contributing

Thank you for your interest in contributing! This project welcomes contributions from the community.

## How to Contribute

### 1. Fork & Clone

All contributions must come through **Pull Requests from forks**. Direct pushes to this repository are not accepted.

```bash
# Fork the repo on GitHub, then:
git clone https://github.com/mohansharma-me/loom.git
cd REPO_NAME
git remote add upstream https://github.com/mohansharma-me/loom.git
```

### 2. Create a Branch

Always create a feature branch from the latest `main`:

```bash
git checkout main
git pull upstream main
git checkout -b feature/your-feature-name
```

**Branch naming convention:**
- `feature/short-description` — for new features
- `fix/short-description` — for bug fixes
- `docs/short-description` — for documentation changes

### 3. Make Your Changes

- Follow existing code style and conventions
- Write meaningful commit messages
- Keep commits atomic — one logical change per commit
- Add or update tests for your changes

### 4. Submit a Pull Request

```bash
git push origin feature/your-feature-name
```

Then open a PR against the `main` branch of this repository.

**PR Requirements:**
- Fill out the PR template completely
- Link related issues using `Fixes #123` or `Closes #123`
- Ensure all CI checks pass
- Be responsive to review feedback

### 5. Review Process

- **All PRs require approval** from the repository maintainer before merging
- Review feedback will be provided within a reasonable timeframe
- Please be patient — this is a solo-maintained project
- If changes are requested, push additional commits to the same branch

## What We Accept

- Bug fixes with reproducible test cases
- Feature improvements that align with the project's direction
- Documentation improvements
- Performance improvements with benchmarks
- Test coverage improvements

## What We Generally Don't Accept

- Large refactors without prior discussion (open an issue first)
- Changes that break backward compatibility without discussion
- Unrelated changes bundled into a single PR
- PRs without tests (where applicable)

## Code of Conduct

Be respectful. Be constructive. Assume good intent.

## Questions?

If you're unsure about whether a contribution would be welcome, **open an issue first** to discuss it.
