---
description: Create a git commit following project standards and safety protocols
allowed-tools: Bash(git status:*), Bash(git log:*), Bash(git add:*), Bash(git diff:*), Bash(git commit:*), Bash(make test:*), Read, Edit
---

# commit

Create a git commit following all project standards and safety protocols for pgxntool-test.

**CRITICAL REQUIREMENTS:**

1. **Git Safety**: Never update `git config`, never force push to `main`/`master`, never skip hooks unless explicitly requested

2. **Commit Attribution**: Do NOT add "Generated with Claude Code" to commit message body. The standard Co-Authored-By trailer is acceptable per project CLAUDE.md.

3. **Multi-Repo Commits**: If BOTH repositories have changes, commit BOTH (unless user explicitly says otherwise). Do NOT create empty commits - only commit repos with actual changes.

4. **Testing**: ALL tests must pass before committing:
   - Tests are run via test subagent (first step in workflow)
   - Check subagent output carefully for any "not ok" lines
   - **If ANY tests fail: STOP. Do NOT commit. Ask the user what to do.**
   - There is NO such thing as an "acceptable" failing test
   - Do NOT rationalize failures as "pre-existing" or "unrelated"

5. **HISTORY.asc Updates**: For significant, user-visible changes in pgxntool, HISTORY.asc must be updated:
   - Propose an entry and ask for confirmation
   - Updates go in the STABLE section at the TOP of the file
   - If no STABLE section exists, create one

**WORKFLOW:**

1. **Launch test subagent** (unless user explicitly says not to):
   - Use Task tool to launch test subagent to run `make test`
   - Run in background so we can continue with analysis
   - Tests will be checked before committing

2. **While tests run**, gather information in parallel:
   - `git status`, `git diff --stat`, `git log -10 --oneline` for both repos

3. **Check if HISTORY.asc needs updating** (for pgxntool changes only):
   - Read `../pgxntool/HISTORY.asc`
   - Determine if changes are significant and user-visible:
     * ✅ New features, new commands, behavior changes, bug fixes users would notice
     * ❌ Internal refactoring, test changes, code cleanup, documentation fixes
   - If update needed, propose an entry in AsciiDoc format (use `==` for heading)
   - Present proposed entry and ask for confirmation BEFORE proceeding
   - If confirmed, add entry to STABLE section (create section if missing):
     ```
     STABLE
     ------
     == [Entry heading]
     [Entry description]

     [existing content...]
     ```

4. **Analyze changes** in BOTH repositories and draft commit messages for BOTH:

   **CRITICAL: Item Ordering**
   - Order all items (changes, bullet points) by **decreasing importance**
   - Importance = impact of the change × likelihood someone reading history will care
   - Most impactful/interesting changes first, minor details last
   - Think: "What would I want to see first when reading this in git log 2 years from now?"

   For pgxntool:
   - Analyze: `git status`, `git diff --stat`, `git log -10 --oneline`
   - Draft message with structure:
     ```
     Subject line

     [Main changes in pgxntool, ordered by decreasing importance...]

     Related changes in pgxntool-test:
     - [RELEVANT test change 1]
     - [RELEVANT test change 2]

     Co-Authored-By: Claude <noreply@anthropic.com>
     ```
   - Only mention RELEVANT test changes (1-3 bullets):
     * ✅ Include: Tests for new features, template updates, user docs
     * ❌ Exclude: Test refactoring, infrastructure, internal changes
   - Wrap code references in backticks (e.g., `helpers.bash`, `make test`)
   - No hash placeholder needed - pgxntool doesn't reference test hash

   For pgxntool-test:
   - Analyze: `git status`, `git diff --stat`, `git log -10 --oneline`
   - Draft message with structure:
     ```
     Subject line

     Add tests/updates for pgxntool commit [PGXNTOOL_COMMIT_HASH] (brief description):
     - [Key pgxntool change 1]
     - [Key pgxntool change 2]

     [pgxntool-test specific changes, ordered by decreasing importance...]

     Co-Authored-By: Claude <noreply@anthropic.com>
     ```
   - Use placeholder `[PGXNTOOL_COMMIT_HASH]`
   - Include brief summary (2-3 bullets) of pgxntool changes near top
   - Wrap code references in backticks

   **If only one repo has changes:**
   Skip the repo with no changes. In the commit message for the repo that has changes,
   add: "Changes only in [repo]. No related changes in [other repo]." before Co-Authored-By.

