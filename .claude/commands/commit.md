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

**Additional context for this repo:**
- This is pgxntool-test, the test harness for pgxntool
- The pgxntool repository lives at `../pgxntool/`
