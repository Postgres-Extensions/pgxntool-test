#!/usr/bin/env bash
# run-tests.sh - Test runner with TAP parsing and progress tracking
#
# Usage: run-tests.sh [make-target-or-bats-files...]
#   Default: test-all
#   Accepts: test, test-extra, test-all, or specific .bats file paths
#   When specific .bats files given, runs test/bats/bin/bats directly

set -euo pipefail

# Set PGPORT from PGCLUSTER if not already set, so pg_regress and other raw
# PostgreSQL binaries use the correct cluster (Debian pg_wrapper handles
# PGCLUSTER but raw binaries only respect PGPORT).
if [ -z "${PGPORT:-}" ] && [ -n "${PGCLUSTER:-}" ]; then
    _port=$(pg_lsclusters -h 2>/dev/null | awk -v c="$PGCLUSTER" \
        'BEGIN{split(c,a,"/"); v=a[1]; n=a[2]} $1==v && $2==n {print $3; exit}')
    [ -n "$_port" ] && export PGPORT=$_port
    unset _port
fi

# Determine log directory (per-project, based on working directory)
LOG_DIR="/tmp/pgxntool-test-logs$(pwd | sed 's/\//_/g')"
mkdir -p "$LOG_DIR"

# Prevent parallel test runs - tests share state and CANNOT run concurrently
LOCK_FILE="$LOG_DIR/lock"
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE")
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "ERROR: Tests already running (PID $LOCK_PID). Tests CANNOT run in parallel." >&2
    echo "If this is stale, remove: $LOCK_FILE" >&2
    exit 1
  fi
  # Stale lock - previous run crashed
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

TIMESTAMP=$(date +%Y%m%dT%H%M%S)
FULL_LOG="$LOG_DIR/test-full-${TIMESTAMP}.log"
ERRORS_LOG="$LOG_DIR/test-errors-${TIMESTAMP}.log"
SKIPS_LOG="$LOG_DIR/test-skips-${TIMESTAMP}.log"
STATUS_FILE="$LOG_DIR/status"

# Determine what to run
TARGET="${1:-test-all}"
shift 2>/dev/null || true

# Build the argv; arguments are passed through literally, never re-parsed by a shell.
if [[ "$TARGET" == *.bats ]]; then
  # Specific bats file(s)
  CMD=(test/bats/bin/bats "$TARGET" "$@")
else
  # Make target
  CMD=(make "$TARGET")
fi

# Initialize status file
cat > "$STATUS_FILE" <<EOF
STATE: RUNNING
SUITES: 0
TESTS: 0/0 passed, 0 failed, 0 skipped
CURRENT_SUITE: (starting)
LAST: (none)
EOF

# Counters
SUITES=0
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
CURRENT_SUITE=""
EXIT_CODE=0

# A direct .bats run needs the submodule; let make initialize it first (output goes to the
# full log, and a failure there is the run's failure).
run_cmd() {
  if [[ "$TARGET" == *.bats ]]; then
    make test/bats/bin/bats && "${CMD[@]}"
  else
    "${CMD[@]}"
  fi
}

