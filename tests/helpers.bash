#!/usr/bin/env bash

# Shared helper functions for BATS tests
#
# IMPORTANT: Concurrent Test Execution Limitations
#
# While this system has provisions to detect conflicting concurrent test runs
# (via PID files and locking), the mechanism is NOT bulletproof.
#
# When BATS is invoked with multiple files (e.g., "bats test1.bats test2.bats"),
# each .bats file runs in a separate process with different PIDs. This means:
# - We cannot completely eliminate race conditions
# - Two tests might both check for locks before either acquires one
# - The lock system provides best-effort protection, not a guarantee
#
# Theoretically we could use parent PIDs to detect this, but it's significantly
# more complicated and not worth the effort for this test suite.
#
# RECOMMENDATION: Run sequential tests one at a time, or accept occasional
# race condition failures when running multiple tests concurrently.

# Load assertion functions
load assertions

# Output to terminal (always visible)
# Usage: out "message"
# Outputs to FD 3 which BATS sends directly to terminal
out() {
  echo "# $*" >&3
}

# Error message and return failure
# Usage: error "message"
# Outputs error message and returns 1
error() {
  out "ERROR: $*"
  return 1
}

# Debug output function
# Usage: debug LEVEL "message"
# Outputs message if DEBUG >= LEVEL
debug() {
  local level=$1
  shift
  local message="$*"

  if [ "${DEBUG:-0}" -ge "$level" ]; then
    out "DEBUG[$level]: $message"
  fi
}

# Clean (remove) a test environment safely
# Checks for running tests via lock directories before removing
# Usage: clean_env "sequential"
clean_env() {
  local env_name=$1
  local env_dir="$TOPDIR/.envs/$env_name"

  debug 5 "clean_env: Cleaning $env_name at $env_dir"

  [ -d "$env_dir" ] || { debug 5 "clean_env: Directory doesn't exist, nothing to clean"; return 0; }

  local state_dir="$env_dir/.bats-state"

  # Check for running tests via lock directories
  if [ -d "$state_dir" ]; then
    debug 5 "clean_env: Checking for running tests in $state_dir"
    for lockdir in "$state_dir"/.lock-*; do
      [ -d "$lockdir" ] || continue

      local pidfile="$lockdir/pid"
      [ -f "$pidfile" ] || continue

      local pid=$(cat "$pidfile")
      local test_name=$(basename "$lockdir" | sed 's/^\.lock-//')
      debug 5 "clean_env: Found lock for $test_name with PID $pid"

      if kill -0 "$pid" 2>/dev/null; then
        error "Cannot clean $env_name - test $test_name is still running (PID $pid)"
      fi
      debug 5 "clean_env: PID $pid is stale (process not running)"
    done
  fi

  # Safe to clean now
  out "Removing $env_name environment..."

  # SECURITY: Ensure we're only deleting .envs subdirectories
  if [[ "$env_dir" != "$TOPDIR/.envs/"* ]]; then
    error "Refusing to clean directory outside .envs: $env_dir"
  fi

  rm -rf "$env_dir"
  debug 5 "clean_env: Successfully removed $env_dir"
}

# Create a new isolated test environment
# Usage: create_env "sequential" or create_env "doc"
create_env() {
  local env_name=$1
  local env_dir="$TOPDIR/.envs/$env_name"

  # Use clean_env for safe removal
  clean_env "$env_name" || return 1

  # Create new environment
  out "Creating $env_name environment..."
  mkdir -p "$env_dir/.bats-state"

  # Create .env file for this environment
  cat > "$env_dir/.env" <<EOF
export TOPDIR="$TOPDIR"
export TEST_DIR="$env_dir"
export TEST_REPO="$env_dir/repo"
export RESULT_DIR="$TOPDIR/results"
EOF
}

