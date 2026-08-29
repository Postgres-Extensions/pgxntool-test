# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## CI Monitoring After Every Push

**REQUIRED**: After every `git push`, immediately start a background task to
monitor the CI run for that push. If you pushed to both pgxntool and
pgxntool-test, start a background task for each repo — do not monitor them
sequentially.

Always use the `/ci` skill (`bash .claude/skills/ci/scripts/monitor-ci.sh`).
Pass the exact push SHA when available — `gh run list --branch` has a race
condition: if two pushes land close together on the same branch (e.g., two
Claude sessions pushing in parallel), `--branch` may pick up the wrong run.
`--commit SHA` targets the exact push and avoids this.

**After every monitor run, check the `=== BRANCHES: pgxntool=X
pgxntool-test=Y ===` line** to verify the right code is under test. If the
branches don't match what you pushed, cancel the run and re-trigger.

## Multiple Concurrent Sessions

It is common to have multiple Claude Code sessions open simultaneously across
pgxntool and pgxntool-test. To avoid cross-session interference:

**If you are asked to do something on an existing PR that you did not open or
are not already working on in this session, immediately ask for confirmation
before proceeding.** For example: "I see PR #21 exists. Were you asking me to
work on that, or did you mean to send this to a different session?"

This applies to: editing PR branches, pushing to them, closing/reopening them,
adding commits, modifying PR descriptions, or any other PR-level action.

## GitHub Issues: Repo Routing

Both pgxntool and pgxntool-test have GitHub issues enabled, and it's easy to
lose track of which repo an issue landed in. When opening an issue:

1. **Choose the right repo:**
   - Issues about pgxntool itself (the framework's behavior, Makefiles,
     scripts, docs it ships) go in **pgxntool**.
   - Issues about pgxntool-test's own development (test harness internals,
     BATS infrastructure, template maintenance) go in **pgxntool-test**.
   - Exception: important/critical test-related issues also go in
     **pgxntool** even though they're test-related, for visibility —
     don't let them sit only in pgxntool-test where they're easy to miss.
2. **Bold which repo the issue lives in** somewhere prominent in the issue
   body (e.g. a leading `**Repo: pgxntool**` or `**Repo: pgxntool-test**`
   line).

## Check Master Sync Before Branching

**Before creating a new branch or worktree** in either repo, fetch the
upstream remote and confirm local master isn't behind it — don't just check
`git status`/branch name, actually compare the SHAs:

```bash
git fetch upstream master --quiet
git rev-parse master upstream/master  # compare the two SHAs
```

If local master is behind, sync it before branching off it — don't branch
from a stale base. Branching from a stale master risks redoing work that's
already been fixed upstream.

This is separate from (and broader than) the `/release` skill's own
pre-flight sync check (Step 1) — that one only runs right before a release;
this applies to *any* new branch or worktree in either repo.

## Git Commit Guidelines

**CRITICAL**: Never attempt to commit changes on your own initiative. Always wait for explicit user instruction to commit. Even if you detect issues (like out-of-date files), inform the user and let them decide when to commit.

**IMPORTANT**: When creating commit messages, do not attribute commits to yourself (Claude). Commit messages should reflect the work being done without AI attribution in the message body. The standard Co-Authored-By trailer is acceptable.

## Maintainer-Gated Labels

**NEVER apply or remove the `commit-with-no-tests` label (or any similarly maintainer-gated label) on pgxntool PRs, even if the authenticated account has admin/write access that makes it technically possible.** `protect-label.yml` restricts this label to maintainers by design — having the technical ability to set it does not make it your call. If a PR looks like it genuinely needs no paired test PR, say so explicitly and let a human apply the label.

## Executable Bit Safety

`sed -i` (and similar in-place file-rewriting tools) can silently drop a file's executable bit -- this has caused real regressions in this repo (a script losing its `+x` bit cascaded into a wide swath of unrelated-looking test failures before the actual cause was found). After using `sed -i` or similar on any file, check `git diff --summary` for a `100755 => 100644` mode change and restore `chmod +x` before doing anything else with it.

## PR-Based Workflow: Merges Happen Outside AI Control

**This project uses a GitHub PR workflow, not direct commits to master.** The `/commit` skill's two-phase cross-reference process (commit pgxntool, capture its hash, commit pgxntool-test referencing it) was designed for an earlier direct-commit era and still applies to *composing a PR branch's own commits* before merge — but actually merging a PR happens via the GitHub website, by the user, outside AI control. Claude never commits directly to master and does not control when or how a PR lands, with one narrow, safety-gated exception: `crossref-audit`'s Step 4 may amend and force-push a single tip-of-master commit to add a missing cross-reference, under the specific conditions documented there (never more than one commit, never at or before the last release tag, content-diff verified empty before pushing).

