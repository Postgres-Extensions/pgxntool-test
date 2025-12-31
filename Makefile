.PHONY: all
all: test

# Capture git status once at Make parse time
GIT_DIRTY := $(shell git status --porcelain 2>/dev/null)

# Build fresh foundation environment (clean + create)
# Foundation is the base TEST_REPO that all tests depend on
# See test/lib/foundation.bats for detailed explanation of why foundation.bats
# is both a test and a library
.PHONY: foundation
foundation: clean-envs
	@test/bats/bin/bats test/lib/foundation.bats

# Test recursion and pollution detection
# Cleans environments then runs one independent test, which auto-runs foundation
# as a prerequisite. This validates that recursion and pollution detection work correctly.
# Note: Doesn't matter which independent test we use, we just pick the fastest one (doc).
.PHONY: test-recursion
test-recursion: clean-envs
	@echo "Testing recursion with clean environment..."
	@test/bats/bin/bats test/standard/doc.bats

# Test file lists
# These are computed at Make parse time for efficiency
SEQUENTIAL_TESTS := $(shell ls test/sequential/[0-9][0-9]-*.bats 2>/dev/null | sort)
STANDARD_TESTS := $(shell ls test/standard/*.bats 2>/dev/null | grep -v foundation.bats)
EXTRA_TESTS := $(shell ls test/extra/*.bats 2>/dev/null)
ALL_INDEPENDENT_TESTS := $(STANDARD_TESTS) $(EXTRA_TESTS)

# Common test setup: runs foundation test ONLY
# This is shared by all test targets to avoid duplication
#
# IMPORTANT: test-setup ONLY runs foundation.bats, no other tests.
# See test/lib/foundation.bats for detailed explanation of why foundation.bats
# must be run directly (not as part of another test) to get useful error output.
#
# If git repo is dirty (uncommitted test code changes), runs test-recursion FIRST
# to validate that recursion/pollution detection still work with the changes.
# This is critical because changes to test infrastructure (helpers.bash, etc.) could
# break the prerequisite or pollution detection systems. By running test-recursion
# first with a clean environment, we exercise these systems before running the full suite.
# If recursion is broken, we want to know immediately, not after running all tests.
.PHONY: test-setup
test-setup:
ifneq ($(GIT_DIRTY),)
	@echo "Git repo is dirty (uncommitted changes detected)"
	@echo "Running recursion test first to validate test infrastructure..."
	$(MAKE) test-recursion
	@echo ""
	@echo "Recursion test passed, now running full test suite..."
endif
	@$(MAKE) clean-envs
	@$(MAKE) check-readme
	@test/bats/bin/bats test/lib/foundation.bats

# Run standard tests - sequential tests in order, then standard independent tests
# Excludes optional/extra tests (e.g., test-pgtle-versions.bats) which are only run in test-all or test-extra
#
# Note: We explicitly list all sequential tests rather than just running the last one
# because BATS only outputs TAP results for the test files directly invoked.
# If we only ran the last test, prerequisite tests would run but their results
# wouldn't appear in the output.
.PHONY: test
test: test-setup
	@test/bats/bin/bats $(SEQUENTIAL_TESTS) $(STANDARD_TESTS)

# Run ALL tests including optional/extra tests
# This is simply the combination of test and test-extra
.PHONY: test-all
test-all: test test-extra

# Run ONLY extra/optional tests (e.g., test-pgtle-versions.bats)
# These are tests that are excluded from the standard test suite but can be run separately
.PHONY: test-extra
test-extra: test-setup
ifneq ($(EXTRA_TESTS),)
	@test/bats/bin/bats $(EXTRA_TESTS)
else
	@echo "No extra tests found"
endif

# Clean test environments
.PHONY: clean-envs
clean-envs:
	@echo "Removing test environments..."
	@rm -rf .envs

.PHONY: clean
clean: clean-envs

# Build README.html from README.asc
# Prefers asciidoctor over asciidoc
# Note: This works on the pgxntool source repository, not test environments
ASCIIDOC_CMD := $(shell which asciidoctor 2>/dev/null || which asciidoc 2>/dev/null)
PGXNTOOL_SOURCE_DIR := $(shell cd $(CURDIR)/../pgxntool && pwd)
.PHONY: readme
readme:
ifndef ASCIIDOC_CMD
	$(error Could not find "asciidoc" or "asciidoctor". Add one of them to your PATH)
endif
	@if [ ! -f "$(PGXNTOOL_SOURCE_DIR)/README.asc" ]; then \
		echo "ERROR: README.asc not found at $(PGXNTOOL_SOURCE_DIR)/README.asc" >&2; \
		exit 1; \
	fi
	@$(ASCIIDOC_CMD) $(if $(findstring asciidoctor,$(ASCIIDOC_CMD)),-a sectlinks -a sectanchors -a toc -a numbered,) "$(PGXNTOOL_SOURCE_DIR)/README.asc" -o "$(PGXNTOOL_SOURCE_DIR)/README.html"

# Check if README.html is up to date
#
# CRITICAL: This target checks if README.html is out of date BEFORE rebuilding.
# If out of date, we:
#   1. Set an error flag
#   2. Rebuild as a convenience for developers
#   3. Exit with error status (even after rebuilding)
#
# This ensures CI fails if README.html is out of date, while still providing
# a convenient auto-rebuild for local development.
#
# The rebuild is to make life easy FOR A PERSON. But having .html out of date
# IS AN ERROR and needs to ALWAYS be treated as such.
.PHONY: check-readme
check-readme:
	@# Check if source files exist
	@if [ ! -f "$(PGXNTOOL_SOURCE_DIR)/README.asc" ] || [ ! -f "$(PGXNTOOL_SOURCE_DIR)/README.html" ]; then \
		echo "WARNING: README.asc or README.html not found, skipping check" >&2; \
		exit 0; \
	fi
	@# Check if README.html is out of date (BEFORE rebuilding)
	@OUT_OF_DATE=0; \
	if [ "$(PGXNTOOL_SOURCE_DIR)/README.asc" -nt "$(PGXNTOOL_SOURCE_DIR)/README.html" ] 2>/dev/null; then \
		OUT_OF_DATE=1; \
	fi; \
	if [ $$OUT_OF_DATE -eq 1 ]; then \
		echo "ERROR: pgxntool/README.html is out of date relative to README.asc" >&2; \
		echo "" >&2; \
		echo "Rebuilding as a convenience, but this is an ERROR condition..." >&2; \
		$(MAKE) -s readme 2>/dev/null || true; \
		echo "" >&2; \
		echo "README.html has been automatically updated, but you must commit the change." >&2; \
		echo "This check ensures README.html stays up-to-date for automated testing." >&2; \
		echo "" >&2; \
		echo "To fix this, run: cd ../pgxntool && git add README.html && git commit" >&2; \
		exit 1; \
	fi

# To use this, do make print-VARIABLE_NAME
print-%	: ; $(info $* is $(flavor $*) variable set to "$($*)") @true

# List all make targets
.PHONY: list
list:
	sh -c "$(MAKE) -p no_targets__ | awk -F':' '/^[a-zA-Z0-9][^\$$#\/\\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}' | grep -v '__\$$' | sort"
