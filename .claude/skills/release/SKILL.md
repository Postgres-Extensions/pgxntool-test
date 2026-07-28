---
name: release
description: |
  Create a release for pgxntool and pgxntool-test. Handles version tagging,
  HISTORY.asc updates, and pushing to the main Postgres-Extensions GitHub repos.

  Use when user says "release", "create release", "tag version", or "/release"
allowed-tools: Bash(.claude/skills/release/scripts/release-preflight.sh:*), Bash(git tag:*), Bash(git commit:*), Bash(git push:*), Bash(git checkout:*), Bash(git status:*), Bash(git log:*), Bash(git remote:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(git fetch:*), Bash(git diff:*), Read, Edit
---

# /release

Create a release for pgxntool and pgxntool-test.

**Usage:** `/release [VERSION]`

## Terminology

- **STABLE section**: The heading in `HISTORY.asc` where unreleased changes are documented. During a release, this heading is replaced with the version number. This has nothing to do with git branches.
- **UPSTREAM_REMOTE**: The local git remote pointing to the main project repos at `https://github.com/Postgres-Extensions/`. Releases must be pushed here -- never to a fork. The remote name varies; it is identified by URL pattern in the pre-flight script.
- **User-facing API surface**: what the review agents launched in
  [Launch API Documentation Review Agents](#launch-api-documentation-review-agents)
  treat as "the documented API" of pgxntool. The canonical, evolving
  definition lives in this repo's own `CLAUDE.md`, under "User-Facing API
  Surface of pgxntool" (not `../pgxntool/CLAUDE.md` — that file is
  user-facing docs for extension developers, not dev/audit tooling docs).
  Read that section fresh before launching those agents and give them its
  current text verbatim as their scope, since it's expected to change over
  time. When a reviewer hits a case that doesn't clearly fit, flag it for
  the user rather than guessing, and consider updating that section
  afterward.
- **Discovering make targets**: the definition's target list should be
  found with `make list` (a target pgxntool itself provides — see
  `base.mk`), not by grepping for target definitions, since pattern rules
  and generated targets are easy to miss that way. Run it from a scratch
  directory containing nothing but a `Makefile` with
  `include <path-to-pgxntool>/base.mk`. Two things to watch for:
  - The output includes harmless noise from make's own recursive-submake
    chatter (literal lines `Makefile`, `make[1]`, etc.) — filter these out,
    they aren't real targets.
  - Targets gated behind `ifeq`/`ifdef` conditionals that depend on files
    not present in a bare scratch directory (e.g. `test-build`,
    `clean-test-build`, which only appear when `test/build/*.sql` or
    `test/install/*.sql` exist) won't show up this way. Read `base.mk`
    directly for these rather than relying on `make list` alone.

## Process Notes

- **Steps below are headings, referenced by anchor link.** Earlier versions
  of this skill numbered each step and cross-referenced them as "Step 6",
  "Step 2", etc. That broke every time a step was inserted, removed, or
  reordered -- every reference elsewhere in the document had to be found
  and renumbered by hand, and it was easy to miss one. A later revision
  switched to bolding the step's heading text instead, which fixed the
  renumbering problem but was still just prose -- nothing stopped it from
  drifting out of sync with the actual heading, and it gave a human reading
  this on GitHub nothing to click. Steps are referenced by a real markdown
  link to the heading's anchor instead (`[Heading Text](#heading-text)`),
  which is both unambiguous (a stale link can be checked by clicking it)
  and clickable when this file is viewed on GitHub.
- **Parallelize independent work.** The steps below are written in the order
  they're normally reasoned about, but that doesn't mean everything has to
  run one at a time. Where two pieces of work don't depend on each other's
  output, hand them to separate subagents and let them run concurrently
  instead of sequentially -- e.g. the two review efforts in
  [Launch API Documentation Review Agents](#launch-api-documentation-review-agents)
  already run as parallel background agents, and
  [Tag and Push pgxntool](#tag-and-push-pgxntool) /
  [Stamp, Tag, and Push pgxntool-test](#stamp-tag-and-push-pgxntool-test)
  are two independent repos that can likewise run at the same time rather
  than one after the other. Anything that reads or depends on another
  step's output (e.g.
  [Sanity-Check bin/version Output](#sanity-check-binversion-output) needs
  the stamp from
  [Update HISTORY.asc and Commit](#update-historyasc-and-commit) to already
  exist) must still wait for that dependency first.

---

## Run Pre-flight Checks

Run the pre-flight script, passing VERSION if provided:

```bash
.claude/skills/release/scripts/release-preflight.sh [VERSION]
```

The script checks:
1. Upstream remotes exist (pointing to Postgres-Extensions)
2. Both working directories are clean
3. Both repos are on master
4. Local master is in sync with upstream
5. Version format is valid and tag doesn't already exist
6. HISTORY.asc has a STABLE section

**If the script exits with errors:** STOP and show the errors to the user.

**If there are warnings:** Show them and ask the user how to proceed.

**Extract remote names** from the script output (last section):
- `PGXNTOOL_UPSTREAM` - remote name for pgxntool (e.g., "upstream")
- `PGXNTOOL_TEST_UPSTREAM` - remote name for pgxntool-test (e.g., "upstream")

## Launch API Documentation Review Agents

Immediately after pre-flight passes, launch the review agents below via the
Agent tool, running in the background. This happens early so the review has
time to finish while
[Determine Version Number](#determine-version-number) and
[Confirm HISTORY.asc](#confirm-historyasc) (below) are worked through.

**Gate: do not proceed past
[Update HISTORY.asc and Commit](#update-historyasc-and-commit) — i.e. do not
make any release-related change to git — until both sets of findings below
have been retrieved and inspected.** See
[Inspect API Documentation Review Findings](#inspect-api-documentation-review-findings).

Launch two independent review efforts. Each may be one agent or a small set
of agents if splitting the surface area (e.g. by file) makes sense; give
every agent concrete file paths, not a vague "review the code" instruction.

**A. Since-last-release review** (focus: what MUST be documented in
`HISTORY.asc`)

- Scope: commits in `../pgxntool` between the `release` tag and `HEAD`
  (`git log release..HEAD`, `git diff release..HEAD`), restricted to changes
  that touch the user-facing API surface (see Terminology). **Commit
  titles are not a reliable filter** — a commit can touch API-surface
  behavior without saying so in its subject line. Always check the actual
  file-level diff, don't just scan `git log --oneline`.
- For every such change, compare against:
  - `../pgxntool/HISTORY.asc` STABLE section — is the behavior change called
    out there?
  - `../pgxntool/README.asc` — if the change added, removed, renamed, or
    changed the default/semantics of a documented item, is README.asc
    updated to match?
- Report: (1) behavior changes in the diff not mentioned in the STABLE
  section, (2) API items added or removed by these commits but not reflected
  in README.asc, (3) anything encountered that's ambiguously in/out of the
  user-facing API surface.

**B. Comprehensive review** (focus: current-state drift, regardless of
history)

- Scope: the full user-facing API surface (see Terminology) as it exists in
  `../pgxntool` right now, compared against everything documented in
  `../pgxntool/README.asc`.
- Report: (1) documented items no longer present in code, (2) code-level
  items in the user-facing API surface not documented in README.asc, (3)
  documented behavior that no longer matches the code (wrong defaults,
  wrong prerequisites, wrong descriptions), (4) anything encountered that's
  ambiguously in/out of the user-facing API surface.
- This review ignores git history entirely — it only compares the README
  against the code as they exist right now.

## Determine Version Number

If VERSION was not provided as an argument, ask the user:

Use AskUserQuestion:
- Header: "Version"
- Question: "What version number should this release be?"
- Provide options based on current version in pgxntool's HISTORY.asc

**Then re-run pre-flight** with the chosen version to validate it:
```bash
.claude/skills/release/scripts/release-preflight.sh VERSION
```

## Confirm HISTORY.asc

Read `../pgxntool/HISTORY.asc` and show the user what's in the STABLE section.

**If no STABLE section exists:**
- Warn: "No STABLE section found. No changes are documented for this release."
- Ask user if they want to continue using AskUserQuestion.

## Inspect API Documentation Review Findings

Retrieve the results from both review efforts launched in
[Launch API Documentation Review Agents](#launch-api-documentation-review-agents)
(wait for them if they haven't finished). This is a hard gate: **do not
proceed to
[Update HISTORY.asc and Commit](#update-historyasc-and-commit) until this
step is complete** — that's the first release step that changes git state,
and the whole point of launching the reviews early was to have their
findings in hand before that happens.

For each finding:

- **Since-last-release findings (review A):** a behavior change without a
  STABLE entry MUST be fixed before continuing. Either add the missing entry
  to the STABLE section now (folded into the HISTORY.asc edit below), or ask
  the user how they want it documented — do not release with an undocumented
  behavior change. API items added/removed by these commits but missing from
  README.asc must also be fixed (edit README.asc) before continuing.
- **Comprehensive findings (review B):** these may include pre-existing
  drift unrelated to this release. Show the findings to the user and ask
  whether to fix now (as part of this release), file as follow-up work, or
  dismiss as a false positive — don't silently fix or silently ignore them.
- **Ambiguous user-facing API surface calls (either agent):** show these to
  the user too. If a pattern recurs or the user gives a clear answer,
  consider updating the "User-facing API surface" definition in Terminology
  so future reviews don't re-flag it.

Summarize what was found and how each item was resolved before moving on.

## Update HISTORY.asc and Commit

### Reorder the STABLE section entries by importance

By this point (the gate in
[Inspect API Documentation Review Findings](#inspect-api-documentation-review-findings))
every entry this release needs is already in place. Before stamping, sort
those entries -- most important first -- into:

- Breaking changes -- anything that could break an existing consumer's
  build, tests, or behavior
- Non-breaking behavior changes -- existing behavior changed, but nothing
  should break as a result (expect this category to be rare)
- New features/additions -- new targets, variables, scripts, etc.
- Bugfixes

An entry that fits more than one category goes under the highest (earliest)
one that applies. This is a one-time pass over *this release's* entries
only -- it's not a standing order for HISTORY.asc as a whole, and older,
already-released sections are never touched. If an entry's category is
genuinely unclear, ask the user rather than guessing.

### Stamp the version

Edit `../pgxntool/HISTORY.asc`: replace the `STABLE` heading with the version number.

Replace:
```
STABLE
------
```
With:
```
VERSION
-------
```
(Adjust dashes to match version string length)

### Commit

```bash
cd ../pgxntool && git commit -am "Stamp VERSION"
```

## Sanity-Check bin/version Output

CI depends on `bin/version` (see `../pgxntool/bin/version`, also wired up as
`make pgxntool-version`) correctly reflecting whatever is actually on the
first line of `HISTORY.asc` -- that's what lets a release PR be caught in CI
if the stamp above didn't take effect the way it should have. Run it
directly against the just-stamped, unmodified `../pgxntool` checkout:

```bash
../pgxntool/bin/version
```

**The output must be exactly VERSION.** If it's `STABLE`, an old version, or
an error instead, the stamp in
[Update HISTORY.asc and Commit](#update-historyasc-and-commit) didn't take
effect correctly (or `bin/version` itself regressed). Stop and fix it -- do
not tag or push a release that doesn't agree with this.

## Tag and Push pgxntool

**CRITICAL: Push to the Postgres-Extensions remote, not to a fork.**

```bash
cd ../pgxntool
git tag VERSION
git push PGXNTOOL_UPSTREAM master
git push PGXNTOOL_UPSTREAM VERSION
```

## Stamp, Tag, and Push pgxntool-test

**CRITICAL: Push to the Postgres-Extensions remote, not to a fork.**

Create a stamp commit to match pgxntool's, then tag and push:

```bash
cd ../pgxntool-test
git commit --allow-empty -m "Stamp VERSION"
git tag VERSION
git push PGXNTOOL_TEST_UPSTREAM master
git push PGXNTOOL_TEST_UPSTREAM VERSION
```

This is independent of [Tag and Push pgxntool](#tag-and-push-pgxntool)
(separate repo, separate remote) — see
[Process Notes](#process-notes) above on running the two as parallel
subagents.

## Update the release Tag

Both repos have a `release` tag on upstream that must always point to the latest
release. This is a moving tag that requires force-push to update.

```bash
cd ../pgxntool
git tag -f release VERSION
git push PGXNTOOL_UPSTREAM -f refs/tags/release
```

```bash
cd ../pgxntool-test
git tag -f release VERSION
git push PGXNTOOL_TEST_UPSTREAM -f refs/tags/release
```

## Verify and Report

```bash
cd ../pgxntool && git checkout master
cd ../pgxntool-test && git checkout master
```

Output:

```
Release VERSION complete!

pgxntool:
- HISTORY.asc stamped with VERSION
- Tag VERSION created and pushed to PGXNTOOL_UPSTREAM
- release tag updated to VERSION

pgxntool-test:
- Stamp commit created
- Tag VERSION created and pushed to PGXNTOOL_TEST_UPSTREAM
- release tag updated to VERSION

Verify releases:
- https://github.com/Postgres-Extensions/pgxntool/releases/tag/VERSION
- https://github.com/Postgres-Extensions/pgxntool-test/releases/tag/VERSION
```

---

## Error Handling

**If any git operation fails:**
- Stop immediately
- Show the error
- Show current state of BOTH repos: `git status`, `git branch`, `git log -1`
- Provide recovery instructions
- Note which repo failed and what state the other repo is in

**Rollback guidance if partial failure:**
- If pgxntool push succeeded but pgxntool-test failed (or vice versa --
  if these ran as parallel subagents, either can fail independently of
  the other):
  - Note which repo already succeeded
  - Provide commands to manually complete the other repo's release
- If failure during push:
  - Local state is complete, just need to retry push

**Common issues:**
- "Push rejected": Upstream has changes. Need to pull first.
- "Tag already exists": Version was already released. Choose different version.
- "Permission denied": Check GitHub permissions.
