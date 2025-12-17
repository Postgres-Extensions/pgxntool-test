---
description: Create a git commit following project standards and safety protocols
allowed-tools: Bash(git status:*), Bash(git log:*), Bash(git add:*), Bash(git diff:*), Bash(git commit:*), Bash(make test:*), Bash(asciidoctor:*)
---

# commit

**FIRST: Update pgxntool README.html (if needed)**

Before following the standard commit workflow, check if `../pgxntool/README.html` needs regeneration:

1. Check timestamps: if `README.asc` is newer than `README.html` (or if `README.html` doesn't exist), regenerate:
   ```bash
   cd ../pgxntool
   if [ ! -f README.html ] || [ README.asc -nt README.html ]; then
     asciidoctor README.asc -o README.html
   fi
   ```
2. If HTML was generated, sanity-check `README.html`:
   - Verify file exists and is not empty
   - Check file size is reasonable (should be larger than source)
   - Spot-check that it contains HTML tags
3. If generation fails or file looks wrong: STOP and inform the user
4. Return to pgxntool-test directory: `cd ../pgxntool-test`

**THEN: Follow standard commit workflow**

After completing the README.html step above, follow all instructions from:

@../pgxntool/.claude/commands/commit.md

**MULTI-REPO COMMIT CONTEXT:**

**CRITICAL**: Commits to pgxntool are often done across multiple repositories:
- **pgxntool** (main repo at `../pgxntool/`) - The framework itself
- **pgxntool-test** (this repo) - Test harness
- **pgxntool-test-template** (at `../pgxntool-test-template/`) - Test template

When committing changes that span repositories:
1. **Commit messages in pgxntool-test and pgxntool-test-template should reference the main changes in pgxntool**
   - Example: "Add tests for pg_tle support (see pgxntool commit for implementation)"
   - Example: "Update template for pg_tle feature (see pgxntool commit for details)"

2. **ALWAYS include ALL new files in commits**
   - Check `git status` for untracked files
   - **ALL untracked files that are part of the feature should be staged and committed**
   - Do NOT leave new files uncommitted unless explicitly told to exclude them
   - If you see untracked files in `git status`, ask yourself: "Are these part of this change?" If yes, include them.

3. **When working across repos, commit in logical order:**
   - Usually: pgxntool → pgxntool-test → pgxntool-test-template
   - But adapt based on dependencies

**Additional context for this repo:**
- This is pgxntool-test, the test harness for pgxntool
- The pgxntool repository lives at `../pgxntool/`
- The pgxntool-test-template repository lives at `../pgxntool-test-template/`