# Helper functions for repository path handling
local_repo() {
  # Check if repo is local (filesystem) or remote (git/http/https)
  if echo "$1" | grep -Eq '^(git|https?):'; then
    debug 5 "repo $1 is NOT local"
    return 1
  else
    debug 5 "repo $1 is local"
    return 0
  fi
}

find_repo() {
  # Get absolute path for local repos
  if local_repo "$1"; then
    (cd "$1" && pwd)
  else
    echo "$1"
  fi
}

debug_vars() {
  # Debug output for multiple variables
  local level=$1
  shift
  local output=""
  local value=""
  for variable in "$@"; do
    value="${!variable}"  # Safe indirect expansion (not eval)
    output="$output $variable='$value'"
  done
  debug "$level" "$output"
}

# Setup pgxntool-related variables
setup_pgxntool_vars() {
  # Smart branch detection: if pgxntool-test is on a non-master branch,
  # automatically use the same branch from pgxntool if it exists
  if [ -z "$PGXNBRANCH" ]; then
    # Detect current branch of pgxntool-test
    local TEST_HARNESS_BRANCH=$(git -C "$TOPDIR" symbolic-ref --short HEAD 2>/dev/null || echo "master")
    debug 5 "TEST_HARNESS_BRANCH=$TEST_HARNESS_BRANCH"

    # Default to master if test harness is on master
    if [ "$TEST_HARNESS_BRANCH" = "master" ]; then
      PGXNBRANCH="master"
    else
      # Check if pgxntool is local and what branch it's on
      local PGXNREPO_TEMP=${PGXNREPO:-${TOPDIR}/../pgxntool}
      if local_repo "$PGXNREPO_TEMP"; then
        local PGXNTOOL_BRANCH=$(git -C "$PGXNREPO_TEMP" symbolic-ref --short HEAD 2>/dev/null || echo "master")
        debug 5 "PGXNTOOL_BRANCH=$PGXNTOOL_BRANCH"

        # Use pgxntool's branch if it's master or matches test harness branch
        if [ "$PGXNTOOL_BRANCH" = "master" ] || [ "$PGXNTOOL_BRANCH" = "$TEST_HARNESS_BRANCH" ]; then
          PGXNBRANCH="$PGXNTOOL_BRANCH"
        else
          # Different branches - use master as safe fallback
          out "WARNING: pgxntool-test is on '$TEST_HARNESS_BRANCH' but pgxntool is on '$PGXNTOOL_BRANCH'"
          out "Using 'master' branch. Set PGXNBRANCH explicitly to override."
          PGXNBRANCH="master"
        fi
      else
        # Remote repo - default to master
        PGXNBRANCH="master"
      fi
    fi
  fi

  # Set defaults
  PGXNBRANCH=${PGXNBRANCH:-master}
  PGXNREPO=${PGXNREPO:-${TOPDIR}/../pgxntool}
  TEST_TEMPLATE=${TEST_TEMPLATE:-${TOPDIR}/../pgxntool-test-template}
  TEST_REPO=${TEST_DIR}/repo
  debug_vars 3 PGXNBRANCH PGXNREPO TEST_TEMPLATE TEST_REPO

  # Normalize repository paths
  PG_LOCATION=$(pg_config --bindir | sed 's#/bin##')
  PGXNREPO=$(find_repo "$PGXNREPO")
  TEST_TEMPLATE=$(find_repo "$TEST_TEMPLATE")
  debug_vars 5 PG_LOCATION PGXNREPO TEST_TEMPLATE

  # Export for use in tests
  export PGXNBRANCH PGXNREPO TEST_TEMPLATE TEST_REPO PG_LOCATION
}

# Load test environment for given environment name
# Auto-creates the environment if it doesn't exist
# Usage: load_test_env "sequential" or load_test_env "doc"
load_test_env() {
  local env_name=${1:-sequential}
  local env_file="$TOPDIR/.envs/$env_name/.env"

  # Auto-create if doesn't exist
  if [ ! -f "$env_file" ]; then
    create_env "$env_name" || return 1
  fi

  source "$env_file"

  # Setup pgxntool variables (replaces lib.sh functionality)
  setup_pgxntool_vars

  # Export for use in tests
  export TOPDIR TEST_DIR TEST_REPO RESULT_DIR

  return 0
}

