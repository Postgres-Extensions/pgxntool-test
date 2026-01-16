# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commit Guidelines

**CRITICAL**: Never attempt to commit changes on your own initiative. Always wait for explicit user instruction to commit. Even if you detect issues (like out-of-date files), inform the user and let them decide when to commit.

**IMPORTANT**: When creating commit messages, do not attribute commits to yourself (Claude). Commit messages should reflect the work being done without AI attribution in the message body. The standard Co-Authored-By trailer is acceptable.

## Using Subagents

**CRITICAL**: Always use ALL available subagents. Subagents are domain experts that provide specialized knowledge and should be consulted for their areas of expertise.

Subagents are automatically discovered and loaded at session start from:
- `.claude/agents/*.md` - Specialized domain experts (invoked via Task tool)
- `.claude/commands/*.md` - Command/skill handlers (invoked via Skill tool)

These subagents are already available in your context - you don't need to discover them. Just USE them whenever their expertise is relevant.

**Key principle**: If a subagent exists for a topic, USE IT. Don't try to answer questions or make decisions in that domain without consulting the expert subagent first.

**Important**: ANY backward-incompatible change to an API function we use MUST be treated as a version boundary. Consult the relevant subagent (e.g., pgtle for pg_tle API compatibility) to understand version boundaries correctly.

### Session Startup: Check for New Versions

**At the start of every session**: Invoke the pgtle subagent to check if there are any newer versions of pg_tle than what it has already analyzed. If new versions exist, the subagent should analyze them for API changes and update its knowledge of version boundaries.

## Claude Commands

The `/commit` Claude Command lives in this repository (`.claude/commands/commit.md`). pgxntool no longer has its own copy.

## What This Repo Is

