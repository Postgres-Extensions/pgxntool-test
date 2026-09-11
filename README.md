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

**The norm is that a change is paired across both repos** — it comes with a matching branch (same name, same account) in the other repo. This is effectively required for `pgxntool` changes: a pgxntool change should almost always have a corresponding pgxntool-test change, and CI blocks an unpaired pgxntool PR unless a maintainer applies the `commit-with-no-tests` label (see below). A pgxntool-test-only change (with no pgxntool counterpart) is the occasional exception — for example, improving test coverage or infrastructure — and CI runs it against `pgxntool` master. Neither repo should be changed in isolation as a matter of routine.

### PR conventions

A change normally touches both repos, so open a PR in **each repo from a branch with the same name, on the same GitHub account** (your fork). For example, if your feature branch is named `feature/add-pgtle-support`, push it to both your `pgxntool` and `pgxntool-test` forks and open a PR from each. **The branch name *and* the account must match** — CI pairs the two PRs using both. (The exception is a pgxntool-test-only change, which needs no pgxntool PR; see above.)

### How CI works

**When you open a PR in `pgxntool-test`:**
CI looks for a `pgxntool` branch with the same name **on your account** (the PR's head fork). If it exists, tests run against that branch; if not, they run against `pgxntool` master **from Postgres-Extensions**. Results appear directly on your pgxntool-test PR.

**When you open a PR in `pgxntool`:**
CI waits for the paired pgxntool-test PR (matched by branch name **and** account) to complete (polling for up to 20 minutes), then checks whether it passed. When a paired PR is found, pgxntool CI does not run tests itself — it relies entirely on the pgxntool-test CI results, avoiding duplicate work. When no paired PR is found, pgxntool's own test job runs the tests directly against pgxntool-test master instead (see below).

- **If a paired test PR is found and its CI passes**: pgxntool CI passes. There is no test duplication.
- **If no paired test PR is found**: the `check-test-pr` check still fails (see below), but pgxntool's test job also runs against pgxntool-test master regardless, so there's a real pass/fail signal to inform whether overriding the failed check is safe.

> **Fork contributors — security note:** CI only ever pairs branches within the **same account**. It will never match your fork's branch to a same-named branch on a different account (including Postgres-Extensions). When there is no paired branch, the *other* repo is always taken from **`Postgres-Extensions/master`** — never a fork's `master` — so a stale or modified fork `master` can't influence the run. `master` is the only ref ever taken cross-account.

### What to do when pgxntool CI fails with "No paired test PR found"

This failure means CI couldn't find an open pgxntool-test PR **from your account** with a matching branch name. The fix is almost always:

1. **Open a PR in pgxntool-test** from a branch with the **same name, on the same account (your fork)** as your pgxntool branch.
2. Re-run the failing CI check on your pgxntool PR (or push a new commit to trigger it).

**The branch name and account must match exactly.** If your pgxntool branch is `fix/parse-bug` on `your-account`, your pgxntool-test branch must also be `fix/parse-bug` on `your-account`.

### The `commit-with-no-tests` label

For pgxntool PRs that genuinely don't require any test changes (documentation fixes, comment updates, etc.), a maintainer can apply the `commit-with-no-tests` label. This tells CI to run tests against `pgxntool-test/master` directly.

**This is not a normal shortcut.** Most pgxntool changes touch behavior that tests must cover. This label is for the rare case where a pgxntool change is truly orthogonal to the test suite.

**This label is write-protected**: only maintainers with write access to the repository can add or remove it. If a non-maintainer applies it, an automated workflow removes it immediately and posts an explanation.

To request the label:
1. Open your pgxntool PR.
2. Leave a comment explaining why no test changes are needed.
3. A maintainer will review and apply the label if appropriate.

### Branch protection

pgxntool's `master` currently has no branch protection configured, so `check-test-pr` is not a technically-enforced merge gate — a maintainer can merge via GitHub regardless of whether it passed. It's process enforcement only: its failure is visible on the PR and signals that a pairing is missing or the paired tests failed, but nothing prevents merging past it.

## Development

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines and architecture documentation.
