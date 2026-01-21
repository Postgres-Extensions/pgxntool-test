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
# Note: BATS resolves load paths relative to the test file, not this file.
# Since test files load this as ../lib/helpers, we need to use ../lib/assertions
# to find assertions.bash in the same directory as this file.
load ../lib/assertions

# Set TOPDIR to the repository root
# This function should be called in setup_file() before using TOPDIR
# It works from any test file location (test/standard/, test/sequential/, test/lib/, etc.)
# Supports both regular git repositories (.git directory) and git worktrees (.git file)
setup_topdir() {
  if [ -z "$TOPDIR" ]; then
    # Try to find repo root by looking for .git (directory or file for worktrees)
    local dir="${BATS_TEST_DIRNAME:-.}"
    while [ "$dir" != "/" ] && [ ! -e "$dir/.git" ]; do
      dir=$(dirname "$dir")
    done
    if [ -e "$dir/.git" ]; then
      export TOPDIR="$dir"
    else
      error "Cannot determine TOPDIR: no .git found from ${BATS_TEST_DIRNAME}. Tests must be run from within the repository."
      return 1
    fi
  fi
}

# Output to terminal (always visible)
# Usage: out "message"
#        out -f "message"  # flush immediately (for piped output)
# Outputs to FD 3 which BATS sends directly to terminal
# The -f flag uses a space+backspace trick to force immediate flushing when piped.
# See https://stackoverflow.com/questions/68759687 for why this works.
out() {
  local prefix=''
  if [ "$1" = "-f" ]; then
    prefix=' \b'
    shift
  fi
  echo -e "$prefix# $*" >&3
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
    out -f "DEBUG[$level]: $message"
  fi
}

# Clean (remove) a test environment safely
# Checks for running tests via lock directories before removing
# Usage: clean_env "sequential"
clean_env() {
  local env_name=$1
  local env_dir="$TOPDIR/test/.envs/$env_name"

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
  if [[ "$env_dir" != "$TOPDIR/test/.envs/"* ]]; then
    error "Refusing to clean directory outside .envs: $env_dir"
  fi

  rm -rf "$env_dir"
  debug 5 "clean_env: Successfully removed $env_dir"
}

# Create a new isolated test environment
# Usage: create_env "sequential" or create_env "doc"
create_env() {
  local env_name=$1
  local env_dir="$TOPDIR/test/.envs/$env_name"

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
  TEST_TEMPLATE=${TEST_TEMPLATE:-${TOPDIR}/template}
  TEST_REPO=${TEST_DIR}/repo
  debug_vars 3 PGXNBRANCH PGXNREPO TEST_TEMPLATE TEST_REPO

  # Normalize repository paths
  PG_LOCATION=$(pg_config --bindir | sed 's#/bin##')
  PGXNREPO=$(find_repo "$PGXNREPO")
  # TEST_TEMPLATE is now a local directory, not a repository
  debug_vars 5 PG_LOCATION PGXNREPO TEST_TEMPLATE

  # Export for use in tests
  export PGXNBRANCH PGXNREPO TEST_TEMPLATE TEST_REPO PG_LOCATION
}

