# BATS Test System TODO

This file tracks future improvements and enhancements for the BATS test system.

## High Priority

### Evaluate BATS Standard Assertion Libraries

**Goal**: Replace our custom assertion functions with community-maintained libraries.

**Why**: Don't reinvent the wheel - the BATS ecosystem has mature, well-tested assertion libraries.

**Libraries to Evaluate**:
- [bats-assert](https://github.com/bats-core/bats-assert) - General assertion library
- [bats-support](https://github.com/bats-core/bats-support) - Supporting library for bats-assert
- [bats-file](https://github.com/bats-core/bats-file) - File system assertions

**Tasks**:
1. Install libraries as git submodules (like we did with bats-core)
2. Review their assertion functions vs our custom ones in assertions.bash
3. Migrate tests to use standard libraries where appropriate
4. Keep any custom assertions that don't have standard equivalents
5. Update documentation to reference standard libraries

## CI/CD Integration

Add GitHub Actions workflow for automated testing across PostgreSQL versions.

**Implementation**:

Create `.github/workflows/test.yml`:

```yaml
name: Test pgxntool
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        postgres: [12, 13, 14, 15, 16]
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: recursive
      - name: Install PostgreSQL ${{ matrix.postgres }}
        run: |
          sudo apt-get update
          sudo apt-get install -y postgresql-${{ matrix.postgres }}
      - name: Run BATS tests
        run: make test-bats
```

## Static Analysis with ShellCheck

Add linting target to catch shell scripting errors early.

**Implementation**:

Add to `Makefile`:

```makefile
.PHONY: lint
lint:
	find tests -name '*.bash' | xargs shellcheck
	find tests -name '*.bats' | xargs shellcheck -s bash
	shellcheck lib.sh util.sh make-temp.sh clean-temp.sh
```

**Usage**: `make lint`

## Low Priority / Future Considerations

### Parallel Execution for Non-Sequential Tests

Non-sequential tests (test-*.bats) could potentially run in parallel since they use isolated environments.

**Considerations**:
- Would need to ensure no resource conflicts (port numbers, etc.)
- BATS supports parallel execution with `--jobs` flag
- May need adjustments to environment creation logic

### Test Performance Profiling

Add timing information to identify slow tests.

**Possible approaches**:
- Use BATS TAP output with timing extensions
- Add manual timing instrumentation
- Profile individual test operations

### Enhanced State Debugging

Add commands to inspect test state without running tests.

**Examples**:
- `make test-bats-state` - Show current state markers
- `make test-bats-clean-state` - Safely clean all environments
- State visualization tools
