.PHONY: all
all: test

# Build fresh foundation environment (clean + create)
# Foundation is the base TEST_REPO that all tests depend on
.PHONY: foundation
foundation: clean-envs
	@test/bats/bin/bats tests/foundation.bats

# Run all tests - sequential tests in order, then non-sequential tests
# Note: We explicitly list all sequential tests rather than just running the last one
# because BATS only outputs TAP results for the test files directly invoked.
# If we only ran the last test, prerequisite tests would run but their results
# wouldn't appear in the output.
.PHONY: test
test: clean-envs
	@test/bats/bin/bats $$(ls tests/[0-9][0-9]-*.bats 2>/dev/null | sort) tests/test-*.bats

# Clean test environments
.PHONY: clean-envs
clean-envs:
	@echo "Removing test environments..."
	@rm -rf .envs

.PHONY: clean
clean: clean-envs

# To use this, do make print-VARIABLE_NAME
print-%	: ; $(info $* is $(flavor $*) variable set to "$($*)") @true

# List all make targets
.PHONY: list
list:
	sh -c "$(MAKE) -p no_targets__ | awk -F':' '/^[a-zA-Z0-9][^\$$#\/\\t=]*:([^=]|$$)/ {split(\$$1,A,/ /);for(i in A)print A[i]}' | grep -v '__\$$' | sort"