5. **PRESENT both proposed commit messages to the user and WAIT for approval**

   Show both messages:
   ```
   ## Proposed Commit for pgxntool:
   [message]

   ## Proposed Commit for pgxntool-test:
   [message with [PGXNTOOL_COMMIT_HASH] placeholder]
   ```

   **Note:** Mention any files that are intentionally not being committed and why.

   **Note:** If only one repo has changes, show only that message (with note about other repo).

6. **Wait for tests to complete** - THIS IS MANDATORY:
   - Check test subagent output for completion
   - Verify ALL tests passed (no "not ok" lines)
   - **If ANY tests fail: STOP. Do NOT commit. Ask the user what to do.**
   - There is NO such thing as an "acceptable" failing test
   - Do NOT rationalize failures as "pre-existing" or "unrelated"
   - Only proceed to commit if ALL tests pass

7. **After tests pass AND receiving approval, execute two-phase commit:**

   **Phase 1: Commit pgxntool**

   a. `cd ../pgxntool`

   b. Stage changes: `git add` (include ALL new files per guidelines below)
      - Check `git status` for untracked files
      - ALL untracked files that are part of the feature/change MUST be staged
      - New scripts, new documentation, new helper files, etc. should all be included
      - Do NOT leave new files uncommitted unless explicitly told to exclude them

   c. Verify staged files: `git status`
      - Confirm ALL modified AND untracked files are staged
      - STOP and ask user if staging doesn't match intent

   d. Commit using approved message:
      ```bash
      git commit -m "$(cat <<'EOF'
      [approved pgxntool message]
      EOF
      )"
      ```

   e. Capture hash: `PGXNTOOL_HASH=$(git log -1 --format=%h)`

   f. Verify: `git status`

   g. Handle pre-commit hooks if needed:
      - Check if hooks modified files
      - Check authorship: `git log -1 --format='%an %ae'`
      - Check branch status
      - Amend if safe or create new commit

   **Phase 2: Commit pgxntool-test**

   a. `cd ../pgxntool-test`

   b. Replace `[PGXNTOOL_COMMIT_HASH]` in approved message with `$PGXNTOOL_HASH`
      - Keep everything else EXACTLY the same

   c. Stage changes: `git add` (include ALL new files)

   d. Verify staged files: `git status`

   e. Commit using hash-injected message:
      ```bash
      git commit -m "$(cat <<'EOF'
      [approved message with actual pgxntool hash]
      EOF
      )"
      ```

   f. Capture hash: `TEST_HASH=$(git log -1 --format=%h)`

   g. Verify: `git status`

   h. Handle pre-commit hooks if needed

   **Note:** If only one repo has changes, skip the phase for the other repo.

**MULTI-REPO COMMIT CONTEXT:**

The two repositories:
- **pgxntool** - The main framework
- **pgxntool-test** - Test harness (includes template files in `template/` directory)

When committing changes that span repositories:

1. **pgxntool-test commit MUST reference pgxntool commit hash**

   pgxntool commit format:
   ```
   Subject line

   [Main changes...]

   Related changes in pgxntool-test:
   - [RELEVANT test change]
   - [Keep to 1-3 bullets]

   Co-Authored-By: Claude <noreply@anthropic.com>
   ```

   pgxntool-test commit format:
   ```
   Subject line

   Add tests for pgxntool commit def5678 (brief description):
   - [Key pgxntool change 1]
   - [Key pgxntool change 2]

   [pgxntool-test specific changes...]

   Co-Authored-By: Claude <noreply@anthropic.com>
   ```

2. **Relevance filter for pgxntool message:**
   - ✅ Include: Tests for new features, template updates, user documentation
   - ❌ Exclude: Test refactoring, infrastructure changes, internal improvements
   - Keep it brief (1-3 bullets max)

3. **Commit workflow:**
   - Commit pgxntool first (no placeholder)
   - Capture pgxntool hash
   - Commit pgxntool-test (inject pgxntool hash)
   - Result: pgxntool-test references pgxntool commit

4. **Single-repo case:**
   Add line: "Changes only in [repo]. No related changes in [other repo]."

**REPOSITORY CONTEXT:**

This is pgxntool, a PostgreSQL extension build framework. Key facts:
- Main Makefile is `base.mk`
- Scripts live in root directory
- Documentation is in `README.asc` (generates `README.html`)

**RESTRICTIONS:**
- DO NOT push unless explicitly asked
- DO NOT commit files with actual secrets (`.env`, `credentials.json`, etc.)
- Never use `-i` flags (`git commit -i`, `git rebase -i`, etc.)