# Check if environment is in clean state
# Returns 0 if clean, 1 if dirty
is_clean_state() {
  local current_test=$1
  local state_dir="$TEST_DIR/.bats-state"

  debug 2 "is_clean_state: Checking pollution for $current_test"

  # If current test doesn't match sequential pattern, it's standalone (no pollution check needed)
  if ! echo "$current_test" | grep -q "^[0-9][0-9]-"; then
    debug 3 "is_clean_state: Standalone test, skipping pollution check"
    return 0  # Standalone tests don't use shared state
  fi

  [ -d "$state_dir" ] || { debug 3 "is_clean_state: No state dir, clean"; return 0; }

  # Check if current test is re-running itself (already completed in this environment)
  # This catches re-runs but preserves normal prerequisite recursion (03 running 02 as prerequisite is fine)
  if [ -f "$state_dir/.complete-$current_test" ]; then
    debug 1 "POLLUTION DETECTED: $current_test already completed in this environment"
    debug 1 "  Completed: $(cat "$state_dir/.complete-$current_test")"
    debug 1 "  Re-running a completed test pollutes environment with side effects"
    out "Environment polluted: $current_test already completed here (re-run detected)"
    out "  Completed: $(cat "$state_dir/.complete-$current_test")"
    return 1  # Dirty!
  fi

  # Check for incomplete tests (started but not completed)
  # NOTE: We DO check the current test. If .start-<current> exists when we're
  # starting up, it means a previous run didn't complete (crashed or was killed).
  # That's pollution and we need to rebuild from scratch.
  debug 2 "is_clean_state: Checking for incomplete tests"
  for start_file in "$state_dir"/.start-*; do
    [ -f "$start_file" ] || continue
    local test_name=$(basename "$start_file" | sed 's/^\.start-//')

    debug 3 "is_clean_state: Found .start-$test_name (started: $(cat "$start_file"))"

    if [ ! -f "$state_dir/.complete-$test_name" ]; then
      # DEBUG 1: Most important - why did test fail?
      debug 1 "POLLUTION DETECTED: test $test_name started but didn't complete"
      debug 1 "  Started: $(cat "$start_file")"
      debug 1 "  Complete marker missing"
      out "Environment polluted: test $test_name started but didn't complete"
      out "  Started: $(cat "$start_file")"
      out "  Complete marker missing"
      return 1  # Dirty!
    else
      debug 3 "is_clean_state: .complete-$test_name exists (completed: $(cat "$state_dir/.complete-$test_name"))"
    fi
  done

  # Dynamically determine test order from directory (sorted)
  local test_order=$(cd "$TOPDIR/tests" && ls [0-9][0-9]-*.bats 2>/dev/null | sort | sed 's/\.bats$//' | xargs)

  debug 3 "is_clean_state: Test order: $test_order"

  local found_current=false

  # Check if any "later" sequential test has run
  debug 2 "is_clean_state: Checking for later tests"
  for test in $test_order; do
    if [ "$test" = "$current_test" ]; then
      debug 5 "is_clean_state: Found current test in order"
      found_current=true
      continue
    fi

    if [ "$found_current" = true ] && [ -f "$state_dir/.start-$test" ]; then
      # DEBUG 1: Most important - why did test fail?
      debug 1 "POLLUTION DETECTED: $test (runs after $current_test)"
      debug 1 "  Test order: $test_order"
      debug 1 "  Later test started: $(cat "$state_dir/.start-$test")"
      out "Environment polluted by $test (runs after $current_test)"
      out "  Test order: $test_order"
      out "  Later test started: $(cat "$state_dir/.start-$test")"
      return 1  # Dirty!
    fi
  done

  debug 2 "is_clean_state: Environment is clean"
  return 0  # Clean
}

