---
name: pr
description: Create pull requests for pgxntool changes
---

# /pr Claude Command

Create pull requests for pgxntool and pgxntool-test changes, following the two-repo workflow.

**Note:** This is a Claude Command (invoked with `/pr`), part of the Claude Code integration.

**CRITICAL WORKFLOW:**

1. **Check both repositories** - Always check git status in both pgxntool and pgxntool-test

2. **Only create PRs for repos with changes** - Never create a branch or PR for a repo that has no changes. It's normal for only one repo to have changes.

3. **Create PRs in correct order** - If both have changes: pgxntool first, then pgxntool-test

3. **Always target main repositories:**
   - pgxntool: `--repo Postgres-Extensions/pgxntool`
   - pgxntool-test: `--repo Postgres-Extensions/pgxntool-test`
   - **NEVER** target fork (jnasbyupgrade)

4. **Cross-reference PRs by URL, never by commit hash:**
   - pgxntool-test PR: "Related pgxntool PR: [URL]"
   - After creating test PR: Update pgxntool PR to add "Related pgxntool-test PR: [URL]"
   - Single-repo PR: "Changes only in [repo]. No related changes in [other repo]."
   - Put these lines after the opening paragraph, not first: the opening has to work standalone as the squash commit message (`../ai/PR.md` "PR descriptions").
   - **Always use full URLs** (cross-repo #number doesn't work)

5. **Before pushing or creating a PR, run `/test`** and proceed only on `PASS` with zero skips (CLAUDE.md "Testing").

---

## PR Title Rules

**CRITICAL: The title must contain only the most essential info about the change.**

- **Never include the pgxntool PR number in a pgxntool-test PR title.** Cross-references belong in the body, not the title. The title should stand alone and describe the change itself.
- Bad: `"Add tests for pgxntool PR #31 (fix results ordering, whitespace, overrides)"`
- Good: `"Fix results ordering, control file whitespace, ENABLE_* overrides"`

## Closing GitHub Issues (CRITICAL)

When a PR fixes one or more issues, give each its own `Fixes #N` / `Closes
#N` / `Resolves #N` line in the PR body -- never combine them into a single
comma-separated list like `Fixes #7, #14, #19`. **GitHub's auto-close only
recognizes the first issue number in that pattern and silently drops every
issue after it, with no error or warning.** This caused real drift in the
2.2.0 release: one PR's `Fixes #7, #14, #19, #28, #50, #53` line only
auto-closed #7 -- the other four issues were genuinely fixed but stayed
open on GitHub until a manual post-release audit caught it.

## HISTORY.asc (pgxntool PRs only)

Read `../pgxntool/HISTORY.asc` and handle two separate things:

1. **Entry**, only for significant user-visible changes (new features, behavior changes, bug fixes users would notice; not refactoring, test changes, cleanup, or doc fixes). Propose the entry in AsciiDoc (`==` heading) and get confirmation before adding it to the `STABLE` section at the top of the file (create the section if missing):
   ```
   STABLE
   ------
   == [Entry heading]
   [Entry description]
   ```
2. **Fixed-issues line**, always: every pgxntool issue in the PR's `Fixes #N` / `Closes #N` / `Resolves #N` set goes on `Issues fixed in this release: #7, #14, #19`, the last line of the `STABLE` section, even when the change is too minor for an entry. Create the line if missing; keep it deduped and in ascending order. pgxntool issues only; pgxntool-test has no equivalent. Re-check it whenever a push to an open PR changes that set.

## Debug Levels (pgxntool `.sh` changes only)

For each changed `../pgxntool/*.sh` file, flag it if it contains loops (`for`, `while`) and every `debug N` call uses a single-digit level, or if it has 5+ `debug` calls all at the same level. Advisory only: present findings and let the user decide; say nothing when nothing is flagged.

## PR Description Guidelines

**Think: "Someone in 2 years reading this in the commit log - what do they need to know?"**

**Key principle:** Be specific about outcomes. Avoid vague claims.

**CRITICAL: Item Ordering**
- Order all items (sections, bullet points, changes) by **decreasing importance**
- Importance = impact of the change × likelihood someone reading history will care
- Most impactful/interesting changes first, minor details last
- Think: "What would I want to see first when reviewing this PR?"

**Examples:**
- Good: "test-extra runs full test suite across multiple pg_tle versions"
- Bad: "comprehensive testing support"

- Good: "Fix race condition where git subtree add fails due to filesystem timestamp granularity"
- Bad: "Fix various timing issues"

- Good: "Template files moved from pgxntool-test-template/t/ to template/"
- Bad: "Improved template organization"

**Don't document the development journey** - No "first we tried X, discovered Y, so did Z"

**Don't over-explain** - If the reason is obvious, don't state it.

**No Testing/Test plan section by default** - The standard is to rely on CI. Only add one when something needs verification CI won't cover (e.g. a manual step, a live trigger that can't run in CI, an explicit known limitation).

**Tone reference:** See HISTORY.asc for style (outcome-focused, concise). PRs should be more detailed than changelog entries.

---

## Workflow

### 1. Analyze Changes

```bash
cd ../pgxntool && git status && git log origin/BRANCH..BRANCH --oneline
cd ../pgxntool-test && git status && git log origin/BRANCH..BRANCH --oneline
```

### 2. Create pgxntool PR

```bash
cd ../pgxntool
gh pr create \
  --repo Postgres-Extensions/pgxntool \
  --base master \
  --head jnasbyupgrade:BRANCH \
  --title "[Title]" \
  --body "[Body]"
```

### 3. Create pgxntool-test PR

```bash
cd ../pgxntool-test
gh pr create \
  --repo Postgres-Extensions/pgxntool-test \
  --base master \
  --head jnasbyupgrade:BRANCH \
  --title "[Title]" \
  --body "[Opening paragraph]

Related pgxntool PR: [URL]

[Rest of body]"
```

### 4. Update pgxntool PR with cross-reference

`gh pr edit` has no append flag, so read the current body, append, and write it back:

```bash
body=$(mktemp) &&
gh pr view [NUMBER] --repo Postgres-Extensions/pgxntool --json body --jq .body > "$body" &&
printf '\nRelated pgxntool-test PR: %s\n' "[URL]" >> "$body" &&
gh pr edit [NUMBER] --repo Postgres-Extensions/pgxntool --body-file "$body"
rm -f "$body"
```

---

## Example

**Good PR Description:**
```
Add pg_tle support, with a test-extra target that runs the full suite across pg_tle versions, and move the template extension into pgxntool-test.

Related pgxntool-test PR: https://github.com/Postgres-Extensions/pgxntool-test/pull/2

## Key Features

**pg_tle Support:**
- Support pg_tle versions 1.0.0-1.5.2 (https://github.com/aws/pg_tle)
- test-extra target runs full test suite across multiple pg_tle versions

**Template Consolidation:**
- Remove pgxntool-test-template dependency
- Template files moved to pgxntool-test/template/
- Two-repo pattern: pgxntool + pgxntool-test

**Distribution:**
- Exclude .claude/ from git archive
```

**Bad PR Description:**
```
Improvements and bug fixes

This PR modernizes the test infrastructure and adds comprehensive testing.

During development we discovered issues and refactored to improve maintainability.

Changes:
- Better testing
- Fixed bugs
```
Problems: Vague, documents development process, no specifics
