.PHONY: all
all: test

TEST_DIR ?= tests
DIFF_DIR ?= diffs
RESULT_DIR ?= results
RESULT_SED = $(RESULT_DIR)/result.sed

DIRS = $(RESULT_DIR) $(DIFF_DIR)

#
# Test targets
#
# We define TEST_TARGETS from TESTS instead of the other way around so you can
# over-ride what tests will run by defining TESTS
TESTS ?= $(subst $(TEST_DIR)/,,$(wildcard $(TEST_DIR)/*)) # Can't use pathsubst for some reason
TEST_TARGETS = $(TESTS:%=test-%)

# Dependencies
test-setup: test-clone

test-meta: test-setup

test-dist: test-meta
test-setup-final: test-dist

test-make-test: test-setup-final
test-doc: test-setup-final

test-make-results: test-make-test

.PHONY: test
test: clean-temp cont

# Just continue what we were building
.PHONY: cont
cont: $(TEST_TARGETS)
	@[ "`cat $(DIFF_DIR)/*.diff 2>/dev/null | head -n1`" == "" ] \
		&& (echo; echo 'All tests passed!'; echo) \
		|| (echo; echo "Some tests failed:"; echo ; egrep -lR '.' $(DIFF_DIR); echo; exit 1)

#
# Actual test targets
#

.PHONY: $(TEST_TARGETS)
$(TEST_TARGETS): test-%: $(DIFF_DIR)/%.diff

# Ensure expected files exist so diff doesn't puke
expected/%.out:
	@[ -e $@ ] || (echo "CREATING EMPTY $@"; touch $@)

# Generic test environment
.PHONY: env
env: .env $(RESULT_SED)

.PHONY: sync-expected
sync-expected: $(TESTS:%=$(RESULT_DIR)/%.out)
	cp $^ expected/

# Generic output target
.PRECIOUS: $(RESULT_DIR)/%.out
$(RESULT_DIR)/%.out: $(TEST_DIR)/% .env lib.sh | $(RESULT_SED)
	@echo "Running $<; logging to $@ (temp log=$@.tmp)"
	@rm -f $@.tmp # Remove old temp file if it exists
	@LOG=`pwd`/$@.tmp ./$< && mv $@.tmp $@

# Generic diff target
# TODO: allow controlling whether we stop immediately on error or not
$(DIFF_DIR)/%.diff: $(RESULT_DIR)/%.out expected/%.out | $(DIFF_DIR)
	@echo diffing $*
	@diff -u expected/$*.out $< > $@ && rm $@ || head -n 40 $@


#
# Environment setup
#

CLEAN += $(DIRS)
$(DIRS): %:
	mkdir -p $@

$(RESULT_SED): base_result.sed | $(RESULT_DIR)
	@echo "Constructing $@"
	@cp $< $@
	@if [ "$$(psql -X -qtc "SELECT current_setting('server_version_num')::int < 90200")" = "t" ]; then \
		echo "Enabling support for Postgres < 9.2" ;\
		echo "s!rm -f  sql/pgxntool-test--0.1.0.sql!rm -rf  sql/pgxntool-test--0.1.0.sql!" >> $@ ;\
		echo "s!rm -f ../distribution_test!rm -rf ../distribution_test!" >> $@ ;\
	fi

CLEAN += .env
.env: make-temp.sh
	@echo "Creating temporary environment"
	@./make-temp.sh > .env
	@RESULT_DIR=`pwd`/$(RESULT_DIR) && echo "RESULT_DIR='$${RESULT_DIR}'" >> .env

.PHONY: clean-temp
clean: clean-temp
clean-temp:
	@[ ! -e .env ] || (echo Removing temporary environment; ./clean-temp.sh)

clean: clean-temp 
	rm -rf $(CLEAN)

# To use this, do make print-VARIABLE_NAME
print-%	: ; $(info $* is $(flavor $*) variable set to "$($*)") @true

