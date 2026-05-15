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

`pgxntool` is the framework itself; `pgxntool-test` is the test harness for it. They are kept separate so the test harness can be used as a git subtree in other projects. This means a change to either repo may require a corresponding change in the other, and the CI is designed to handle this.

### PR conventions

When your change requires modifications to both repos, open PRs in **both repos using the same branch name**. For example, if your feature branch is named `feature/add-pgtle-support`, create that branch in both `pgxntool` and `pgxntool-test`. The CI uses the branch name to automatically find the corresponding PR in the other repo.

If your change only affects one repo (e.g., a docs fix in pgxntool-test that doesn't require any pgxntool changes), see [the `no-test-pr` label](#the-no-test-pr-label) below.

### How CI works

**When you open a PR in `pgxntool-test`:**
CI checks whether `pgxntool` has a branch with the same name. If it does, tests run against that branch. If not, tests run against `pgxntool/master`. Results appear on your pgxntool-test PR.

**When you open a PR in `pgxntool`:**
CI searches for an open PR in `pgxntool-test` with the same branch name and waits up to 5 minutes for one to appear (in case you open the second PR shortly after). If a matching test PR is found, CI waits for its checks to pass before running the pgxntool tests against it. Results appear on your pgxntool PR.

If no matching test PR appears within 5 minutes and the PR does not have the `no-test-pr` label, the CI check fails and the PR cannot be merged. This is intentional — it ensures test coverage for pgxntool changes.

### The `no-test-pr` label

For pgxntool PRs that genuinely don't require any test changes (e.g., documentation updates, comment fixes), a maintainer can apply the `no-test-pr` label to the PR. This tells CI to skip waiting for a test PR and run against `pgxntool-test/master` instead.

**This label is write-protected**: only maintainers with write access to the repository can add or remove it. If you add the label yourself, an automated workflow will remove it and explain why. Ask a maintainer to apply it if you believe your PR doesn't need test changes.

To get the label applied:
1. Open your pgxntool PR as normal.
2. Leave a comment asking a maintainer to apply `no-test-pr` and explain why no test changes are needed.
3. A maintainer will review and apply the label if appropriate.

### Branch protection

The `resolve-test-ref` status check on pgxntool is a required check for merging to `master`. It only passes when either:
- A corresponding pgxntool-test PR CI has passed, or
- A maintainer has applied the `no-test-pr` label.

This means you cannot merge a pgxntool PR without test coverage, even accidentally.

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and architecture documentation.