Because of that, whether a paired PR's cross-reference actually made it onto master can only be verified *after the fact*, once both sides are already merged — see `crossref-audit` below.

### End of Each Round: Check for Missing Cross-References

**At the end of each round of work in pgxntool or pgxntool-test (not just once at session start — sessions here run long), and before rebasing any branch onto a fresh master fetch**, run the `crossref-audit` skill's script: `bash .claude/skills/crossref-audit/scripts/audit.sh <pgxntool-dir> <pgxntool-test-dir>`. It fetches both masters, caches the last-checked SHAs, and exits immediately with a one-line "nothing new" if neither has moved since the last clean check — so repeating it every round costs near-zero tokens in the common case. Only read further into the skill's rules if it reports something flagged; follow those rules exactly, especially around when it is and isn't safe to amend an already-merged commit.

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
The `/crossref-audit` skill lives in `.claude/skills/crossref-audit/` — audits master in both repos for paired commits missing a cross-reference to each other (see "PR-Based Workflow" above).
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

### User-Facing API Surface of pgxntool

This defines what counts as pgxntool's "public API" for the purposes of the
`/release` skill's API documentation review (`.claude/skills/release/SKILL.md`,
Step 2): the surface that must be kept in sync between the code and
`../pgxntool/README.asc`, and whose behavior changes must be called out in
`../pgxntool/HISTORY.asc`. It's a working definition, expected to evolve:
when something doesn't clearly fit, don't guess — raise it and update this
section once resolved.

1. **Make targets pgxntool defines**, including dev-helper targets like
   `list` and `print-%` (they exist specifically to help users introspect
   the Makefile). Excludes:
   - Targets pgxntool inherits from PGXS **unmodified** (`install`,
     `submake-*`, etc.) — but only to the extent they're genuinely
     unmodified. The moment pgxntool adds or changes a prerequisite,
     recipe body, or variable (e.g. `EXTRA_CLEAN`) on a PGXS-named target,
     that modification is IN SCOPE and must be tracked like any other API
     surface item — the underlying PGXS behavior pgxntool didn't touch
     stays out of scope, but pgxntool's own authored changes to a
     shared-name target don't get to hide behind "it's a PGXS target."
     This is settled policy: it has already caused two real misses when
     treated as excluded-by-name-alone — a stale README claim about
     `test`'s prerequisites, and `installcheck: install` (issue #79, a
     genuine ordering-bug fix to the PGXS-named `installcheck` target)
     nearly being waved through as "out of scope" during 2.3.0 release
     prep. Both should have been (and now are) tracked the same as any
     other API surface change.
   - Pure generated-file targets (`META.json`, `meta.mk`, `control.mk`) —
     build plumbing, not something a user intentionally runs.
   - Conditionally-defined helper targets that exist purely to support
     another target's lifecycle rather than being invoked directly (e.g.
     `clean-test-build`, which only runs as a hook off `clean`; the
     install-schedule file target that `installcheck` depends on). The
     primary target they support (e.g. `test-build` itself) remains in
     scope if it's meant to be invoked directly and is independently
     documented.
   - Finding these requires reading the actual source, not just running
     `make list` — conditionally-gated targets, pgxntool's own additions
     to PGXS-named targets, and anything else a discovery tool can't
     fully enumerate, only show up by inspecting
     `base.mk`/`control.mk.sh`/`meta.mk.sh` directly.
2. **Target prerequisites worth documenting by name** even when not
   invoked directly (e.g. `testdeps`), since extension authors may
   reference or override them.
