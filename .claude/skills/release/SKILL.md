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

---

## Step 1: Run Pre-flight Checks

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

## Step 2: Launch API Documentation Review Agents

Immediately after pre-flight passes, launch the review agents below via the
Agent tool, running in the background. This happens early so the review has
time to finish while Steps 3-4 (version number, confirming HISTORY.asc) are
worked through.

**Gate: do not proceed past Step 6 (Update HISTORY.asc and Commit) — i.e. do
not make any release-related change to git — until both sets of findings
below have been retrieved and inspected.** See Step 5.

Launch two independent review efforts. Each may be one agent or a small set
of agents if splitting the surface area (e.g. by file) makes sense; give
every agent concrete file paths, not a vague "review the code" instruction.

**A. Since-last-release review** (focus: what MUST be documented in
`HISTORY.asc`)

- Scope: commits in `../pgxntool` between the `release` tag and `HEAD`
  (`git log release..HEAD`, `git diff release..HEAD -- base.mk control.mk.sh
  setup.sh meta.mk.sh build_meta.sh pgxntool-sync.sh update-setup-files.sh
  run-test-build.sh verify-results-pgtap.sh lib.sh pgtle.sh`).
- For every change to a make target, make/environment variable, or
  user-facing script or flag in that diff, compare against:
  - `../pgxntool/HISTORY.asc` STABLE section — is the behavior change called
    out there?
  - `../pgxntool/README.asc` — if the change added, removed, renamed, or
    changed the default/semantics of a documented item, is README.asc
    updated to match?
- Report: (1) behavior changes in the diff not mentioned in the STABLE
  section, (2) API items added or removed by these commits but not reflected
  in README.asc.

**B. Comprehensive review** (focus: current-state drift, regardless of
history)

- Scope: everything documented under "== make targets" and any documented
  variables in `../pgxntool/README.asc`, compared against everything
  actually implemented in `base.mk`, `control.mk.sh`, `setup.sh`,
  `meta.mk.sh`, `build_meta.sh`, `pgxntool-sync.sh`, `update-setup-files.sh`,
  `run-test-build.sh`, `verify-results-pgtap.sh`, `lib.sh`, `pgtle.sh`.
- Report: (1) documented items no longer present in code, (2) code-level
  items (targets/variables/scripts) not documented in README.asc, (3)
  documented behavior that no longer matches the code (wrong defaults,
  wrong prerequisites, wrong descriptions).
- This review ignores git history entirely — it only compares the README
  against the code as they exist right now.

## Step 3: Determine Version Number

If VERSION was not provided as an argument, ask the user:

Use AskUserQuestion:
- Header: "Version"
- Question: "What version number should this release be?"
- Provide options based on current version in pgxntool's HISTORY.asc

**Then re-run pre-flight** with the chosen version to validate it:
```bash
.claude/skills/release/scripts/release-preflight.sh VERSION
```

## Step 4: Confirm HISTORY.asc

Read `../pgxntool/HISTORY.asc` and show the user what's in the STABLE section.

**If no STABLE section exists:**
- Warn: "No STABLE section found. No changes are documented for this release."
- Ask user if they want to continue using AskUserQuestion.

## Step 5: Inspect API Documentation Review Findings

Retrieve the results from both review efforts launched in Step 2 (wait for
them if they haven't finished). This is a hard gate: **do not proceed to
Step 6 until this step is complete** — Step 6 is the first release step
that changes git state, and the whole point of launching the reviews early
was to have their findings in hand before that happens.

For each finding:

- **Since-last-release findings (2A):** a behavior change without a STABLE
  entry MUST be fixed before continuing. Either add the missing entry to the
  STABLE section now (folded into Step 6's edit), or ask the user how they
  want it documented — do not release with an undocumented behavior change.
  API items added/removed by these commits but missing from README.asc must
  also be fixed (edit README.asc) before continuing.
- **Comprehensive findings (2B):** these may include pre-existing drift
  unrelated to this release. Show the findings to the user and ask whether
  to fix now (as part of this release), file as follow-up work, or dismiss
  as a false positive — don't silently fix or silently ignore them.

Summarize what was found and how each item was resolved before moving on.

## Step 6: Update HISTORY.asc and Commit

1. Edit `../pgxntool/HISTORY.asc`: Replace the `STABLE` heading with the version number

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

2. Commit:
   ```bash
   cd ../pgxntool && git commit -am "Stamp VERSION"
   ```

## Step 7: Tag and Push pgxntool

**CRITICAL: Push to the Postgres-Extensions remote, not to a fork.**

```bash
cd ../pgxntool
git tag VERSION
git push PGXNTOOL_UPSTREAM master
git push PGXNTOOL_UPSTREAM VERSION
```

## Step 8: Stamp, Tag, and Push pgxntool-test

**CRITICAL: Push to the Postgres-Extensions remote, not to a fork.**

Create a stamp commit to match pgxntool's, then tag and push:

```bash
cd ../pgxntool-test
git commit --allow-empty -m "Stamp VERSION"
git tag VERSION
git push PGXNTOOL_TEST_UPSTREAM master
git push PGXNTOOL_TEST_UPSTREAM VERSION
```

## Step 9: Update `release` Tag

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

## Step 10: Verify and Report

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
- If pgxntool push succeeded but pgxntool-test failed:
  - Note that pgxntool is already released
  - Provide commands to manually complete pgxntool-test release
- If failure during push:
  - Local state is complete, just need to retry push

**Common issues:**
- "Push rejected": Upstream has changes. Need to pull first.
- "Tag already exists": Version was already released. Choose different version.
- "Permission denied": Check GitHub permissions.