# Create PID file/lock for a test using atomic mkdir
# Safe to call multiple times from same process
# Returns 0 on success, 1 on failure
create_pid_file() {
  local test_name=$1
  local lockdir="$TEST_DIR/.bats-state/.lock-$test_name"
  local pidfile="$lockdir/pid"

  # Try to create lock directory atomically
  if mkdir "$lockdir" 2>/dev/null; then
    # Got lock, write our PID
    echo $$ > "$pidfile"
    debug 5 "create_pid_file: Created lock for $test_name with PID $$"
    return 0
  fi

  # Lock exists, check if it's ours or stale
  if [ -f "$pidfile" ]; then
    local existing_pid=$(cat "$pidfile")

    # Check if it's our own PID (safe to call multiple times)
    if [ "$existing_pid" = "$$" ]; then
      return 0  # Already locked by us
    fi

    # Check if process is still alive
    if kill -0 "$existing_pid" 2>/dev/null; then
      error "Test $test_name already running (PID $existing_pid)"
    fi

    # Stale lock - try to remove safely
    # KNOWN RACE CONDITION: This cleanup is not fully atomic. If another process
    # creates a new PID file between our rm and rmdir, we'll fail with an error.
    # This is acceptable because:
    # 1. It only happens with true concurrent access (rare in test suite)
    # 2. It fails safe (error rather than corrupting state)
    # 3. Making it fully atomic would require OS-specific file locking
    rm -f "$pidfile" 2>/dev/null  # Remove PID file first
    if ! rmdir "$lockdir" 2>/dev/null; then
      error "Cannot remove stale lock for $test_name"
    fi

    # Retry - recursively call ourselves with recursion limit
    # Guard against infinite recursion (shouldn't happen, but be safe)
    local recursion_depth="${PIDFILE_RECURSION_DEPTH:-0}"
    if [ "$recursion_depth" -ge 5 ]; then
      error "Too many retries attempting to create PID file for $test_name"
    fi

    PIDFILE_RECURSION_DEPTH=$((recursion_depth + 1)) create_pid_file "$test_name"
    return $?
  fi

  # Couldn't get lock for unknown reason
  error "Cannot acquire lock for $test_name (unknown reason)"
}

# Mark test start (create .start marker)
# Note: PID file/lock is created separately via create_pid_file()
mark_test_start() {
  local test_name=$1
  local state_dir="$TEST_DIR/.bats-state"

  debug 3 "mark_test_start called for $test_name by PID $$"

  mkdir -p "$state_dir"

  # Mark test start with timestamp (high precision)
  date '+%Y-%m-%d %H:%M:%S.%N %z' > "$state_dir/.start-$test_name"
}

# Mark test complete (and remove lock directory)
mark_test_complete() {
  local test_name=$1
  local state_dir="$TEST_DIR/.bats-state"
  local lockdir="$state_dir/.lock-$test_name"

  debug 3 "mark_test_complete called for $test_name by PID $$"

  # Mark completion with timestamp (high precision)
  date '+%Y-%m-%d %H:%M:%S.%N %z' > "$state_dir/.complete-$test_name"

  # Remove lock directory (includes PID file)
  rm -rf "$lockdir"
  
  debug 5 ".env contents: $(find $state_dir -type f)"
}

# Check if a test is currently running
# Returns 0 if running, 1 if not
check_test_running() {
  local test_name=$1
  local state_dir="$TEST_DIR/.bats-state"
  local pid_file="$state_dir/.pid-$test_name"

  [ -f "$pid_file" ] || return 1  # No PID file, not running

  local pid=$(cat "$pid_file")

  # Check if process is still running
  if kill -0 "$pid" 2>/dev/null; then
    out "Test $test_name is already running (PID $pid)"
    return 0  # Still running
  else
    # Stale PID file, remove it
    rm -f "$pid_file"
    return 1  # Not running
  fi
}

