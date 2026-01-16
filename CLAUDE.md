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

## Testing

**For all testing information, use the test subagent** (`.claude/agents/test.md`).

The test subagent is the authoritative source for:
- Test architecture and organization
- Running tests (`make test`, individual test files)
- Debugging test failures
- Writing new tests
- Environment variables and helper functions
- Critical rules (no parallel runs, no manual cleanup, etc.)

Quick reference: `make test` runs the full test suite.

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
├── .claude/                  # Claude subagents and commands
└── .envs/                    # Test environments (gitignored)
```

## Related Repositories

- **../pgxntool/** - The framework being tested
- **../pgxntool-test-template/** - The minimal extension used as test subject

## General Guidelines

- You should never have to run `rm -rf .envs`; the test system should always know how to handle .envs
- Do not hard code things that can be determined in other ways. For example, if we need to do something to a subset of files, look for ways to list the files that meet the specification
- When documenting things avoid referring to the past, unless it's a major change. People generally don't need to know about what *was*, they only care about what we have now
- NEVER use `echo ""` to print a blank line; just use `echo` with no arguments