# Load test environment for given environment name
# Auto-creates the environment if it doesn't exist
# Usage: load_test_env "sequential" or load_test_env "doc"
# Note: TOPDIR must be set before calling this function (use setup_topdir() in setup_file)
load_test_env() {
  local env_name=${1:-sequential}
  # Ensure TOPDIR is set
  if [ -z "$TOPDIR" ]; then
    setup_topdir
  fi
  local env_file="$TOPDIR/test/.envs/$env_name/.env"

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
  local test_order=$(cd "$TOPDIR/test/sequential" && ls [0-9][0-9]-*.bats 2>/dev/null | sort | sed 's/\.bats$//' | xargs)

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

  # Ensure TOPDIR is set
  if [ -z "$TOPDIR" ]; then
    setup_topdir
  fi

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

    # Foundation is special - it has its own environment with its own completion marker
    # Check foundation's own marker, not sequential's copy
    local prereq_complete_marker
    if [ "$immediate_prereq" = "foundation" ]; then
      prereq_complete_marker="$TOPDIR/test/.envs/foundation/.bats-state/.foundation-complete"
    else
      prereq_complete_marker="$TEST_DIR/.bats-state/.complete-$immediate_prereq"
    fi

    if [ ! -f "$prereq_complete_marker" ]; then
      # State marker doesn't exist - must run prerequisite
      # Individual @test blocks will skip if work is already done
      out "Running prerequisite: $immediate_prereq.bats"
      debug 2 "setup_sequential_test: Running prereq: bats $immediate_prereq.bats"
      # Run prereq (it handles its own deps recursively)
      # Filter stdout for TAP comments to FD3, leave stderr alone
      # OK to fail: grep returns non-zero if no matches, but we want empty output in that case

      # Special case: foundation.bats lives in test/lib/, not test/sequential/
      local prereq_path
      if [ "$immediate_prereq" = "foundation" ]; then
        prereq_path="$TOPDIR/test/lib/foundation.bats"
      else
        prereq_path="$BATS_TEST_DIRNAME/$immediate_prereq.bats"
      fi

      debug 3 "Prerequisite path: $prereq_path"
      debug 3 "Running: $TOPDIR/test/bats/bin/bats $prereq_path"

      "$TOPDIR/test/bats/bin/bats" "$prereq_path" | { grep '^#' || true; } >&3
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
      local sequential_state_dir="$TOPDIR/test/.envs/sequential/.bats-state"
      if [ -d "$sequential_state_dir" ] && ls "$sequential_state_dir"/.complete-* >/dev/null 2>&1; then
        out "Cleaning sequential environment to avoid pollution from previous test run..."
        # OK to fail: clean_env may fail if environment is locked, but we continue anyway
        clean_env "sequential" || true
      fi
    fi

    for prereq in "${prereq_tests[@]}"; do
      # Check if prerequisite is already complete
      local sequential_state_dir="$TOPDIR/test/.envs/sequential/.bats-state"
      if [ -f "$sequential_state_dir/.complete-$prereq" ]; then
        debug 3 "Prerequisite $prereq already complete, skipping"
        continue
      fi

      # State marker doesn't exist - must run prerequisite
      # Individual @test blocks will skip if work is already done
      out "Running prerequisite: $prereq.bats"
      # OK to fail: grep returns non-zero if no matches, but we want empty output in that case

      # Special case: foundation.bats lives in test/lib/, not test/sequential/
      local prereq_path
      if [ "$prereq" = "foundation" ]; then
        prereq_path="$TOPDIR/test/lib/foundation.bats"
      else
        prereq_path="$BATS_TEST_DIRNAME/$prereq.bats"
      fi

      "$TOPDIR/test/bats/bin/bats" "$prereq_path" | { grep '^#' || true; } >&3
      [ ${PIPESTATUS[0]} -eq 0 ] || return 1
      out "Prerequisite $prereq.bats completed"
    done

    # Copy the sequential TEST_REPO to this non-sequential test's environment
    # THIS IS WHY NON-SEQUENTIAL TESTS DEPEND ON SEQUENTIAL TESTS!
    local sequential_repo="$TOPDIR/test/.envs/sequential/repo"
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

  local foundation_dir="$TOPDIR/test/.envs/foundation"
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

    if [ $age -gt 60 ]; then
      out "WARNING: Foundation is $age seconds old, may be out of date."
      out "         If you've modified pgxntool, run 'make foundation' to rebuild."
    fi
  else
    debug 2 "ensure_foundation: Foundation doesn't exist, creating..."
    out "Creating foundation environment..."

    # Run foundation.bats to create it
    # Note: foundation.bats is in test/lib/ (same directory as helpers.bash)
    # Use TOPDIR to find bats binary (test/bats/bin/bats relative to repo root)
    # OK to fail: grep returns non-zero if no matches, but we want empty output in that case
    if [ -z "$TOPDIR" ]; then
      setup_topdir
    fi
    "$TOPDIR/test/bats/bin/bats" "$TOPDIR/test/lib/foundation.bats" | { grep '^#' || true; } >&3
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

# ============================================================================
# PostgreSQL Availability Detection
# ============================================================================

# Global variable to cache PostgreSQL availability check result
# Values: 0 (available), 1 (unavailable), or "" (not checked yet)
_POSTGRES_AVAILABLE=""

# Check if PostgreSQL is available and running
#
# This function performs a comprehensive check:
# 1. Checks if pg_config is available (PostgreSQL development tools installed)
# 2. Checks if psql is available (PostgreSQL client installed)
# 3. Checks if PostgreSQL server is running (attempts connection using plain `psql`)
#
# IMPORTANT: This function assumes the user has configured PostgreSQL environment
# variables (PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD, etc.) so that a plain
# `psql` command works without additional flags. This keeps the test framework simple.
#
# The result is cached in _POSTGRES_AVAILABLE to avoid repeated expensive checks.
#
# Usage:
#   if ! check_postgres_available; then
#     skip "PostgreSQL not available: $POSTGRES_UNAVAILABLE_REASON"
#   fi
#
# Or use the convenience function:
#   skip_if_no_postgres
#
# Returns:
#   0 if PostgreSQL is available and running
#   1 if PostgreSQL is not available (with reason in POSTGRES_UNAVAILABLE_REASON)
check_postgres_available() {
  # Return cached result if available
  if [ -n "${_POSTGRES_AVAILABLE:-}" ]; then
    return $_POSTGRES_AVAILABLE
  fi

  # Reset reason variable
  POSTGRES_UNAVAILABLE_REASON=""

  # Check 1: pg_config available
  if ! command -v pg_config >/dev/null 2>&1; then
    POSTGRES_UNAVAILABLE_REASON="pg_config not found (PostgreSQL development tools not installed)"
    _POSTGRES_AVAILABLE=1
    return 1
  fi

  # Check 2: psql available
  local psql_path
  psql_path=$(get_psql_path)
  if [ -z "$psql_path" ]; then
    POSTGRES_UNAVAILABLE_REASON="psql not found (PostgreSQL client not installed)"
    _POSTGRES_AVAILABLE=1
    return 1
  fi

  # Check 3: PostgreSQL server running
  # Assume user has configured environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE, etc.)
  # so that a plain `psql` command works. This keeps the test framework simple.
  local connect_error
  if ! connect_error=$("$psql_path" -c "SELECT 1;" 2>&1); then
    # Determine the specific reason
    if echo "$connect_error" | grep -qi "could not connect\|connection refused\|connection timed out\|no such file or directory"; then
      POSTGRES_UNAVAILABLE_REASON="PostgreSQL server not running or not accessible (check PGHOST, PGPORT, etc.)"
    elif echo "$connect_error" | grep -qi "password authentication failed"; then
      POSTGRES_UNAVAILABLE_REASON="PostgreSQL authentication failed (check PGPASSWORD, .pgpass, or pg_hba.conf)"
    elif echo "$connect_error" | grep -qi "role.*does not exist\|database.*does not exist"; then
      POSTGRES_UNAVAILABLE_REASON="PostgreSQL user/database not found (check PGUSER, PGDATABASE, etc.)"
    else
      # Use first 5 lines of error for context
      POSTGRES_UNAVAILABLE_REASON="PostgreSQL not accessible: $(echo "$connect_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
    fi
    _POSTGRES_AVAILABLE=1
    return 1
  fi

  # All checks passed
  _POSTGRES_AVAILABLE=0
  return 0
}

# Convenience function to skip test if PostgreSQL is not available
#
# Usage:
#   @test "my test that needs PostgreSQL" {
#     skip_if_no_postgres
#     # ... rest of test ...
#   }
#
# This function:
# - Checks PostgreSQL availability (cached after first check)
# - Skips the test with a helpful message if unavailable
# - Does nothing if PostgreSQL is available
skip_if_no_postgres() {
  if ! check_postgres_available; then
    skip "PostgreSQL not available: $POSTGRES_UNAVAILABLE_REASON"
  fi
}

# Global variable to cache psql path
# Value: path to psql executable, "__NOT_FOUND__" (checked but not found), or unset (not checked yet)
_PSQL_PATH=""

# Get psql executable path
# Returns path to psql or empty string if not found
# Caches result in _PSQL_PATH to avoid repeated lookups
# Uses "__NOT_FOUND__" as magic value to cache "checked but not found" state
get_psql_path() {
  # Return cached result if available
  if [ -n "${_PSQL_PATH:-}" ]; then
    if [ "$_PSQL_PATH" = "__NOT_FOUND__" ]; then
      echo
      return 1
    else
      echo "$_PSQL_PATH"
      return 0
    fi
  fi

  local psql_path
  if ! psql_path=$(command -v psql 2>/dev/null); then
    # Try to find psql via pg_config
    local pg_bindir
    pg_bindir=$(pg_config --bindir 2>/dev/null || echo)
    if [ -n "$pg_bindir" ] && [ -x "$pg_bindir/psql" ]; then
      psql_path="$pg_bindir/psql"
    else
      _PSQL_PATH="__NOT_FOUND__"
      echo
      return 1
    fi
  fi
  _PSQL_PATH="$psql_path"
  echo "$psql_path"
  return 0
}

# Check if pg_tle extension is available in the PostgreSQL cluster
#
# This function checks if:
# - PostgreSQL is available (reuses check_postgres_available)
# - pg_tle extension is available in the cluster (can be created with CREATE EXTENSION)
#
# Note: This checks for availability at the cluster level, not whether
# the extension has been created in a specific database.
#
# Sets global variable _PGTLE_AVAILABLE to 0 (available) or 1 (unavailable)
# Sets PGTLE_UNAVAILABLE_REASON with helpful error message
# Returns 0 if available, 1 if not
check_pgtle_available() {
  # Use cached result if available (check FIRST)
  if [ -n "${_PGTLE_AVAILABLE:-}" ]; then
    return $_PGTLE_AVAILABLE
  fi

  # First check if PostgreSQL is available
  if ! check_postgres_available; then
    PGTLE_UNAVAILABLE_REASON="PostgreSQL not available: $POSTGRES_UNAVAILABLE_REASON"
    _PGTLE_AVAILABLE=1
    return 1
  fi

  # Reset reason variable
  PGTLE_UNAVAILABLE_REASON=""

  # Get psql path
  local psql_path
  psql_path=$(get_psql_path)
  if [ -z "$psql_path" ]; then
    PGTLE_UNAVAILABLE_REASON="psql not found"
    _PGTLE_AVAILABLE=1
    return 1
  fi

  # Check if pg_tle is available in cluster
  # pg_available_extensions shows extensions that can be created with CREATE EXTENSION
  # Use -X to ignore .psqlrc which may add timing or other output
  local pgtle_available
  if ! pgtle_available=$("$psql_path" -X -tAc "SELECT EXISTS(SELECT 1 FROM pg_available_extensions WHERE name = 'pg_tle');" 2>&1); then
    PGTLE_UNAVAILABLE_REASON="Failed to query pg_available_extensions: $(echo "$pgtle_available" | head -5 | tr '\n' '; ' | sed 's/; $//')"
    _PGTLE_AVAILABLE=1
    return 1
  fi

  # Trim whitespace and newlines from result
  pgtle_available=$(echo "$pgtle_available" | tr -d '[:space:]')

  if [ "$pgtle_available" != "t" ]; then
    PGTLE_UNAVAILABLE_REASON="pg_tle extension not available in cluster (install pg_tle extension first)"
    _PGTLE_AVAILABLE=1
    return 1
  fi

  # All checks passed
  _PGTLE_AVAILABLE=0
  return 0
}

# Convenience function to skip test if pg_tle is not available
#
# Usage:
#   @test "my test that needs pg_tle" {
#     skip_if_no_pgtle
#     # ... rest of test ...
#   }
#
# This function:
# - Checks pg_tle availability (cached after first check)
# - Skips the test with a helpful message if unavailable
# - Does nothing if pg_tle is available
skip_if_no_pgtle() {
  if ! check_pgtle_available; then
    skip "pg_tle not available: $PGTLE_UNAVAILABLE_REASON"
  fi
}

# ============================================================================
# Directory Management
# ============================================================================

# Change directory with assertion
# Usage: assert_cd "directory"
#
# This function attempts to change to the specified directory and errors out
# with a clear message if the cd fails. This is safer than bare `cd` commands
# which can fail silently or cause confusing test failures.
#
# Examples:
#   assert_cd "$TEST_REPO"
#   assert_cd "$TEST_DIR"
#   assert_cd /tmp
assert_cd() {
  local target_dir="$1"

  if [ -z "$target_dir" ]; then
    error "assert_cd: directory argument required"
  fi

  if ! cd "$target_dir" 2>/dev/null; then
    error "Failed to cd to directory: $target_dir"
  fi

  debug 5 "Changed directory to: $PWD"
  return 0
}

# Change to the test environment directory
# Usage: cd_test_env
#
# This convenience function changes to TEST_REPO for tests that need to be
# in the repository directory. For tests that run before TEST_REPO exists,
# use assert_cd() directly instead.
#
# Examples:
#   cd_test_env  # Changes to TEST_REPO
#   assert_cd "$TEST_DIR"  # For early foundation tests
cd_test_env() {
  # Only handles the common case: cd to TEST_REPO
  # For other cases, use assert_cd() directly
  assert_cd "$TEST_REPO"
}

# Global variable to cache current pg_tle extension version
# Format: "version" (e.g., "1.4.0") or "" if not created
_PGTLE_CURRENT_VERSION=""

# Global variable to track if we've checked pg_tle version
# Values: "checked" or "" (not checked yet)
_PGTLE_VERSION_CHECKED=""

# Ensure pg_tle extension is created/updated
#
# This function ensures the pg_tle extension exists in the database at the
# requested version. It caches the current version to avoid repeated queries.
#
# Usage:
#   ensure_pgtle_extension [version]
#
# Arguments:
#   version (optional): Specific pg_tle version to install (e.g., "1.4.0")
#                       If not provided, creates extension or updates to newest
#
# Behavior:
#   - If no version specified:
#     * Creates extension if it doesn't exist
#     * Updates to newest version if it exists but is not latest
#   - If version specified:
#     * Creates at that version if extension doesn't exist
#     * Updates to that version if different version is installed
#     * Drops and recreates if needed to change version
#
# Caching:
#   - Caches current version in _PGTLE_CURRENT_VERSION
#   - Only queries database once per test run
#
# Error handling:
#   - Sets PGTLE_EXTENSION_ERROR with helpful error message on failure
#   - Returns 0 on success, 1 on failure
#
# Example:
#   ensure_pgtle_extension || skip "pg_tle extension cannot be created: $PGTLE_EXTENSION_ERROR"
#   ensure_pgtle_extension "1.4.0" || skip "Cannot install pg_tle 1.4.0: $PGTLE_EXTENSION_ERROR"
#
# Reset pg_tle cache
# Clears cached version information so it will be re-checked
reset_pgtle_cache() {
  _PGTLE_VERSION_CHECKED=""
  _PGTLE_CURRENT_VERSION=""
}

ensure_pgtle_extension() {
  local requested_version="${1:-}"
  
  # First ensure PostgreSQL is available
  if ! check_postgres_available; then
    PGTLE_EXTENSION_ERROR="PostgreSQL not available: $POSTGRES_UNAVAILABLE_REASON"
    return 1
  fi
  
  # Get psql path
  local psql_path
  psql_path=$(get_psql_path)
  if [ -z "$psql_path" ]; then
    PGTLE_EXTENSION_ERROR="psql not found"
    return 1
  fi
  
  # Check current version if not cached
  if [ "$_PGTLE_VERSION_CHECKED" != "checked" ]; then
    _PGTLE_CURRENT_VERSION=$("$psql_path" -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_tle';" 2>/dev/null | tr -d '[:space:]' || echo)
    _PGTLE_VERSION_CHECKED="checked"
  fi
  
  # Reset error variable
  PGTLE_EXTENSION_ERROR=""
  
  # If no version requested, create or update to newest
  if [ -z "$requested_version" ]; then
    if [ -z "$_PGTLE_CURRENT_VERSION" ]; then
      # Extension doesn't exist, create it
      local create_error
      if ! create_error=$("$psql_path" -X -c "CREATE EXTENSION pg_tle;" 2>&1); then
        # Determine the specific reason
        if echo "$create_error" | grep -qi "shared_preload_libraries"; then
          PGTLE_EXTENSION_ERROR="pg_tle not configured in shared_preload_libraries (add 'pg_tle' to shared_preload_libraries in postgresql.conf and restart PostgreSQL)"
        elif echo "$create_error" | grep -qi "extension.*already exists"; then
          # Extension exists but wasn't in cache, refresh cache and continue
          _PGTLE_CURRENT_VERSION=$("$psql_path" -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_tle';" 2>/dev/null | tr -d '[:space:]' || echo)
        else
          # Use first 5 lines of error for context
          PGTLE_EXTENSION_ERROR="Failed to create pg_tle extension: $(echo "$create_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
        fi
        if [ -n "$PGTLE_EXTENSION_ERROR" ]; then
          return 1
        fi
      fi
      # Update cache after creation
      _PGTLE_CURRENT_VERSION=$("$psql_path" -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_tle';" 2>/dev/null | tr -d '[:space:]' || echo)
    else
      # Extension exists, check if update needed
      local newest_version
      newest_version=$("$psql_path" -X -tAc "SELECT MAX(version) FROM pg_available_extension_versions WHERE name = 'pg_tle';" 2>/dev/null | tr -d '[:space:]' || echo)
      if [ -n "$newest_version" ] && [ "$_PGTLE_CURRENT_VERSION" != "$newest_version" ]; then
        local update_error
        if ! update_error=$("$psql_path" -X -c "ALTER EXTENSION pg_tle UPDATE;" 2>&1); then
          PGTLE_EXTENSION_ERROR="Failed to update pg_tle extension: $(echo "$update_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
          return 1
        fi
        # Update cache
        _PGTLE_CURRENT_VERSION=$("$psql_path" -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_tle';" 2>/dev/null | tr -d '[:space:]' || echo)
      fi
    fi
  else
    # Version specified - ensure extension is at that version
    if [ -z "$_PGTLE_CURRENT_VERSION" ]; then
      # Extension doesn't exist, create at requested version
      local create_error
      if ! create_error=$("$psql_path" -X -c "CREATE EXTENSION pg_tle VERSION '$requested_version';" 2>&1); then
        if echo "$create_error" | grep -qi "shared_preload_libraries"; then
          PGTLE_EXTENSION_ERROR="pg_tle not configured in shared_preload_libraries (add 'pg_tle' to shared_preload_libraries in postgresql.conf and restart PostgreSQL)"
        elif echo "$create_error" | grep -qi "version.*does not exist"; then
          PGTLE_EXTENSION_ERROR="pg_tle version '$requested_version' not available in cluster"
        else
          PGTLE_EXTENSION_ERROR="Failed to create pg_tle extension at version '$requested_version': $(echo "$create_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
        fi
        return 1
      fi
      # Update cache
      _PGTLE_CURRENT_VERSION=$("$psql_path" -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_tle';" 2>/dev/null | tr -d '[:space:]' || echo)
    elif [ "$_PGTLE_CURRENT_VERSION" != "$requested_version" ]; then
      # Extension exists at different version, try to update first
      local update_error
      if ! update_error=$("$psql_path" -X -c "ALTER EXTENSION pg_tle UPDATE TO '$requested_version';" 2>&1); then
        # Update failed, may need to drop and recreate
        if echo "$update_error" | grep -qi "version.*does not exist\|cannot.*update"; then
          # Version doesn't exist or can't update directly, drop and recreate
          local drop_error
          if ! drop_error=$("$psql_path" -X -c "DROP EXTENSION pg_tle CASCADE;" 2>&1); then
            PGTLE_EXTENSION_ERROR="Failed to drop pg_tle extension: $(echo "$drop_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
            return 1
          fi
          # Now create at requested version
          if ! create_error=$("$psql_path" -X -c "CREATE EXTENSION pg_tle VERSION '$requested_version';" 2>&1); then
            if echo "$create_error" | grep -qi "version.*does not exist"; then
              PGTLE_EXTENSION_ERROR="pg_tle version '$requested_version' not available in cluster"
            else
              PGTLE_EXTENSION_ERROR="Failed to create pg_tle extension at version '$requested_version': $(echo "$create_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
            fi
            return 1
          fi
        elif echo "$update_error" | grep -qi "extension.*does not exist"; then
          # Extension doesn't exist (cache was stale), create it
          if ! create_error=$("$psql_path" -X -c "CREATE EXTENSION pg_tle VERSION '$requested_version';" 2>&1); then
            if echo "$create_error" | grep -qi "version.*does not exist"; then
              PGTLE_EXTENSION_ERROR="pg_tle version '$requested_version' not available in cluster"
            else
              PGTLE_EXTENSION_ERROR="Failed to create pg_tle extension at version '$requested_version': $(echo "$create_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
            fi
            return 1
          fi
        else
          PGTLE_EXTENSION_ERROR="Failed to update pg_tle extension to version '$requested_version': $(echo "$update_error" | head -5 | tr '\n' '; ' | sed 's/; $//')"
          return 1
        fi
      fi
      # Update cache
      _PGTLE_CURRENT_VERSION=$("$psql_path" -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_tle';" 2>/dev/null | tr -d '[:space:]' || echo)
    fi
    # Verify we're at the requested version
    if [ "$_PGTLE_CURRENT_VERSION" != "$requested_version" ]; then
      PGTLE_EXTENSION_ERROR="pg_tle extension is at version '$_PGTLE_CURRENT_VERSION', not requested version '$requested_version'"
      return 1
    fi
  fi
  
  return 0
}

# ============================================================================
# Custom Template Repository Building
# ============================================================================

# Build a test repository from a custom template
#
# This function creates a fully set up test repository from a template directory,
# similar to what foundation.bats does but with a custom template. It handles:
# 1. Creating TEST_REPO directory
# 2. Initializing git
# 3. Copying template files
# 4. Committing template files
# 5. Configuring fake remote
# 6. Adding pgxntool (via subtree or rsync if dirty)
# 7. Running setup.sh
# 8. Committing setup changes
#
# Usage:
#   build_test_repo_from_template "$template_dir"
#
# Arguments:
#   template_dir: Path to the template directory to copy from
#
# Prerequisites:
#   - TOPDIR must be set (call setup_topdir() first)
#   - TEST_DIR and TEST_REPO must be set (call load_test_env() first)
#   - PGXNREPO and PGXNBRANCH must be set (done by load_test_env via setup_pgxntool_vars)
#
# Returns:
#   0 on success, 1 on failure
#
# After calling this function, TEST_REPO will be a fully initialized repository
# with pgxntool added and setup.sh run, ready for testing.
#
# Example:
#   setup_file() {
#     setup_topdir
#     load_test_env "my-test"
#     build_test_repo_from_template "${TOPDIR}/my-custom-template"
#   }
build_test_repo_from_template() {
  local template_dir="$1"

  if [ -z "$template_dir" ]; then
    error "build_test_repo_from_template: template_dir required"
  fi

  if [ ! -d "$template_dir" ]; then
    error "build_test_repo_from_template: template directory does not exist: $template_dir"
  fi

  # Validate prerequisites
  if [ -z "$TOPDIR" ]; then
    error "build_test_repo_from_template: TOPDIR not set (call setup_topdir first)"
  fi
  if [ -z "$TEST_DIR" ]; then
    error "build_test_repo_from_template: TEST_DIR not set (call load_test_env first)"
  fi
  if [ -z "$TEST_REPO" ]; then
    error "build_test_repo_from_template: TEST_REPO not set (call load_test_env first)"
  fi
  if [ -z "$PGXNREPO" ]; then
    error "build_test_repo_from_template: PGXNREPO not set"
  fi
  if [ -z "$PGXNBRANCH" ]; then
    error "build_test_repo_from_template: PGXNBRANCH not set"
  fi

  debug 2 "build_test_repo_from_template: Building from $template_dir"

  # Step 1: Create TEST_REPO directory
  if [ -d "$TEST_REPO" ]; then
    error "build_test_repo_from_template: TEST_REPO already exists: $TEST_REPO"
  fi
  mkdir "$TEST_REPO" || {
    error "build_test_repo_from_template: Failed to create TEST_REPO"
  }

  # Step 2: Initialize git repository
  (cd "$TEST_REPO" && git init) || {
    error "build_test_repo_from_template: git init failed"
  }

  # Step 3: Copy template files
  rsync -a --exclude='.DS_Store' "$template_dir"/ "$TEST_REPO"/ || {
    error "build_test_repo_from_template: Failed to copy template files"
  }

  # Step 4: Commit template files
  (cd "$TEST_REPO" && git add . && git commit -m "Initial extension files from template") || {
    error "build_test_repo_from_template: Failed to commit template files"
  }

  # Step 5: Configure fake remote
  git init --bare "${TEST_DIR}/fake_repo" >/dev/null 2>&1 || {
    error "build_test_repo_from_template: Failed to create fake remote"
  }
  (cd "$TEST_REPO" && git remote add origin "${TEST_DIR}/fake_repo") || {
    error "build_test_repo_from_template: Failed to add origin remote"
  }
  local current_branch
  current_branch=$(cd "$TEST_REPO" && git symbolic-ref --short HEAD)
  (cd "$TEST_REPO" && git push --set-upstream origin "$current_branch") || {
    error "build_test_repo_from_template: Failed to push to fake remote"
  }

  # Step 6: Add pgxntool
  # Wait for filesystem timestamp granularity
  sleep 1
  (cd "$TEST_REPO" && git update-index --refresh) || {
    error "build_test_repo_from_template: git update-index failed"
  }

  # Check if pgxntool repo is dirty
  local source_is_dirty=0
  if [ -d "$PGXNREPO/.git" ]; then
    if [ -n "$(cd "$PGXNREPO" && git status --porcelain)" ]; then
      source_is_dirty=1
      local pgxn_branch
      pgxn_branch=$(cd "$PGXNREPO" && git symbolic-ref --short HEAD)

      if [ "$pgxn_branch" != "$PGXNBRANCH" ]; then
        error "build_test_repo_from_template: Source repo is dirty but on wrong branch ($pgxn_branch, expected $PGXNBRANCH)"
      fi

      out "Source repo is dirty and on correct branch, using rsync instead of git subtree"

      mkdir "$TEST_REPO/pgxntool" || {
        error "build_test_repo_from_template: Failed to create pgxntool directory"
      }
      rsync -a "$PGXNREPO/" "$TEST_REPO/pgxntool/" --exclude=.git || {
        error "build_test_repo_from_template: Failed to rsync pgxntool"
      }
      (cd "$TEST_REPO" && git add --all && git commit -m "Committing unsaved pgxntool changes") || {
        error "build_test_repo_from_template: Failed to commit pgxntool files"
      }
    fi
  fi

  # If source wasn't dirty, use git subtree
  if [ $source_is_dirty -eq 0 ]; then
    (cd "$TEST_REPO" && git subtree add -P pgxntool --squash "$PGXNREPO" "$PGXNBRANCH") || {
      error "build_test_repo_from_template: git subtree add failed"
    }
  fi

  # Verify pgxntool was added
  if [ ! -f "$TEST_REPO/pgxntool/base.mk" ]; then
    error "build_test_repo_from_template: pgxntool/base.mk not found after adding pgxntool"
  fi

  # Step 7: Run setup.sh
  # Verify repo is clean first
  local porcelain_output
  porcelain_output=$(cd "$TEST_REPO" && git status --porcelain)
  if [ -n "$porcelain_output" ]; then
    error "build_test_repo_from_template: Repository is dirty before setup.sh"
  fi

  (cd "$TEST_REPO" && ./pgxntool/setup.sh) || {
    error "build_test_repo_from_template: setup.sh failed"
  }

  # Verify Makefile was created
  if [ ! -f "$TEST_REPO/Makefile" ]; then
    error "build_test_repo_from_template: Makefile not created by setup.sh"
  fi

  # Step 8: Commit setup changes
  (cd "$TEST_REPO" && git commit -am "Add pgxntool setup") || {
    error "build_test_repo_from_template: Failed to commit setup changes"
  }

  debug 2 "build_test_repo_from_template: Successfully built repository"
  return 0
}

# vi: expandtab sw=2 ts=2
