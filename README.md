# pgxntool-test

Test harness for [pgxntool](https://github.com/decibel/pgxntool), a PostgreSQL extension build framework.

## Repository Structure

**IMPORTANT**: This repository must be cloned in the same directory as pgxntool, so that `../pgxntool` exists. The test harness expects this directory layout:

```
parent-directory/
├── pgxntool/          # The framework being tested
└── pgxntool-test/     # This repository (test harness)
```

The tests use relative paths to access pgxntool, so maintaining this structure is required.

## Requirements

- PostgreSQL with development headers
- rsync
- asciidoctor (for documentation tests)

BATS (Bash Automated Testing System) is included as a git submodule at `test/bats/`.

### PostgreSQL Configuration

Tests that require PostgreSQL assume a plain `psql` command works. Set the appropriate environment variables:

- `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD` (or use `~/.pgpass`)

If not set, `psql` uses defaults (Unix socket, database matching username). Tests skip if PostgreSQL is not accessible.

## Running Tests

```bash
# Run all tests
# Note: If git repo is dirty (uncommitted changes), automatically runs test-recursion
# instead to validate that test infrastructure changes don't break prerequisites/pollution detection
make test

# Test recursion and pollution detection with clean environment
# Runs one independent test which auto-runs foundation as prerequisite
# Useful for validating test infrastructure changes work correctly
make test-recursion

# Run individual test files (they auto-run prerequisites)
test/bats/bin/bats tests/01-meta.bats
test/bats/bin/bats tests/02-dist.bats
test/bats/bin/bats tests/test-doc.bats
# etc...
```

### Smart Test Execution

`make test` automatically detects if test code has uncommitted changes:

- **Clean repo**: Runs full test suite (all sequential and independent tests)
- **Dirty repo**: Runs `make test-recursion` FIRST, then runs full test suite

This is important because changes to test code (helpers.bash, test files, etc.) might break the prerequisite or pollution detection systems. Running test-recursion first exercises these systems by:
1. Starting with completely clean environments
2. Running an independent test that must auto-run foundation
3. Validating that recursion and pollution detection work correctly
4. If recursion is broken, we want to know immediately before running all tests

This catches infrastructure bugs early - if test-recursion fails, you know the test system itself is broken before wasting time running the full suite.

## How Tests Work

This test harness validates pgxntool by:
1. Creating a fresh git repo with extension files from `template/`
2. Adding pgxntool via git subtree
3. Running various pgxntool operations (setup, build, test, dist)
4. Validating the results

See [CLAUDE.md](CLAUDE.md) for detailed documentation.

## Test Organization

Tests are organized by filename pattern:

**Foundation Layer:**
- **foundation.bats** - Creates base TEST_REPO (git init + template files + pgxntool subtree + setup.sh)
- Run automatically by other tests, not directly

**Sequential Tests (Pattern: `[0-9][0-9]-*.bats`):**
- Run in numeric order, each building on previous test's work
- Examples: 00-validate-tests, 01-meta, 02-dist, 03-setup-final
- Share state in `test/.envs/sequential/` environment

**Independent Tests (Pattern: `test-*.bats`):**
- Each gets its own isolated environment
- Examples: test-dist-clean, test-doc, test-make-test, test-make-results
- Can test specific scenarios without affecting sequential state

Each test file automatically runs its prerequisites if needed, so they can be run individually or as a suite.

## CI and Contributing

### Why two repos?

`pgxntool` is the framework itself; `pgxntool-test` is the test harness for it. They are kept separate because `pgxntool` is embedded into extension projects via `git subtree` — you don't want test infrastructure polluting those projects. The CI is designed to coordinate changes across both repos.

A pgxntool change **should almost always have a corresponding test change** in pgxntool-test. Commits touching only pgxntool (with no test changes) should be rare. It is also normal and common to have commits that only touch pgxntool-test (e.g., improving test coverage) with no corresponding pgxntool change — as long as tests pass, that's fine.

### PR conventions

When your change requires modifications to both repos, open PRs in **both repos using the same branch name**. For example, if your feature branch is named `feature/add-pgtle-support`, create that branch in both `pgxntool` and `pgxntool-test`. **Branch names must match exactly** — the CI uses the branch name to find the paired PR.

### How CI works

**When you open a PR in `pgxntool-test`:**
CI checks whether `pgxntool` has a branch with the same name. If it does, tests run against that pgxntool branch. If not, tests run against `pgxntool/master`. Results appear directly on your pgxntool-test PR.

**When you open a PR in `pgxntool`:**
CI waits for the paired pgxntool-test PR's CI to complete (polling for up to 20 minutes), then checks whether it passed. pgxntool CI does not run tests itself — it relies entirely on the pgxntool-test CI results.

- **If a paired test PR is found and its CI passes**: pgxntool CI passes. There is no test duplication.
- **If no paired test PR is found**: pgxntool CI fails (see below).

### What to do when pgxntool CI fails with "No paired test PR found"

This failure means CI couldn't find an open PR in pgxntool-test with a matching branch name. The fix is almost always:

1. **Open a PR in pgxntool-test** from a branch with the **same name** as your pgxntool branch.
2. Re-run the failing CI check on your pgxntool PR (or push a new commit to trigger it).

**Branch names must match exactly.** If your pgxntool branch is `fix/parse-bug`, your pgxntool-test branch must also be `fix/parse-bug`.

### The `commit-with-no-tests` label

For pgxntool PRs that genuinely don't require any test changes (documentation fixes, comment updates, etc.), a maintainer can apply the `commit-with-no-tests` label. This tells CI to run tests against `pgxntool-test/master` directly.

**This is not a normal shortcut.** Most pgxntool changes touch behavior that tests must cover. This label is for the rare case where a pgxntool change is truly orthogonal to the test suite.

**This label is write-protected**: only maintainers with write access to the repository can add or remove it. If a non-maintainer applies it, an automated workflow removes it immediately and posts an explanation.

To request the label:
1. Open your pgxntool PR.
2. Leave a comment explaining why no test changes are needed.
3. A maintainer will review and apply the label if appropriate.

### Branch protection

The `check-test-pr` status check on pgxntool is a required check for merging to `master`. It only passes when either:
- A corresponding pgxntool-test PR exists (with a matching branch name) and its tests are **passing**, or
- A maintainer has applied the `commit-with-no-tests` label.

This ensures pgxntool changes cannot be merged without passing test coverage.

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and architecture documentation.