# Run tests, capturing output and parsing TAP in real-time. The while loop runs in a
# subshell, so the command's status is taken from PIPESTATUS in the parent. Under pipefail
# a zero there means tee or the read loop failed, which still counts as a failure.
run_cmd 2>&1 | tee "$FULL_LOG" | while IFS= read -r line; do
  # Detect new suite (TAP plan line: 1..N)
  if [[ "$line" =~ ^1\.\. ]]; then
    SUITES=$((SUITES + 1))
    # Try to extract suite name from preceding output
    CURRENT_SUITE="suite-$SUITES"
  fi

  # Detect suite file header (bats outputs "File test/foo.bats" or similar)
  if [[ "$line" =~ ^#[[:space:]]+File[[:space:]]+(.*) ]]; then
    CURRENT_SUITE="${BASH_REMATCH[1]}"
  fi

  # Count test results
  if [[ "$line" =~ ^ok[[:space:]] ]]; then
    TOTAL=$((TOTAL + 1))
    if [[ "$line" =~ \#[[:space:]]*skip ]]; then
      SKIPPED=$((SKIPPED + 1))
    else
      PASSED=$((PASSED + 1))
    fi
    # Update status
    cat > "$STATUS_FILE" <<INNER_EOF
STATE: RUNNING
SUITES: $SUITES
TESTS: $PASSED/$TOTAL passed, $FAILED failed, $SKIPPED skipped
CURRENT_SUITE: $CURRENT_SUITE
LAST: $line
INNER_EOF
  elif [[ "$line" =~ ^not[[:space:]]ok[[:space:]] ]]; then
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    cat > "$STATUS_FILE" <<INNER_EOF
STATE: RUNNING
SUITES: $SUITES
TESTS: $PASSED/$TOTAL passed, $FAILED failed, $SKIPPED skipped
CURRENT_SUITE: $CURRENT_SUITE
LAST: $line
INNER_EOF
  fi
done || { EXIT_CODE=${PIPESTATUS[0]}; [ "$EXIT_CODE" -ne 0 ] || EXIT_CODE=1; }

# The pipe subshell loses counter values, so re-parse from the full log
SUITES=0
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
PLAN_TOTAL=0

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^1\.\. ]]; then
    SUITES=$((SUITES + 1))
    if [[ "$line" =~ ^1\.\.([0-9]+)$ ]]; then
      PLAN_TOTAL=$((PLAN_TOTAL + BASH_REMATCH[1]))
    fi
  elif [[ "$line" =~ ^ok[[:space:]] ]]; then
    TOTAL=$((TOTAL + 1))
    if [[ "$line" =~ \#[[:space:]]*skip ]]; then
      SKIPPED=$((SKIPPED + 1))
    else
      PASSED=$((PASSED + 1))
    fi
  elif [[ "$line" =~ ^not[[:space:]]ok[[:space:]] ]]; then
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
  fi
done < "$FULL_LOG"

# Extract failures with diagnostics
> "$ERRORS_LOG"
{
  IN_FAILURE=false
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^not[[:space:]]ok[[:space:]] ]]; then
      IN_FAILURE=true
      echo "$line" >> "$ERRORS_LOG"
    elif $IN_FAILURE && [[ "$line" =~ ^#[[:space:]] ]]; then
      echo "$line" >> "$ERRORS_LOG"
    else
      IN_FAILURE=false
    fi
  done < "$FULL_LOG"
}

# Extract skips
> "$SKIPS_LOG"
grep -E '^ok .* # skip' "$FULL_LOG" >> "$SKIPS_LOG" 2>/dev/null || true

# Determine overall status. FAIL is checked first and covers a run that executed nothing
# (or a different number of tests than the TAP plans declared), whatever the command's exit code was.
REASONS=()
[ "$EXIT_CODE" -ne 0 ] && REASONS+=("command exited $EXIT_CODE")
[ "$TOTAL" -eq 0 ] && REASONS+=("no tests ran")
[ "$PLAN_TOTAL" -ne "$TOTAL" ] && REASONS+=("TAP plan declared $PLAN_TOTAL tests, $TOTAL reported")
[ "$FAILED" -gt 0 ] && REASONS+=("$FAILED test(s) failed")
if [ "${#REASONS[@]}" -gt 0 ]; then
  STATUS="FAIL"
  REASON_LINE="REASON: $(IFS=';'; echo "${REASONS[*]}" | sed 's/;/; /g')"
  [ "$EXIT_CODE" -ne 0 ] || EXIT_CODE=1
elif [ "$SKIPPED" -gt 0 ]; then
  STATUS="PASS_WITH_SKIPS"
  REASON_LINE=""
else
  STATUS="PASS"
  REASON_LINE=""
fi

# Build failure section
if [ -s "$ERRORS_LOG" ]; then
  FAILURE_LINES=$(cat "$ERRORS_LOG")
elif [ "$STATUS" = "FAIL" ]; then
  FAILURE_LINES="  (no TAP failures parsed; last 20 lines of full log:)
$(tail -n 20 "$FULL_LOG" | sed 's/^/    /')"
else
  FAILURE_LINES="  (none)"
fi

# Build skip section
SKIP_LINES=""
if [ -s "$SKIPS_LOG" ]; then
  SKIP_LINES=$(cat "$SKIPS_LOG")
else
  SKIP_LINES="  (none)"
fi

# Write final status file and output summary
SUMMARY=$(cat <<EOF
STATE: DONE
STATUS: $STATUS
${REASON_LINE:+$REASON_LINE
}SUITES: $SUITES  TOTAL: $TOTAL  PASSED: $PASSED  FAILED: $FAILED  SKIPPED: $SKIPPED
EXIT_CODE: $EXIT_CODE

FAILURES:
$FAILURE_LINES

SKIPS:
$SKIP_LINES

LOGS:
  Full:   $FULL_LOG
  Errors: $ERRORS_LOG
  Skips:  $SKIPS_LOG
  Status: $STATUS_FILE
EOF
)

echo "$SUMMARY" > "$STATUS_FILE"
echo "$SUMMARY"

exit "$EXIT_CODE"
