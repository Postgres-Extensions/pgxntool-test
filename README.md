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

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and architecture documentation.