# Helper for sequential tests - sets up environment and ensures prerequisites
#
# Sequential tests build on each other's state:
#   01-meta → 02-dist → 03-setup-final
#
# This function tracks prerequisites to enable running individual sequential tests.
# When you run a single test file, it automatically runs any prerequisites first.
#
# Example:
#   $ test/bats/bin/bats tests/02-dist.bats
#   # Automatically runs 01-meta first if not already complete
#
# This is critical for development workflow - you can test any part of the sequence
# without manually running earlier tests or maintaining test state yourself.
#
# The function also implements pollution detection: if tests run out of order or
# a test crashes, it detects the invalid state and rebuilds from scratch.
#
# Usage: setup_sequential_test "test-name" ["immediate-prereq"]
# Pass only ONE immediate prerequisite - it will handle its own dependencies recursively
#
# Examples:
#   setup_sequential_test "01-meta"           # First test, no prerequisites
#   setup_sequential_test "02-dist" "01-meta" # Depends on 01, which depends on foundation
#   setup_sequential_test "03-setup-final" "02-dist" # Depends on 02 → 01 → foundation
setup_sequential_test() {
  local test_name=$1
  local immediate_prereq=$2

  debug 2 "=== setup_sequential_test: test=$test_name prereq=$immediate_prereq PID=$$"
  debug 3 "    Caller: ${BASH_SOURCE[1]}:${BASH_LINENO[0]} in ${FUNCNAME[1]}"

  # Validate we're not called with too many prereqs
  if [ $# -gt 2 ]; then
    out "ERROR: setup_sequential_test called with $# arguments"
    out "Usage: setup_sequential_test \"test-name\" [\"immediate-prereq\"]"
    out "Pass only the immediate prerequisite, not the full chain"
    return 1
  fi

  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # 1. Load environment
  load_test_env "sequential" || return 1

  # 2. CREATE LOCK FIRST (prevents race conditions)
  create_pid_file "$test_name" || return 1

  # 3. Check if environment is clean
  if ! is_clean_state "$test_name"; then
    # Environment dirty - need to clean and rebuild
    # First remove our own lock so clean_env doesn't refuse
    rm -rf "$TEST_DIR/.bats-state/.lock-$test_name"
    clean_env "sequential" || return 1
    load_test_env "sequential" || return 1
    # Will handle prereqs below
  fi

  # 4. Ensure immediate prereq completed
  if [ -n "$immediate_prereq" ]; then
    debug 2 "setup_sequential_test: Checking prereq $immediate_prereq"
    if [ ! -f "$TEST_DIR/.bats-state/.complete-$immediate_prereq" ]; then
      # State marker doesn't exist - must run prerequisite
      # Individual @test blocks will skip if work is already done
      out "Running prerequisite: $immediate_prereq.bats"
      debug 2 "setup_sequential_test: Running prereq: bats $immediate_prereq.bats"
      # Run prereq (it handles its own deps recursively)
      # Filter stdout for TAP comments to FD3, leave stderr alone
      # OK to fail: grep returns non-zero if no matches, but we want empty output in that case
      "$BATS_TEST_DIRNAME/../test/bats/bin/bats" "$BATS_TEST_DIRNAME/$immediate_prereq.bats" | { grep '^#' || true; } >&3
      local prereq_status=${PIPESTATUS[0]}
      if [ $prereq_status -ne 0 ]; then
        out "ERROR: Prerequisite $immediate_prereq failed"
        rm -rf "$TEST_DIR/.bats-state/.lock-$test_name"
        return 1
      fi
      out "Prerequisite $immediate_prereq.bats completed"
    else
      debug 2 "setup_sequential_test: Prereq $immediate_prereq already complete"
    fi
  fi

  # 5. Re-acquire lock (might have been cleaned)
  create_pid_file "$test_name" || return 1

  # 6. Create .start marker
  mark_test_start "$test_name"

  export TOPDIR TEST_REPO TEST_DIR
}

# ============================================================================
# NON-SEQUENTIAL TEST SETUP
# ============================================================================
#
# **CRITICAL**: "Non-sequential" tests are NOT truly independent!
#
# These tests DEPEND on sequential tests (01-clone through 05-setup-final)
# having run successfully first. They copy the completed sequential environment
# to avoid re-running expensive setup steps.
#
# The term "non-sequential" means: "does not participate in sequential state
# building, but REQUIRES sequential tests to have completed first."
#
# DO NOT be misled by the name - these tests have MANDATORY prerequisites!
# ============================================================================

# Helper for non-sequential feature tests
# Usage: setup_nonsequential_test "test-doc" "doc" "05-setup-final"
#
# IMPORTANT: This function:
# 1. Creates a fresh isolated environment for this test
# 2. Runs ALL specified prerequisite tests (usually sequential tests 01-05)
# 3. Copies the completed sequential TEST_REPO to the new environment
# 4. This test then operates on that copy
#
# The test is "non-sequential" because it doesn't participate in sequential
# state building, but it DEPENDS on sequential tests completing first!
setup_nonsequential_test() {
  local test_name=$1
  local env_name=$2
  shift 2
  local prereq_tests=("$@")

  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # Always create fresh environment for non-sequential tests
  out "Creating fresh $env_name environment..."
  clean_env "$env_name" || return 1
  load_test_env "$env_name" || return 1

  # Run prerequisite chain
  if [ ${#prereq_tests[@]} -gt 0 ]; then
    # Check if prerequisites are sequential tests
    local has_sequential_prereqs=false
    for prereq in "${prereq_tests[@]}"; do
      if echo "$prereq" | grep -q "^[0-9][0-9]-"; then
        has_sequential_prereqs=true
        break
      fi
    done

    # If prerequisites are sequential and ANY already completed, clean to avoid pollution
    if [ "$has_sequential_prereqs" = true ]; then
      local sequential_state_dir="$TOPDIR/.envs/sequential/.bats-state"
      if [ -d "$sequential_state_dir" ] && ls "$sequential_state_dir"/.complete-* >/dev/null 2>&1; then
        out "Cleaning sequential environment to avoid pollution from previous test run..."
        # OK to fail: clean_env may fail if environment is locked, but we continue anyway
        clean_env "sequential" || true
      fi
    fi

    for prereq in "${prereq_tests[@]}"; do
      # Check if prerequisite is already complete
      local sequential_state_dir="$TOPDIR/.envs/sequential/.bats-state"
      if [ -f "$sequential_state_dir/.complete-$prereq" ]; then
        debug 3 "Prerequisite $prereq already complete, skipping"
        continue
      fi

      # State marker doesn't exist - must run prerequisite
      # Individual @test blocks will skip if work is already done
      out "Running prerequisite: $prereq.bats"
      # OK to fail: grep returns non-zero if no matches, but we want empty output in that case
      "$BATS_TEST_DIRNAME/../test/bats/bin/bats" "$BATS_TEST_DIRNAME/$prereq.bats" | { grep '^#' || true; } >&3
      [ ${PIPESTATUS[0]} -eq 0 ] || return 1
      out "Prerequisite $prereq.bats completed"
    done

    # Copy the sequential TEST_REPO to this non-sequential test's environment
    # THIS IS WHY NON-SEQUENTIAL TESTS DEPEND ON SEQUENTIAL TESTS!
    local sequential_repo="$TOPDIR/.envs/sequential/repo"
    if [ -d "$sequential_repo" ]; then
      out "Copying sequential TEST_REPO to $env_name environment..."
      cp -R "$sequential_repo" "$TEST_DIR/"
    fi
  fi

  export TOPDIR TEST_REPO TEST_DIR
}

# ============================================================================
# Foundation Management
# ============================================================================

# Ensure foundation environment exists and copy it to target environment
#
# The foundation is the base TEST_REPO that all tests depend on. It's created
# once in .envs/foundation/ and then copied to other test environments for speed.
#
# This function:
# 1. Checks if foundation exists (.envs/foundation/.bats-state/.foundation-complete)
# 2. If foundation exists but is > 10 seconds old, warns it may be stale
#    (important when testing changes to pgxntool itself)
# 3. If foundation doesn't exist, runs foundation.bats to create it
# 4. Copies foundation TEST_REPO to the target environment
#
# This allows any test to be run individually without manual setup - the test
# will automatically ensure foundation exists before running.
#
# Usage:
#   ensure_foundation "$TEST_DIR"
#
# Example in test file:
#   setup_file() {
#     load_test_env "my-test"
#     ensure_foundation "$TEST_DIR"  # Ensures foundation exists and copies it
#     # Now TEST_REPO exists and we can work with it
#   }
ensure_foundation() {
  local target_dir="$1"
  if [ -z "$target_dir" ]; then
    error "ensure_foundation: target_dir required"
  fi

  local foundation_dir="$TOPDIR/.envs/foundation"
  local foundation_state="$foundation_dir/.bats-state"
  local foundation_complete="$foundation_state/.foundation-complete"

  debug 2 "ensure_foundation: Checking foundation state"

  # Check if foundation exists
  if [ -f "$foundation_complete" ]; then
    debug 3 "ensure_foundation: Foundation exists, checking age"

    # Get current time and file modification time
    local now=$(date +%s)
    local mtime

    # Try BSD stat first (macOS), then GNU stat (Linux)
    if stat -f %m "$foundation_complete" >/dev/null 2>&1; then
      mtime=$(stat -f %m "$foundation_complete")
    elif stat -c %Y "$foundation_complete" >/dev/null 2>&1; then
      mtime=$(stat -c %Y "$foundation_complete")
    else
      # stat not available or different format, skip age check
      debug 3 "ensure_foundation: Cannot determine file age (stat unavailable)"
      mtime=$now
    fi

    local age=$((now - mtime))
    debug 3 "ensure_foundation: Foundation is $age seconds old"

    if [ $age -gt 10 ]; then
      out "WARNING: Foundation is $age seconds old, may be out of date."
      out "         If you've modified pgxntool, run 'make foundation' to rebuild."
    fi
  else
    debug 2 "ensure_foundation: Foundation doesn't exist, creating..."
    out "Creating foundation environment..."

    # Run foundation.bats to create it
    # OK to fail: grep returns non-zero if no matches, but we want empty output in that case
    "$BATS_TEST_DIRNAME/../test/bats/bin/bats" "$BATS_TEST_DIRNAME/foundation.bats" | { grep '^#' || true; } >&3
    local status=${PIPESTATUS[0]}

    if [ $status -ne 0 ]; then
      error "Failed to create foundation environment"
    fi

    out "Foundation created successfully"
  fi

  # Copy foundation TEST_REPO to target environment
  local foundation_repo="$foundation_dir/repo"
  local target_repo="$target_dir/repo"

  if [ ! -d "$foundation_repo" ]; then
    error "Foundation repo not found at $foundation_repo"
  fi

  debug 2 "ensure_foundation: Copying foundation to $target_dir"
  # Use rsync to avoid permission issues with git objects
  rsync -a "$foundation_repo/" "$target_repo/"

  if [ ! -d "$target_repo" ]; then
    error "Failed to copy foundation repo to $target_repo"
  fi

  # Also copy fake_repo if it exists (needed for git push operations)
  local foundation_fake="$foundation_dir/fake_repo"
  local target_fake="$target_dir/fake_repo"
  if [ -d "$foundation_fake" ]; then
    debug 3 "ensure_foundation: Copying fake_repo"
    rsync -a "$foundation_fake/" "$target_fake/"
  fi

  debug 3 "ensure_foundation: Foundation copied successfully"
}

# vi: expandtab sw=2 ts=2