3. **Variables prefixed `PGXNTOOL_` that are designed for override** —
   defaulted with `?=`, or normalized via the validate/override pattern in
   `lib.sh` (e.g. `pgxntool_validate_yesno`). Excludes pure internal
   plumbing — never meant to be set by users — which is named
   `_PGXNTOOL_...` instead (a leading underscore *before* the `PGXNTOOL_`
   prefix, not replacing it) specifically so the name itself signals "not
   part of the user-facing surface" while staying namespaced, rather than
   relying on this prose exclusion list to catch every case: e.g.
   `_PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT` (a seam that exists for
   pgxntool-test's own tests to stub, not for end users to set),
   `_PGXNTOOL_CONTROL_FILES`, `_PGXNTOOL_EXTENSIONS`,
   `_PGXNTOOL_INSTALL_SCHEDULE`, `_PGXNTOOL_BASE_MK_INCLUDED`. One
   deliberate exception: `PGXNTOOL_DIR` is equally pure internal plumbing
   but keeps the bare `PGXNTOOL_` prefix — it's been present since
   pgxntool's very first release and is referenced across `base.mk` plus
   four separate shell scripts, making it the highest-risk name in the
   whole framework to rename (see issue #87 discussion); carrying the
   misleading prefix is judged lower-risk than touching it.
4. **Scripts a user is realistically expected to invoke by hand**:
   `setup.sh`, `pgxntool-sync.sh`, `update-setup-files.sh`, and `pgtle.sh`
   (including its own CLI flags, not just the make targets that wrap it).
5. **`DEBUG` is a special case**: its existence may be documented (it's
   fine for users to know it exists), but the specific level numbers are
   an internal implementation detail, not a documented contract — changing
   them is not a behavior change that needs a `HISTORY.asc` entry.
   `DEBUG`'s absence from `README.asc`/`CLAUDE.md` documentation is NOT
   itself a finding — API-documentation review agents (used by the
   `/release` skill, see `.claude/skills/release/SKILL.md`) must not flag
   "`DEBUG` exists but isn't documented" as a gap, regardless of how many
   scripts reference it. This is the first entry in what should be treated
   as a general pattern: when a documentation gap is judged intentional
   rather than an oversight, record that decision here as a standing
   exception so later reviews don't re-flag and re-litigate the same
   question release after release — add new entries to this list rather
   than raising them fresh each time.
6. **`../pgxntool/CLAUDE.md` is in scope, not exempt as "doc-only."** Unlike
   ordinary dev-only documentation, this file ships into every consumer
   project via subtree and is written for AI agents working in *those*
   consumer repos — it's effectively part of pgxntool's product, the same
   way `README.asc` is. Treat substantive changes to it like changes to
   `README.asc`: they should be reviewed for accuracy, and if they describe
   a behavior change, call it out in `HISTORY.asc` too. (For other files
   that are genuinely just internal dev documentation with no bearing on
   consumer projects, doc-only changes don't need a `HISTORY.asc` entry.)
7. Everything else is internal by default unless there's a specific
   indication otherwise.

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

**Use template files to provide automatic coverage**: If a bug is triggered by specific file content (e.g., a trailing comment in a control file), add that content directly to the appropriate template file rather than writing test code to create it. This gives automatic coverage across all tests that use that template, without any new test code. Use a prominent comment in the template file explaining why the content must not be removed — e.g.:
```
default_version = '2.5.0' # DO NOT REMOVE: trailing comment exercises parse_control_file comment handling (issue #25)
```

**Combine simple sanity checks into a single `@test`**: BATS has per-test overhead (setup, teardown, process spawning). Avoid creating a dedicated `@test` for a single simple assertion. Instead, add the check inline into an existing related `@test`, or consolidate multiple simple one-liner checks into a single `@test "...: simple sanity checks"` block. Reserve dedicated `@test` blocks for checks that need their own setup/teardown or that test meaningfully distinct behaviors.

### Test Each Layer for What It Actually Owns, Not What Another Layer Already Covers

**General rule**: don't re-test behavior that's already established and owned somewhere else -- an underlying framework/dependency's own documented mechanics, or a different layer of pgxntool's own code. Only test that *pgxntool's own code* correctly wires into, configures, or triggers that other layer. This applies whether the "other layer" is a script pgxntool invokes, or an external build framework (PGXS) pgxntool builds on top of.

- **A script's own decision logic** (parsing, comparisons, what makes it succeed or fail) belongs in a test file that invokes the script directly -- no Make, no foundation environment, no Postgres. Exhaustive edge-case coverage belongs here, since it's cheap here.
- **An external framework's own established behavior** (e.g. PGXS's `clean`/`EXTRA_CLEAN` deletion mechanics) is that framework's responsibility, not pgxntool's to re-verify. What pgxntool IS responsible for is correctly *populating* the configuration PGXS consumes (e.g. `EXTRA_CLEAN` containing the right entry) and that the configuration genuinely *reaches* the mechanism it's supposed to configure (e.g. that entry actually appearing in the real `clean` recipe, not just in an isolated variable dump) -- not that PGXS then does the right thing with it, which is PGXS's own well-established behavior.
- **The Makefile's own responsibility**, in either case, is wiring: does the recipe invoke the right script/target with the right arguments/variables, does it run at the correct point relative to other targets, does disabling a feature actually skip invoking it, and does `make` correctly propagate the invoked script's exit status and output. None of this requires re-running the invoked code's real decision logic -- it should be verified with a stub standing in for the real script, a `make -n` dry-run, or both, so the Makefile-layer tests would pass or fail identically no matter what the real invoked code's internals did.

Concrete example 1 -- `check-stale-expected` (script: `../pgxntool/test/bin/check-stale-expected.sh`; recipe: `../pgxntool/base.mk`):
- `test/standard/check-stale-expected-script.bats` invokes the script directly against a bare scratch directory and owns all of the decision-logic coverage: orphan detection, the pg_regress `_N.out` alternate-file convention, the `test/build`/`test/build/expected` pair, the file-type sub-check, and argument validation.
- `test/standard/make-test.bats` owns only the Makefile-integration concerns: the `check-stale-expected: installcheck` ordering guarantee (via `make -n` dry-run), that the recipe passes the right positional args (also via dry-run), that `PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED=no` genuinely skips invoking the script (via a stub -- see below), that `make` correctly propagates a stub's exit status/output either way, and one real end-to-end `make test` failure on a stale file (needs actual pg_regress output to prove the ordering held in practice). It does **not** re-test orphan/alternate-file/file-type decision logic -- that would just be the same assertion running twice, once cheaply and once expensively.

Concrete example 2 -- `EXTRA_CLEAN`/PGXS (`test/standard/make-test.bats`): `make clean` actually deleting `test/results/` is PGXS's own `pg_regress_clean_files`/`EXTRA_CLEAN` mechanism at work -- established, external behavior pgxntool doesn't need to re-verify by creating a real directory, running `make clean`, and checking it's gone. What pgxntool owns is (a) `EXTRA_CLEAN` listing the right entry (`make print-EXTRA_CLEAN`) and (b) that entry actually percolating into the real `clean` recipe's command line (`make -n clean` dry-run) -- proving pgxntool's own wiring is correct without needing to invoke or verify PGXS's deletion mechanics at all.

#### Proving a Script Was/Wasn't Invoked (or That Its Result Was Propagated Correctly)

When a Makefile-layer test needs to prove a script genuinely was (or wasn't) called, or that its exit status/output was correctly bubbled up -- not just that a failure from it was tolerated, which is a materially weaker claim -- prefer a dedicated "which script path to run" make variable over faking out an entire directory tree, and stub the script rather than relying on its real behavior.

Concrete example: the `check-stale-expected` recipe in `../pgxntool/base.mk` invokes `$(_PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT)` (default `$(PGXNTOOL_DIR)/test/bin/check-stale-expected.sh`) instead of a hardcoded path. `make_stub_script` in `test/lib/helpers.bash` writes a throwaway stub (configurable exit code, stdout text, marker file) to prove either that the script was never invoked (`PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED=no` test) or that `make` correctly propagates the script's exit status/output (the dedicated propagation test) -- both in `test/standard/make-test.bats`, both pointing `_PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT` at the stub instead of touching `PGXNTOOL_DIR`.

This is deliberately narrower than overriding `PGXNTOOL_DIR` itself. `PGXNTOOL_DIR` is read by many unrelated targets (`META.json`, `control.mk`, `verify-results`, `pgtle.sh`, etc.), so faking it out wholesale to intercept one script would require a full copy of the real directory just to swap that one file -- expensive, and it defeats the purpose of the narrower variable. Reach for "add a dedicated variable, then stub just that seam" before reaching for a directory-level fake or an in-place edit of a live, shared checkout (e.g. temporarily `mv`-ing the real script aside).

**Why not a BATS-ecosystem mocking library (e.g. [bats-mock](https://github.com/grayhemp/bats-mock) and its forks)?** That library's actual mechanism is PATH-shadowing: it symlinks a wrapper (`binstub`) into a directory prepended to `PATH`, so any invocation of the command *by bare name* resolves to the wrapper instead, which records the call and compares it against an expected "stub plan" (`stub`/`unstub`). That's a solid, general convention -- but it only intercepts commands resolved via `PATH` lookup. `base.mk` invokes `check-stale-expected.sh` by an explicit path (`$(PGXNTOOL_DIR)/test/bin/check-stale-expected.sh`), which bypasses `PATH` entirely, so PATH-shadowing would not have intercepted this call without a larger change to how the recipe invokes the script. A dedicated "which path to invoke" make variable is the idiom that actually fits this codebase's invocation style -- and it isn't a one-off improvisation: `PG_CONFIG` and `ASCIIDOC` (see `../pgxntool/base.mk`) already establish the same "overridable path/binary variable" pattern for other externally-invoked tools, for the same reason. `make_stub_script` itself borrows bats-mock's underlying idea (a throwaway executable with configurable exit code/output, standing in for the real one) without adding a dependency, and is written generally enough to reuse for any future script invocation that's parameterized the same way -- it isn't specific to check-stale-expected.sh.

When adding a new script invocation that later tests might need to intercept, consider referencing it through its own overridable make variable from the start rather than a hardcoded path -- retrofitting testability later is more expensive than designing for it up front.

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