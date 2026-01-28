---
description: Resolve conflicts after pgxntool-sync updates setup files
allowed-tools: Read, Edit, Write, Grep, Glob, Bash(git:*), Bash(grep:*), Bash(cat:*)
---

# pgxntool-update

Help resolve conflicts in setup files after running `make pgxntool-sync`.

When pgxntool is updated via subtree sync, the `update-setup-files.sh` script performs a 3-way merge on files initially copied by `setup.sh`. If both you and pgxntool changed the same file, conflict markers may be left behind.

## Context Gathering

First, find any files with conflict markers (search entire repo):

!grep -rl '<<<<<<<' . 2>/dev/null | grep -v '^\.git/' || echo "No conflict markers found"

Check git status for modified files:

!git status --short

## Your Task

### Step 1: Analyze Each Conflicted File

For each file with conflict markers identified above:

1. **Read the file** to see the current state with conflict markers

2. **Find the source file in pgxntool** - Look at `pgxntool/update-setup-files.sh` to see the mapping:
   ```
   grep SETUP_FILES pgxntool/update-setup-files.sh
   ```

3. **Understand what pgxntool changed** - Check recent commits to the source file:
   ```
   git log --oneline -5 -- pgxntool/<source-file>
   git log -1 -p -- pgxntool/<source-file>
   ```

4. **Check HISTORY.asc** for context on why pgxntool made the change:
   ```
   git diff HEAD~1 -- pgxntool/HISTORY.asc
   ```

5. **Identify the user's customizations** - The content between `<<<<<<< yours` and `|||||||` shows what the user had.

### Step 2: Explain the Situation

Clearly explain to the user:
- What pgxntool changed (the "new pgxntool" side after `=======`)
- What the user had customized (the "yours" side)
- Why pgxntool likely made the change (based on history/HISTORY.asc)
- The base version both diverged from (the "old pgxntool" section)

### Step 3: Suggest Resolution

Based on the analysis, recommend a resolution strategy:

- **If pgxntool added new entries**: Usually safe to keep both user's and pgxntool's additions
- **If pgxntool removed something**: Check if the user still needs it
- **If pgxntool modified existing content**: Understand the intent before deciding

Present the proposed resolution and get user approval before editing.

### Step 4: Edit to Resolve

After approval, use the Edit tool to remove conflict markers and apply the agreed resolution.

### Step 5: Verify

After editing, verify no conflict markers remain:

```
grep -rl '<<<<<<<' . 2>/dev/null | grep -v '^\.git/' || echo "All conflicts resolved"
git diff
git status
```

## Setup Files Reference

Files managed by `update-setup-files.sh` (3-way merged):

| Source in pgxntool | Destination | Purpose |
|-------------------|-------------|---------|
| `_.gitignore` | `.gitignore` | Git ignore patterns |
| `test/deps.sql` | `test/deps.sql` | Test dependencies |

Symlinks (verified, not merged):
- `test/pgxntool` -> `../pgxntool/test/pgxntool`

## Conflict Marker Format

The 3-way merge produces:
```
<<<<<<< yours
[Your version - what you customized]
||||||| old pgxntool
[The old pgxntool version you originally copied from]
=======
[The new pgxntool version from the sync]
>>>>>>> new pgxntool
```

## Common Scenarios

**pgxntool added new ignore patterns:**
- Keep your additions AND pgxntool's new patterns
- Check if any of your patterns are now redundant

**pgxntool changed test/deps.sql:**
- Review what dependencies changed
- Preserve your custom test dependencies
- Ensure pgxntool's new dependencies are included

**Symlink issue:**
- If `test/pgxntool` needs fixing: `ln -sf ../pgxntool/test/pgxntool test/pgxntool`

## After Resolution

Remind the user to:
1. Review all changes with `git diff`
2. Run tests to ensure nothing broke: `make test`
3. Commit when satisfied
