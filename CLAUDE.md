# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commit Guidelines

**IMPORTANT**: When creating commit messages, do not attribute commits to yourself (Claude). Commit messages should reflect the work being done without AI attribution in the message body. The standard Co-Authored-By trailer is acceptable.

## What This Repo Is

**pgxntool-test** is the test harness for validating **../pgxntool/** (a PostgreSQL extension build framework).

This repo tests pgxntool by:
1. Cloning **../pgxntool-test-template/** (a minimal "dummy" extension with pgxntool embedded)
2. Running pgxntool operations (setup, build, test, dist, etc.)
3. Comparing outputs against expected results
4. Reporting differences

## The Three-Repository Pattern

- **../pgxntool/** - The framework being tested (embedded into extension projects via git subtree)
- **../pgxntool-test-template/** - A minimal PostgreSQL extension that serves as test subject
- **pgxntool-test/** (this repo) - The test harness that validates pgxntool's behavior

**Key insight**: pgxntool cannot be tested in isolation because it's designed to be embedded in other projects. So we clone a template project, inject pgxntool, and test the combination.

## How Tests Work

### Test Execution Flow

1. **make test** (or **make cont** to continue interrupted tests)
2. For each test in `tests/*`:
   - Sources `.env` (created by `make-temp.sh`)
   - Runs test script (bash)
   - Captures output to `results/*.out`
   - Compares to `expected/*.out`
   - Writes differences to `diffs/*.diff`
3. Reports success or shows failed test names

### Test Environment Setup

**make-temp.sh**:
- Creates temporary directory for test workspace
- Sets `TEST_DIR`, `TOPDIR`, `RESULT_DIR`
- Writes environment to `.env`

**lib.sh** (sourced by all tests):
- Configures `PGXNREPO` (defaults to `../pgxntool`)
- Configures `PGXNBRANCH` (defaults to `master`)
- Configures `TEST_TEMPLATE` (defaults to `../pgxntool-test-template`)
- Handles output redirection to log files
- Provides utilities: `out()`, `debug()`, `die()`, `check_log()`
- Special handling: if pgxntool repo is dirty and on correct branch, uses `rsync` instead of git subtree

### Test Sequence

Tests run in dependency order (see `Makefile`):
1. **test-clone** - Clone template repo into temp directory, set up fake remote, add pgxntool via git subtree
2. **test-setup** - Run `pgxntool/setup.sh`, verify it errors on dirty repo, commit results
3. **test-meta** - Verify META.json generation
4. **test-dist** - Test distribution packaging
5. **test-setup-final** - Final setup validation
6. **test-make-test** - Run `make test` in the cloned extension
7. **test-doc** - Verify documentation generation
8. **test-make-results** - Test `make results` (updating expected outputs)

## Common Commands

```bash
make test              # Clean temp environment and run all tests (no need for 'make clean' first)
make cont              # Continue running tests (skip cleanup)
make sync-expected     # Copy results/*.out to expected/ (after verifying correctness!)
make clean             # Remove temporary directories and results
make print-VARNAME     # Debug: print value of any make variable
```

**Note:** `make test` automatically runs `clean-temp` as a prerequisite, so there's no need to run `make clean` before testing.

## Test Development Workflow

When fixing a test or updating pgxntool:

1. **Make changes** in `../pgxntool/`
2. **Run tests**: `make test` (or `make cont` to skip cleanup)
3. **Examine failures**:
   - Check `diffs/*.diff` for differences
   - Review `results/*.out` for actual output
   - Compare with `expected/*.out` for expected output
4. **Debug**:
   - Set `LOG` environment variable to see verbose output
   - Tests redirect to log files (see lib.sh redirect mechanism)
   - Use `verboseout=1` for live output during test runs
5. **Update expectations** (only if changes are correct!): `make sync-expected`
6. **Commit** once tests pass

## File Structure

```
pgxntool-test/
├── Makefile              # Test orchestration
├── make-temp.sh          # Creates temp test environment
├── clean-temp.sh         # Cleans up temp environment
├── lib.sh                # Common utilities for all tests
├── util.sh               # Additional utilities
├── base_result.sed       # Sed script for normalizing outputs
├── tests/
│   ├── clone             # Test: Clone template and add pgxntool
│   ├── setup             # Test: Run setup.sh
│   ├── meta              # Test: META.json generation
│   ├── dist              # Test: Distribution packaging
│   ├── make-test         # Test: Run make test
│   ├── make-results      # Test: Run make results
│   └── doc               # Test: Documentation generation
├── expected/             # Expected test outputs
├── results/              # Actual test outputs (generated)
└── diffs/                # Differences between expected and actual (generated)
```

## Key Implementation Details

### Dynamic Test Discovery
- `TESTS` auto-discovered from `tests/*` directory
- Can override: `make test TESTS="clone setup meta"`
- Test targets: `test-%` depends on `diffs/%.diff`

### Output Normalization (result.sed)
- Strips temporary paths (`$TEST_DIR` → `@TEST_DIR@`)
- Normalizes git remotes/branches
- Removes PostgreSQL installation paths
- Handles version-specific differences (e.g., Postgres < 9.2)

### Smart pgxntool Injection
The `tests/clone` script has special logic:
- If `$PGXNREPO` is local and dirty (uncommitted changes)
- AND on the expected branch
- Then use `rsync` to copy files instead of `git subtree`
- This allows testing uncommitted pgxntool changes

### Environment Variables

From `.env` (created by make-temp.sh):
- `TOPDIR` - pgxntool-test repo root
- `TEST_DIR` - Temporary workspace
- `RESULT_DIR` - Where test outputs are written

From `lib.sh`:
- `PGXNREPO` - Location of pgxntool (default: `../pgxntool`)
- `PGXNBRANCH` - Branch to use (default: `master`)
- `TEST_TEMPLATE` - Template repo (default: `../pgxntool-test-template`)
- `TEST_REPO` - Cloned test project location (`$TEST_DIR/repo`)

## Debugging Tests

### Verbose Output
```bash
# Live output while tests run
verboseout=1 make test

# Keep temp directory for inspection
make test
# (temp dir path shown in output, inspect before next run)
```

### Single Test Execution
```bash
# Run just one test
make test-setup

# Or manually:
./make-temp.sh > .env
. .env
. lib.sh
./tests/setup
```

### Log File Inspection
Tests use file descriptors 8 & 9 to preserve original stdout/stderr while redirecting to log files. See `lib.sh` `redirect()` and `reset_redirect()` functions.

## Test Gotchas

1. **Temp Directory Cleanup**: `make test` always cleans temp; use `make cont` to preserve
2. **Git Chattiness**: Tests redirect git output to avoid cluttering logs (uses `2>&9` redirects)
3. **Postgres Version Differences**: `base_result.sed` handles version-specific output variations
4. **Path Sensitivity**: All paths in expected outputs use placeholders like `@TEST_DIR@`
5. **Fake Remote**: Tests create a fake git remote to prevent accidental pushes to real repos

## Related Repositories

- **../pgxntool/** - The framework being tested
- **../pgxntool-test-template/** - The minimal extension used as test subject