**pgxntool-test** is the test harness for validating **../pgxntool/** (a PostgreSQL extension build framework).

This repo tests pgxntool by:
1. Creating a fresh test repository (git init + copying extension files from **template/**)
2. Adding pgxntool via git subtree and running setup.sh
3. Running pgxntool operations (build, test, dist, etc.)
4. Validating results with semantic assertions
5. Reporting pass/fail

## The Two-Repository Pattern

- **../pgxntool/** - The framework being tested (embedded into extension projects via git subtree)
- **pgxntool-test/** (this repo) - The test harness that validates pgxntool's behavior

This repository contains template extension files in the `template/` directory which are used to create fresh test repositories.

**Key insight**: pgxntool cannot be tested in isolation because it's designed to be embedded in other projects. So we create a fresh repository with template extension files, add pgxntool via subtree, and test the combination.

### Important: pgxntool Directory Purity

**CRITICAL**: The `../pgxntool/` directory contains ONLY the tool itself - the files that get embedded into extension projects via `git subtree`. Be extremely careful about what files you add to pgxntool:

- ✅ **DO add**: Files that are part of the framework (Makefiles, scripts, templates, documentation for end users)
- ❌ **DO NOT add**: Development tools, test infrastructure, convenience scripts for pgxntool developers

**Why this matters**: When extension developers run `git subtree add`, they pull the entire pgxntool directory into their project. Any extraneous files (development scripts, testing tools, etc.) will pollute their repositories.

**Where to put development tools**:
- **pgxntool-test/** - Test infrastructure, BATS tests, test helpers, template extension files
- Your local environment - Convenience scripts that don't need to be in version control

### Critical: .gitattributes Belongs ONLY in pgxntool

**RULE**: This repository (pgxntool-test) should NEVER have a `.gitattributes` file.

**Why**:
- `.gitattributes` controls what gets included in `git archive` (used by `make dist`)
- Only pgxntool needs `.gitattributes` because it's the one being distributed
- pgxntool-test is a development/testing repo that never gets distributed
- Having `.gitattributes` here would be confusing and serve no purpose

**If you see `.gitattributes` in pgxntool-test**: Remove it immediately. It shouldn't exist here.

**Where it belongs**: `../pgxntool/.gitattributes` is the correct location - it controls what gets excluded from distributions when extension developers run `make dist`.

## How Tests Work

### Test System Architecture

Tests use BATS (Bash Automated Testing System) with semantic assertions that check specific behaviors rather than comparing text output.

**For detailed development guidance, see @tests/CLAUDE.md**

### Test Execution Flow

1. **make test** (or individual test like **make test-clone**)
2. Each .bats file:
   - Checks if prerequisites are met (e.g., TEST_REPO exists)
   - Auto-runs prerequisite tests if needed (smart dependencies)
   - Runs semantic assertions (not string comparisons)
   - Reports pass/fail per assertion
3. Sequential tests share same temp environment for speed
4. Non-sequential tests get isolated copies of completed sequential environment

### Test Environment Setup

Tests create isolated environments in `test/.envs/` directory:
- **Sequential environment**: Shared by 01-05 tests, built incrementally
- **Non-sequential environments**: Fresh copies for test-make-test, test-make-results, test-doc

**Environment variables** (from setup functions in tests/helpers.bash):
- `TOPDIR` - pgxntool-test repo root
- `TEST_DIR` - Environment-specific workspace (.envs/sequential/, .envs/doc/, etc.)
- `TEST_REPO` - Test project location (`$TEST_DIR/repo`)
- `PGXNREPO` - Location of pgxntool (defaults to `../pgxntool`)
- `PGXNBRANCH` - Branch to use (defaults to `master`)
- `TEST_TEMPLATE` - Template repo (defaults to `../pgxntool-test-template`)
- `PG_LOCATION` - PostgreSQL installation path

### Test Organization

Tests are organized by filename patterns:

**Foundation Layer:**
- **foundation.bats** - Creates base TEST_REPO (git init + copy template files + pgxntool subtree + setup.sh)

**Sequential Tests (Pattern: `[0-9][0-9]-*.bats`):**
- Run in numeric order, each building on previous test's work
- Examples: 00-validate-tests, 01-meta, 02-dist, 03-setup-final
- Share state in `test/.envs/sequential/` environment

**Independent Tests (Pattern: `test-*.bats`):**
- Each gets its own isolated environment
- Examples: test-dist-clean, test-doc, test-make-test, test-make-results
- Can test specific scenarios without affecting sequential state

## Common Commands

```bash
# Run all tests
# NOTE: If git repo is dirty (uncommitted changes), automatically runs make test-recursion
# instead to validate test infrastructure changes don't break prerequisites/pollution detection
make test

# Test recursion and pollution detection with clean environment
# Runs one independent test which auto-runs foundation as prerequisite
# Useful for validating test infrastructure changes work correctly
make test-recursion

# Run individual test files (they auto-run prerequisites if needed)
test/bats/bin/bats tests/foundation.bats
test/bats/bin/bats tests/01-meta.bats
test/bats/bin/bats tests/02-dist.bats
test/bats/bin/bats tests/03-setup-final.bats
```

### CRITICAL: Test Environment Isolation

**DO NOT run tests in parallel!** Test runs share the same `test/.envs/` directory and will clobber each other.

**Examples of what NOT to do:**
- Running `make test` while a test agent is running tests
- Running two separate test commands simultaneously
- Having the main thread run tests while a subagent is also running tests

**Why this matters:**
- Tests create and modify shared state in `test/.envs/sequential/`, `test/.envs/foundation/`, etc.
- Parallel test runs will corrupt each other's environments
- Results will be unpredictable and incorrect

**Safe approach:**
- Wait for any running tests to complete before starting new tests
- Use agents OR run tests directly, never both simultaneously
- If an agent is testing, wait for it to finish before running your own tests

### Smart Test Execution

`make test` automatically detects if test code has uncommitted changes:

- **Clean repo**: Runs full test suite (all sequential and independent tests)
- **Dirty repo**: Runs `make test-recursion` FIRST, then runs full test suite

This is critical because changes to test code (helpers.bash, test files, etc.) might break the prerequisite or pollution detection systems. Running test-recursion first exercises these systems by:
1. Starting with completely clean environments
2. Running an independent test that must auto-run foundation
3. Validating that recursion and pollution detection work correctly
4. If recursion is broken, we want to know immediately before running all tests

**Why this matters**: If you modify pollution detection or prerequisite logic and break it, you need to know immediately. Running the full test suite won't catch some bugs (like broken re-run detection) because tests run fresh. test-recursion specifically tests the recursion system itself.

**Why run it first**: If test infrastructure is broken, we want to fail fast and see the specific recursion failure, not wade through potentially hundreds of test failures caused by the broken infrastructure

## File Structure

```
pgxntool-test/
├── Makefile                  # Test orchestration
├── lib.sh                    # Utility functions (not used by tests)
├── util.sh                   # Additional utilities (not used by tests)
├── README.md                 # Requirements and usage
├── CLAUDE.md                 # This file - project guidance
├── tests/                    # Test suite
│   ├── helpers.bash          # Shared test utilities
│   ├── assertions.bash       # Assertion functions
│   ├── dist-files.bash       # Distribution validation functions
│   ├── dist-expected-files.txt # Expected distribution manifest
│   ├── foundation.bats       # Foundation test (creates base TEST_REPO)
│   ├── [0-9][0-9]-*.bats     # Sequential tests (run in numeric order)
│   │                         # Examples: 00-validate-tests, 01-meta, 02-dist, 03-setup-final
│   ├── test-*.bats           # Independent tests (isolated environments)
│   │                         # Examples: test-dist-clean, test-doc, test-make-test, test-make-results
│   ├── CLAUDE.md             # Detailed test development guidance
│   ├── README.md             # Test system documentation
│   ├── README.pids.md        # PID safety mechanism documentation
│   └── TODO.md               # Future improvements
├── test/bats/                # BATS framework (git submodule)
└── .envs/                    # Test environments (gitignored)
```

## Test System

### Architecture

**Test Types by Filename Pattern:**

1. **foundation.bats** - Creates base TEST_REPO that all other tests depend on
2. **[0-9][0-9]-*.bats** - Sequential tests that run in numeric order, building on previous test's work
3. **test-*.bats** - Independent tests with isolated environments

**Smart Prerequisites:**
Each test file declares its prerequisites and auto-runs them if needed:
- Sequential tests build on each other (e.g., 02-dist depends on 01-meta)
- Independent tests typically depend on foundation
- Tests check if required state exists before running
- Missing prerequisites are automatically run

**Benefits:**
- Run full suite: Fast - prerequisites already met, skips them
- Run individual test: Safe - auto-runs prerequisites
- No duplicate work in either case

**Example from a sequential test:**
```bash
setup_file() {
  setup_sequential_test "02-dist" "01-meta"
}
```

### Writing New Tests

1. Load helpers: `load helpers`
2. Declare prerequisites in `setup_file()`
3. Write semantic assertions (not string comparisons)
4. Use `skip` for conditional tests
5. Test standalone and as part of chain

**Example test:**
```bash
@test "setup.sh creates Makefile" {
  assert_file_exists "Makefile"
  grep -q "include pgxntool/base.mk" Makefile
}
```

## Test Development Workflow

When fixing a test or updating pgxntool:

1. **Make changes** in `../pgxntool/`
2. **Run tests**: `make test`
3. **Examine failures**: Read test output, check assertions
4. **Debug**:
   - Set `DEBUG` environment variable to see verbose output
   - Use `DEBUG=5` for maximum verbosity
5. **Commit** once tests pass

## Debugging Tests

### Verbose Output
```bash
# Debug output while tests run
DEBUG=2 make test

# Very verbose debug
DEBUG=5 test/bats/bin/bats tests/01-meta.bats
```

### Single Test Execution
```bash
# Run just one test
make test-setup

# Or directly with bats
test/bats/bin/bats tests/02-dist.bats
```

## Test Gotchas

1. **Environment Cleanup**: `make test` always cleans environments before starting
2. **Git Chattiness**: Tests suppress git output to keep results readable
3. **Fake Remote**: Tests create a fake git remote to prevent accidental pushes to real repos
4. **State Sharing**: Sequential tests (01-05) share state; non-sequential tests get fresh copies

## Related Repositories

- **../pgxntool/** - The framework being tested
- **../pgxntool-test-template/** - The minimal extension used as test subject
- You should never have to run rm -rf .envs; the test system should always know how to handle .envs
- do not hard code things that can be determined in other ways. For example, if we need to do something to a subset of files, look for ways to list the files that meet the specification
- when documenting things avoid refering to the past, unless it's a major change. People generally don't need to know about what *was*, they only care about what we have now
- NEVER use `echo ""` to print a blank line; just use `echo` with no arguments