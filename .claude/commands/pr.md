---
name: pr
description: Create pull requests for pgxntool changes
---

# /pr Claude Command

Create pull requests for pgxntool and pgxntool-test changes, following the two-repo workflow.

**Note:** This is a Claude Command (invoked with `/pr`), part of the Claude Code integration.

**CRITICAL WORKFLOW:**

1. **Check both repositories** - Always check git status in both pgxntool and pgxntool-test

2. **Create PRs in correct order** - If both have changes: pgxntool first, then pgxntool-test

3. **Always target main repositories:**
   - pgxntool: `--repo Postgres-Extensions/pgxntool`
   - pgxntool-test: `--repo Postgres-Extensions/pgxntool-test`
   - **NEVER** target fork (jnasbyupgrade)

4. **Cross-reference PRs:**
   - pgxntool-test PR: Include "Related pgxntool PR: [URL]" at top
   - After creating test PR: Update pgxntool PR to add "Related pgxntool-test PR: [URL]"
   - **Always use full URLs** (cross-repo #number doesn't work)

---

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
  --body "Related pgxntool PR: [URL]

[Body]"
```

### 4. Update pgxntool PR with cross-reference

```bash
cd ../pgxntool
gh pr edit [NUMBER] --add-body "

Related pgxntool-test PR: [URL]"
```

---

## Example

**Good PR Description:**
```
Add pg_tle support and template consolidation

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
