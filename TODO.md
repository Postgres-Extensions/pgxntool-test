# TODO List for pgxntool-test

## Move Template from Separate Repo to pgxntool-test/git-template

**Current situation**:
- Template lives in separate repo: `../pgxntool-test-template/`
- Foundation copies files from `$TEST_TEMPLATE/t/` to create TEST_REPO
- Requires maintaining three separate git repositories

**Proposed change**:
- Move template files into this repository at `git-template/`
- Update foundation.bats to copy from `$TOPDIR/git-template/` instead of `$TEST_TEMPLATE/t/`
- Simplifies development (one less repo to maintain)
- Makes the test system more self-contained

**Files to update**:
1. Create `git-template/` directory structure
2. Move template files from `../pgxntool-test-template/t/` to `git-template/`
3. Update `test/lib/foundation.bats` to use new path
4. Update `test/lib/helpers.bash` (TEST_TEMPLATE default)
5. Update CLAUDE.md in this repo
6. Update CLAUDE.md in ../pgxntool/ (references to test-template)
7. Update README.md
8. Update .claude/agents/*.md files that reference test-template

**Benefits**:
- Fewer repositories to manage
- Clearer that template is just test data, not a real project
- Easier for contributors (clone one repo instead of three)
- Template changes tested in same commit as test infrastructure changes

**Considerations**:
- Keep pgxntool-test-template repo temporarily as deprecated/archived for reference
- Document the change clearly for anyone with existing clones
