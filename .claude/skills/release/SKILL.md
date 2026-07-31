---
name: release
description: |
  Create a release for pgxntool and pgxntool-test. Handles version tagging,
  HISTORY.asc updates, and pushing to the main Postgres-Extensions GitHub repos.

  Use when user says "release", "create release", "tag version", or "/release"
allowed-tools: Bash(.claude/skills/release/scripts/release-preflight.sh:*), Bash(git tag:*), Bash(git commit:*), Bash(git push:*), Bash(git checkout:*), Bash(git status:*), Bash(git log:*), Bash(git remote:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(git fetch:*), Bash(git diff:*), Bash(git merge:*), Bash(gh pr create:*), Bash(gh pr view:*), Bash(gh pr checks:*), Bash(gh pr close:*), Bash(gh run list:*), Bash(gh run view:*), Bash(grep:*), Bash(.claude/skills/ci/scripts/monitor-ci.sh:*), Read, Edit
---

# /release

Create a release for pgxntool and pgxntool-test.

**Usage:** `/release [VERSION]`

## Terminology

- **STABLE section**: The heading in `HISTORY.asc` where unreleased changes are documented. During a release, this heading is replaced with the version number. This has nothing to do with git branches.
- **UPSTREAM_REMOTE**: The local git remote pointing to the main project repos at `https://github.com/Postgres-Extensions/`. Releases must be pushed here -- never to a fork. The remote name varies; it is identified by URL pattern in the pre-flight script.
- **Release branch**: `release-VERSION` (e.g. `release-2.2.0`), created fresh
  off master in both repos once the version number is known (see
  [Determine Version Number](#determine-version-number)). The pgxntool
  stamp commit lands here, not on master directly -- see
  [Open Release Pull Requests](#open-release-pull-requests) for why. The
  pgxntool-test branch of the same name carries only an empty commit and
  its PR is **never merged** -- see the same section for why it still
  needs to exist.
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
  already run as parallel background agents, and the pgxntool /
  pgxntool-test halves of
  [Open Release Pull Requests](#open-release-pull-requests) and
  [Tag Both Repos](#tag-both-repos) are two independent repos that can
  likewise run at the same time rather than one after the other. Anything
  that reads or depends on another step's output (e.g.
  [Sanity-Check bin/version Output](#sanity-check-binversion-output) needs
  the stamp from
  [Update HISTORY.asc and Commit](#update-historyasc-and-commit) to already
  exist) must still wait for that dependency first.
- **This skill never merges the pgxntool release PR, and never applies the
  `commit-with-no-tests` label.** Both are explicit human actions -- see
  [Wait for CI, Then Hand Off for Review](#wait-for-ci-then-hand-off-for-review).
  The pgxntool-test PR is different again: it's never meant to be merged at
  all, by anyone -- see
  [Open Release Pull Requests](#open-release-pull-requests).
- **The commits in this skill don't need a separate per-commit confirmation
  gate.** Invoking `/release` at all is the user's explicit instruction to
  run this whole documented flow, commits included -- and none of those
  commits touch master directly; they land on `release-VERSION` and only
  reach master through a human-reviewed, human-merged PR (see
  [Open Release Pull Requests](#open-release-pull-requests)).

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

## Verify CI Runs test-all

This whole release process leans on pgxntool-test's own CI (triggered by the
companion PR in
[Open Release Pull Requests](#open-release-pull-requests)) to give the
release content real Postgres test coverage -- see that section for why.
That guarantee is only as good as `run-tests.yml` actually running the full
suite, and this has silently regressed before (it was found running only
`make test`, silently excluding everything in `test/extra/`). Check both the
workflow definition and a recent real run before trusting it -- don't rely
on the YAML alone.

**Check the workflow definition:**

```bash
grep -n "run: make" ../pgxntool-test/.github/workflows/run-tests.yml
```

The `Run tests` step must read `make test-all`. If it reads `make test` or
`make test-extra`, that's the same bug recurring -- stop and fix it (or
confirm someone already is) before continuing.

**Check a recent actual run agrees with the code.** `make test` and `make
test-extra` both print a `Tip: Use 'make test-extra' ... or 'make test-all'
for everything` banner before and after the suite; `make test-all` never
prints it. Pull the most recent successful CI run's logs and confirm that
banner is absent:

```bash
run_id=$(gh run list --repo Postgres-Extensions/pgxntool-test --workflow CI \
  --status success --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view "$run_id" --repo Postgres-Extensions/pgxntool-test --log \
  | grep -i "Use 'make test-extra'"
```

Any match means the actual run did NOT use `test-all`, regardless of what
the checked-in YAML says -- the workflow the runner executed and the
workflow on record can differ (e.g. `run-tests.yml` is a reusable workflow
pulled from a specific ref -- see its own `CROSS-REPO REUSABLE WORKFLOW`
comment in `../pgxntool/.github/workflows/ci.yml`). No match is a good sign
but confirm it's actually checking the right step's output, not silently
matching nothing due to a `gh` error.

**If either check fails:** STOP. This is a testing-infrastructure gap, not
something to route around release-by-release. Fix `run-tests.yml` (or hand
this off, e.g. to a dedicated follow-up PR/agent) and only continue the
release once both checks pass.

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

**If no STABLE section exists:** later,
[Stamp the version](#stamp-the-version) can only replace an existing
`STABLE` heading -- there's nothing to continue *to* without one, and
[Sanity-Check bin/version Output](#sanity-check-binversion-output) will
fail if it's missing. Ask the user (via AskUserQuestion) to pick one:
- Add a `STABLE` section to `HISTORY.asc` now (even if it ends up
  documenting nothing but a header for this release), then continue.
- Stop the release here.

Do not proceed to
[Inspect API Documentation Review Findings](#inspect-api-documentation-review-findings)
without a `STABLE` section actually in hand -- "continue" only means
something once one exists.

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
  STABLE entry means something already went wrong upstream of this release
  (it should have been documented when it merged) -- **always ask the user**
  how they want it documented; never silently write the entry yourself. Fold
  their answer into the STABLE section as part of the HISTORY.asc edit below.
  Do not release with an undocumented behavior change. The same goes for API
  items added/removed by these commits but missing from README.asc: ask, then
  edit README.asc, before continuing.
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

### Create the release branch

Both repos get a same-named branch (see **Release branch** in Terminology;
the empty pgxntool-test PR is strictly to trigger a CI run -- see
[Open Release Pull Requests](#open-release-pull-requests)).

```bash
cd ../pgxntool && git checkout -b release-VERSION
cd ../pgxntool-test && git checkout -b release-VERSION
```

### Reorder the STABLE section entries by importance

By this point (the gate in
[Inspect API Documentation Review Findings](#inspect-api-documentation-review-findings))
every entry this release needs is already in place. Before stamping, sort
those entries -- most important first -- into:

1. Breaking changes -- anything that could break an existing consumer's
   build, tests, or behavior
2. Non-breaking behavior changes -- existing behavior changed, but nothing
   should break as a result (expect this category to be rare)
3. New features/additions -- new targets, variables, scripts, etc.
4. Bugfixes

An entry that fits more than one category goes under the highest (earliest)
one that applies. This is a one-time pass over *this release's* entries
only -- it's not a standing order for HISTORY.asc as a whole, and older,
already-released sections are never touched. If an entry's category is
genuinely unclear, ask the user rather than guessing.

### Compile the complete fixed-issues line

Independent of the individual STABLE entries above (which only narrate
changes important enough to write up), compile one line listing *every*
pgxntool issue actually closed by a commit in `release..HEAD` -- including
issues covered by a change too minor to warrant its own STABLE entry (e.g.
a one-line internal fix nobody bothered to narrate). This also catches
issues GitHub's auto-close silently failed to close:

1. For every PR merged in `release..HEAD`, read its own
   `closingIssuesReferences` (`gh pr view <n> --json closingIssuesReferences`)
   -- GitHub's own parsed understanding of which issues that merge closes.
2. ALSO read the PR body directly for any other `Fixes #N` / `Closes #N` /
   `Resolves #N` mentions not already present in that field. **GitHub only
   recognizes the first issue in a single comma-separated line** like
   `Fixes #7, #14, #19` -- every issue after the first is silently dropped,
   with no error or warning. This is not hypothetical: 2.2.0 shipped with
   issues #14, #19, #50, and #53 all genuinely fixed by one PR whose body
   read `Fixes #7, #14, #19, #28, #50, #53` -- only #7 auto-closed, and the
   other four sat open on GitHub until caught by a manual post-release audit.
3. Union both sources per PR, then union across all PRs in the release.

Append the result as a single line at the end of the STABLE section (after
the last `==` entry, before the next version's heading), e.g.:

```text
Issues fixed in this release: #7, #14, #19, #28, #46, #50, #53, #54, #57, #62, #65
```

**Then check each listed issue's actual state on GitHub.** Any still open
despite being genuinely fixed didn't actually auto-close -- close it now
with a comment linking to the fixing PR, rather than deferring it to a
later audit. Apply the same check to any pgxntool-test issue a paired PR's
body referenced.

### Stamp the version

Edit `../pgxntool/HISTORY.asc`: replace the `STABLE` heading with the version number.

Replace:

```text
STABLE
------
```

With:

```text
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
not open a release PR that doesn't agree with this.

## Open Release Pull Requests

**Never commit or push straight to master.** pgxntool's CI only triggers on
`pull_request` -- a direct push to master's `master` branch (which earlier
versions of this skill did) never runs CI at all, silently skipping every
check this repo relies on. Instead, push the release branch and open a PR
in each repo, same as any other change.

**Why pgxntool-test needs a PR too, even though it has nothing to stamp.**
pgxntool's release PR is doc-only (`HISTORY.asc`/`README.asc`/`README.html`
only), and pgxntool's `check-test-pr` job skips the actual Postgres test
matrix *unconditionally* for a doc-only PR -- no fallback to testing against
master, regardless of whether a paired pgxntool-test PR exists. So without
a companion PR, the real content of this release would get **zero** CI test
coverage before it merges. What actually provides that coverage: an empty
commit is *not* doc-only by pgxntool-test's own check (zero changed files
trips a different guard), so its `test` job runs and resolves the paired
pgxntool branch (`release-VERSION`, matched by name+account) -- exercising
the real Postgres suite against the actual release content, just via
pgxntool-test's CI instead of pgxntool's.

**This means the pgxntool-test PR exists purely to trigger that test run --
it must never be merged.** It changes nothing pgxntool-test actually wants
on its master. Say so explicitly in the PR itself so nobody merges it by
habit. Closing it is not an automatic action just because its CI went
green -- point the user at the CI run and wait for their explicit
go-ahead, same as merging pgxntool's PR is a human action, not this
skill's -- see
[Wait for CI, Then Hand Off for Review](#wait-for-ci-then-hand-off-for-review).

(Push order between the two repos doesn't matter for pgxntool's own
`check-test-pr` gate -- it checks doc-only status purely from this PR's own
changed-file list, with no cross-repo lookup, before it would ever look for
a pairing. That pairing-search race is a real, general latent issue in
`check-test-pr` for any paired PR, but this skill doesn't depend on it
succeeding either way.)

Push both branches directly to the Postgres-Extensions remotes, never a
fork, and open both PRs -- these can run as parallel subagents (see Process
Notes):

```bash
cd ../pgxntool-test
git commit --allow-empty -m "Stamp VERSION"
git push PGXNTOOL_TEST_UPSTREAM release-VERSION
gh pr create --repo Postgres-Extensions/pgxntool-test \
  --base master --head release-VERSION \
  --title "DO NOT MERGE: Release VERSION (CI trigger only)" \
  --body "This PR exists only to trigger a real CI test run of the paired \
pgxntool release-VERSION branch -- pgxntool's own release PR is doc-only \
and skips the Postgres test matrix entirely. It changes nothing in \
pgxntool-test (empty commit) and must NOT be merged. Close it once its CI \
is green."
```

```bash
cd ../pgxntool
git push PGXNTOOL_UPSTREAM release-VERSION
gh pr create --repo Postgres-Extensions/pgxntool \
  --base master --head release-VERSION \
  --title "Release VERSION" \
  --body "Stamps HISTORY.asc for VERSION. Companion (do-not-merge, CI trigger only): pgxntool-test release-VERSION."
```

Per this project's CI-monitoring rule, immediately start a background
monitor for each push (exact SHA, not `--branch`, to avoid a race with any
other concurrent push on this branch name -- one monitor per repo, not run
sequentially):

```bash
bash .claude/skills/ci/scripts/monitor-ci.sh pgxntool-test release-VERSION <pgxntool-test-sha> ""
```

```bash
bash .claude/skills/ci/scripts/monitor-ci.sh pgxntool release-VERSION "" <pgxntool-sha>
```

## Wait for CI, Then Hand Off for Review

Wait for the results from the two `monitor-ci.sh` background runs started in
[Open Release Pull Requests](#open-release-pull-requests). The pgxntool-test
run is where the *actual* Postgres test coverage of this release lives (see
[Open Release Pull Requests](#open-release-pull-requests)) -- pgxntool's own
run will just show its test job skipped as doc-only, which is expected, not
a problem. This skill does not merge the pgxntool PR, does not merge or
close the pgxntool-test PR, and does not apply any label -- all explicit
human actions. Report to the user:

- Both PR URLs
- CI status for each

**If pgxntool-test's CI fails:** this is a real failure of the actual
release content (see above) -- treat it the same as any other CI failure
needing investigation, not a formality.

**If pgxntool's `check-test-pr` job fails** (shouldn't happen for a
doc-only release diff -- see
[Open Release Pull Requests](#open-release-pull-requests) -- but isn't
impossible, e.g. if this release ends up needing a non-doc file change):
tell the user a maintainer needs to apply the `commit-with-no-tests` label
to the pgxntool PR themselves. **This skill must never apply that label --
it's maintainer-gated.**

**Then stop and wait.** Do not proceed to
[Tag Both Repos](#tag-both-repos) until the user confirms: pgxntool's
release PR is merged, and pgxntool-test's CI-trigger PR's CI passed (that
one is never merged -- see
[Open Release Pull Requests](#open-release-pull-requests)).

## Tag Both Repos

Only after the user has confirmed pgxntool's release PR is merged and
pgxntool-test's CI-trigger PR passed CI (see
[Wait for CI, Then Hand Off for Review](#wait-for-ci-then-hand-off-for-review)).
pgxntool's tag must point at whatever actually landed on master -- not the
pre-merge branch tip, which may differ if the PR was squashed or rebased on
merge. pgxntool-test's master never changed (its PR is never merged -- see
[Open Release Pull Requests](#open-release-pull-requests)), so its tag just
goes on current master directly.

This step rebases local state onto a freshly fetched master in both repos,
so per this repo's CLAUDE.md, run the cross-reference audit first:

```bash
bash .claude/skills/crossref-audit/scripts/audit.sh ../pgxntool .
```

Follow its output if it flags anything; only continue once it's clean.

```bash
cd ../pgxntool
git fetch PGXNTOOL_UPSTREAM master
git checkout master
git merge --ff-only PGXNTOOL_UPSTREAM/master
head -n1 HISTORY.asc   # must read exactly VERSION -- stop if it doesn't
git tag VERSION
git push PGXNTOOL_UPSTREAM VERSION
```

```bash
cd ../pgxntool-test
git fetch PGXNTOOL_TEST_UPSTREAM master
git checkout master
git merge --ff-only PGXNTOOL_TEST_UPSTREAM/master
git tag VERSION
git push PGXNTOOL_TEST_UPSTREAM VERSION
```

The `head -n1 HISTORY.asc` check exists because a squash/rebase merge can
alter file content in ways a pre-merge check never saw -- confirm the merged
result, not just the pre-merge branch, agrees with VERSION before tagging.
pgxntool-test's fetch+merge here isn't rebasing onto new content (nothing
merged there) -- it's just confirming local master hasn't drifted from
upstream before tagging it.

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

pgxntool is already on master with the release branch merged in (see
[Tag Both Repos](#tag-both-repos)); delete its now-merged local release
branch.

pgxntool-test's release branch was never merged (see
[Open Release Pull Requests](#open-release-pull-requests)). Before closing
its CI-trigger PR, point the user at its CI run and ask them to confirm
it's OK to close as part of finishing the release -- this is a distinct
confirmation from the CI-passed check in
[Wait for CI, Then Hand Off for Review](#wait-for-ci-then-hand-off-for-review),
not implied by it. Once confirmed, close it and delete the branch on both
ends:

```bash
cd ../pgxntool && git branch -d release-VERSION
cd ../pgxntool-test
gh pr close --repo Postgres-Extensions/pgxntool-test --delete-branch release-VERSION
```

`--delete-branch` removes the remote `release-VERSION` ref; delete the
local one too if it's still checked out elsewhere:

```bash
cd ../pgxntool-test && git branch -D release-VERSION
```

Output:

```text
Release VERSION complete!

pgxntool:
- HISTORY.asc stamped with VERSION
- Release PR merged, tag VERSION created and pushed to PGXNTOOL_UPSTREAM
- release tag updated to VERSION

pgxntool-test:
- CI-trigger PR closed without merging (never landed anything)
- Tag VERSION created directly on master and pushed to PGXNTOOL_TEST_UPSTREAM
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

**If a release PR's CI fails:** fix the problem on the `release-VERSION`
branch and push again (`git commit --amend` or a follow-up commit) -- do not
close it and open a new PR, and do not fall back to pushing straight to
master. Immediately re-run `monitor-ci.sh` for that push, same as in
[Open Release Pull Requests](#open-release-pull-requests).

**Rollback guidance if partial failure:**
- If pgxntool's PR is merged but pgxntool-test's CI-trigger PR hasn't gone
  green yet (or vice versa): expected with a manual hand-off, not a failure
  -- wait for both conditions before running
  [Tag Both Repos](#tag-both-repos). Don't tag one repo without the other.
- If pushing the release branch itself fails: local state is complete, just
  need to retry the push.

**Common issues:**
- "Push rejected": Upstream has changes. Need to pull first.
- "Tag already exists": Version was already released. Choose different version.
- "Permission denied": Check GitHub permissions.
