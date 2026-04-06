# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commit Guidelines

**CRITICAL**: Never attempt to commit changes on your own initiative. Always wait for explicit user instruction to commit. Even if you detect issues (like out-of-date files), inform the user and let them decide when to commit.

**IMPORTANT**: When creating commit messages, do not attribute commits to yourself (Claude). Commit messages should reflect the work being done without AI attribution in the message body. The standard Co-Authored-By trailer is acceptable.

## Using Subagents

**CRITICAL**: Always use ALL available subagents. Subagents are domain experts that provide specialized knowledge and should be consulted for their areas of expertise.

Subagents are automatically discovered and loaded at session start from:
- `.claude/agents/*.md` - Specialized domain experts (invoked via Task tool)
- `.claude/skills/*/SKILL.md` - Skills with preprocessing scripts and guides (invoked via Skill tool)
- `.claude/commands/*.md` - Simple command handlers (invoked via Skill tool)

These subagents are already available in your context - you don't need to discover them. Just USE them whenever their expertise is relevant.

**Key principle**: If a subagent exists for a topic, USE IT. Don't try to answer questions or make decisions in that domain without consulting the expert subagent first.

**Important**: ANY backward-incompatible change to an API function we use MUST be treated as a version boundary. Consult the relevant subagent (e.g., pgtle for pg_tle API compatibility) to understand version boundaries correctly.

### Session Startup: Check for New Versions

**At the start of every session**: Invoke the pgtle subagent to check if there are any newer versions of pg_tle than what it has already analyzed. If new versions exist, the subagent should analyze them for API changes and update its knowledge of version boundaries.

## Claude Skills and Commands

The `/commit` skill lives in `.claude/skills/commit/` with a preprocessing script and format guide.
The `/test` skill lives in `.claude/skills/test/` with a TAP-parsing test runner.
Other commands (worktree, pr, pgxntool-update) remain in `.claude/commands/`.

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

## Running Skills and Scripts

**CRITICAL**: Always run skill scripts using relative paths from the repo root, never absolute paths. Absolute paths cause permission issues.

```bash
# CORRECT:
bash .claude/skills/test/scripts/run-tests.sh test-all

# WRONG:
bash /Users/.../pgxntool-test/.claude/skills/test/scripts/run-tests.sh test-all
```

Ensure your working directory is the pgxntool-test repo root before running skill scripts.

## Testing

**For all testing information, use the test subagent** (`.claude/agents/test.md`).

The test subagent is the authoritative source for:
- Test architecture and organization
- Running tests (`make test`, individual test files)
- Debugging test failures
- Writing new tests
- Environment variables and helper functions
- Critical rules (no parallel runs, no manual cleanup, etc.)

**CRITICAL**: Always use the `/test` skill to run tests. Never run `make test*` or `bats` directly.
The test skill parses output, tracks failures AND skips, and prevents dismissing problems.
Quick reference: `/test` runs `test-all`. `/test test/standard/doc.bats` runs one test.

**CRITICAL**: Tests CANNOT run in parallel. Never start a test run while another is in progress, even in background. The test skill enforces this with a lock file.

**CRITICAL**: Test failures are NEVER acceptable. Any test failure - whether from a smoke test, verification run, or full suite - must be reported to the user immediately. Never rationalize failures as "pre-existing", "expected on this branch", or "unrelated." If failures exist, work with the user to fix them or plan commit order to avoid them.

### State Modifications vs Tests

Don't create `@test` blocks that *only* exist to modify state for later tests. If code doesn't test any pgxntool behavior, it belongs in `setup_file()` or a helper function, not a `@test`.

Tests that legitimately validate behavior AND also modify state used by later tests are fine - add a comment noting which downstream tests depend on the modified state.

Note: "state modifications" here means changes to an already-initialized test environment (updating deps.sql, committing files, etc.) - distinct from BATS `setup_file()`/`setup()` which handle test harness initialization (loading environments, checking prerequisites).

**Why this matters:**
- A skipped or failed `@test` looks like a real test problem. If it's just a state modification that wasn't needed, it creates false alarms and makes it unclear whether real test coverage is missing.
- Pure state modifications can be freely restructured. But `@test` blocks that also test real behavior need careful treatment when modifying.

**Rules:**
1. **Pure state modifications** (git commits, sed edits, file creation solely to establish conditions for later tests): Move into `setup_file()` or helper functions. If they fail, they should ERROR (not skip), because downstream tests depend on them. Only create helper functions for code that's reused or complex enough to hurt readability inline.
2. **Tests that also modify state** (e.g., `make results` to test that command works, where the output is also used by later tests): Keep as `@test`. Add a comment noting what downstream tests depend on the state change.
3. **Never use `skip` for "already done" state modifications.** Make them idempotent with conditionals that simply don't re-run when unnecessary (no skip, no `@test`). Rebuilding state every time is too expensive, so reuse is important - but that logic belongs in non-test code.
4. **Abort early on environment setup failures.** Since we never commit with failing tests, it's better to abort the suite immediately when environment setup fails rather than continuing and collecting potentially many false failures. A failed state modification can invalidate all downstream tests, and the false failures just obscure the real problem.

### Template Design Principles

Tests should generally avoid making changes to template environments. Writing test code to modify the test environment is more complex than having the correct files in the template to begin with. Tests that depend on running `make test` inside a template should strongly consider having the template itself contain the necessary test SQL and expected output files.

Both of these are trade-offs: the goal is to reduce test code complexity.

## File Structure

```
pgxntool-test/
├── Makefile                  # Test orchestration
├── lib.sh                    # Utility functions
├── util.sh                   # Additional utilities
├── README.md                 # Requirements and usage
├── CLAUDE.md                 # This file - project guidance
├── template/                 # Template extension files for test repos
├── tests/                    # Test suite (see test subagent for details)
├── test/bats/                # BATS framework (git submodule)
├── .claude/                  # Claude subagents, skills, and commands
└── .envs/                    # Test environments (gitignored)
```

## Related Repositories

- **../pgxntool/** - The framework being tested
- **../pgxntool-test-template/** - The minimal extension used as test subject

## Template Requirements

**CRITICAL**: The template (`template/`) must always be in a **passing state**. This means:
- All SQL files must have correct matching expected output files
- `make test` in a fresh foundation repository must pass
- Template tests (test/build/, test/install/, test/sql/) must all produce correct output

**Why**: Tests leverage the template's known-good state to validate features. If the template starts broken, tests need extra setup commands to establish a working baseline, which makes tests slower and harder to understand.

## Shell Script Standards

**RULE**: Always use `#!/usr/bin/env bash`, never `#!/bin/bash`.

`/bin/bash` hardcodes the path and fails on systems where bash is elsewhere (some BSDs, NixOS, Homebrew on macOS). `#!/usr/bin/env bash` finds bash on `PATH` and works everywhere.

## General Guidelines

- You should never have to run `rm -rf .envs`; the test system should always know how to handle .envs
- Do not hard code things that can be determined in other ways. For example, if we need to do something to a subset of files, look for ways to list the files that meet the specification
- When documenting things avoid referring to the past, unless it's a major change. People generally don't need to know about what *was*, they only care about what we have now
- NEVER use `echo ""` to print a blank line; just use `echo` with no arguments
- Minimize commands in the test suite. Every `make` invocation and shell command slows down tests. Prefer `make -n` (dry-run) over full `make` when you only need to check target existence or dependencies. Combine related checks into single tests where natural. When multiple tests need the same state change (e.g., removing a directory), order them so the change happens once and subsequent tests ride on that state — don't remove/restore/remove again