#!/usr/bin/env bash
# monitor-ci.sh [repos] [branch] [sha_pgxntool_test] [sha_pgxntool]
#
# Monitor GitHub Actions CI runs for pgxntool-test and/or pgxntool.
# Designed to be run in background by Claude after every git push.
#
# Arguments:
#   repos            : "both" (default), "pgxntool-test", or "pgxntool"
#   branch           : branch name (default: current git branch)
#   sha_pgxntool_test: exact SHA pushed to pgxntool-test (optional)
#   sha_pgxntool     : exact SHA pushed to pgxntool (optional)
#
# Exit codes:
#   0 : ALL_PASS  — all jobs succeeded
#   1 : FAIL      — one or more jobs failed
#   2 : TIMEOUT   — run(s) did not complete within the timeout
#   3 : NO_RUNS   — no CI run found for this branch after waiting
#
# Requires: gh CLI authenticated with repo access.

set -euo pipefail

REPOS="${1:-both}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"
SHA_TEST="${3:-}"
SHA_PGXN="${4:-}"

# Derive owner from the current repo (works for forks too)
_current_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
_owner=$(echo "$_current_repo" | cut -d/ -f1)
if [[ -z "$_owner" ]]; then
  # fallback if gh can't determine the repo
  _owner="Postgres-Extensions"
fi
REPO_TEST="${_owner}/pgxntool-test"
REPO_PGXN="${_owner}/pgxntool"

# pgxntool CI can wait up to 20 min for pgxntool-test CI to complete, then
# runs tests itself (commit-with-no-tests case). Allow 35 min total.
# pgxntool-test runs typically take 5-10 min (resolve + 6 PG matrix jobs).
TIMEOUT_TEST=900    # 15 minutes
TIMEOUT_PGXN=2100   # 35 minutes
POLL_INTERVAL=10    # seconds between status polls

# ─── Helper: wait for a run to appear, then poll until done ──────────────────
monitor_one() {
  local repo="$1"
  local branch="$2"
  local sha="$3"
  local timeout="$4"
  local label="[$repo]"
  local elapsed=0

  # Step 1: find the run ID.
  # When a SHA is provided, wait up to 30s for GitHub to index that exact run
  # before falling back to the branch lookup. Without this wait, rapid pushes
  # cause the branch fallback to pick up the previous run instead of the new one.
  local run_id=""
  local sha_wait=0
  local SHA_INDEX_WAIT=30  # seconds to wait for SHA indexing before branch fallback
  echo "$label Waiting for CI run on branch '$branch'..."
  while [[ -z "$run_id" ]]; do
    if [[ -n "$sha" ]]; then
      run_id=$(gh run list --repo "$repo" --commit "$sha" \
        --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
    fi
    if [[ -z "$run_id" && -n "$branch" && ( -z "$sha" || $sha_wait -ge $SHA_INDEX_WAIT ) ]]; then
      # Only fall back to branch once the SHA wait window has elapsed (or no SHA given).
      # NOTE: this can pick up a different run if two pushes happen rapidly.
      run_id=$(gh run list --repo "$repo" --branch "$branch" \
        --event pull_request --limit 1 \
        --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
    fi
    if [[ -z "$run_id" ]]; then
      sleep 5
      elapsed=$((elapsed + 5))
      sha_wait=$((sha_wait + 5))
      if [[ $elapsed -ge $timeout ]]; then
        echo "$label ERROR: no CI run found after ${timeout}s" >&2
        return 3  # NO_RUNS (distinct from FAIL/TIMEOUT; see exit-code table)
      fi
    fi
  done
  echo "$label Run $run_id found"

  # Step 2: extract the BRANCHES line as soon as the first job starts.
  # We use the direct jobs API (fast ~1s) rather than the zip-download log path
  # (slow 3-10s). We only need one job — all jobs emit the same BRANCHES line.
  local branches_line=""
  local attempts=0
  while [[ -z "$branches_line" && $elapsed -lt $timeout ]]; do
    local first_job_id
    first_job_id=$(gh run view "$run_id" --repo "$repo" \
      --json jobs --jq '[.jobs[].databaseId][0] // empty' 2>/dev/null || true)

    if [[ -n "$first_job_id" ]]; then
      # grep may return non-zero if the line isn't present yet — that's fine.
      branches_line=$(gh api "repos/${repo}/actions/jobs/${first_job_id}/logs" \
        2>/dev/null | grep "^=== BRANCHES:" | tail -1 || true)
    fi

    if [[ -z "$branches_line" ]]; then
      attempts=$((attempts + 1))
      if [[ $attempts -ge 3 ]]; then
        # Give up waiting for the BRANCHES line and move on to polling.
        echo "$label (BRANCHES line not yet available; proceeding to poll)"
        break
      fi
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    fi
  done
  if [[ -n "$branches_line" ]]; then
    echo "$label $branches_line"
  fi

  # Step 3: poll until all jobs complete.
  local status="in_progress"
  local result=""
  while [[ "$status" != "completed" && $elapsed -lt $timeout ]]; do
    result=$(gh run view "$run_id" --repo "$repo" \
      --json status,conclusion,jobs \
      --jq '{status: .status, conclusion: .conclusion,
             jobs: [.jobs[] | {name: .name, status: .status, conclusion: .conclusion}]}' \
      2>/dev/null || true)

    if [[ -z "$result" ]]; then
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
      continue
    fi

    status=$(echo "$result" | jq -r '.status')

    if [[ "$status" != "completed" ]]; then
      local running
      running=$(echo "$result" | jq -r \
        '[.jobs[] | select(.status == "in_progress") | .name] | join(", ")' || true)
      if [[ -n "$running" ]]; then
        echo "$label Polling... (running: $running)"
      fi
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    fi
  done

  if [[ $elapsed -ge $timeout ]]; then
    echo "$label ERROR: timed out after ${timeout}s" >&2
    return 2
  fi

  # Step 4: report per-job outcomes.
  local conclusion
  conclusion=$(echo "$result" | jq -r '.conclusion')
  echo "$label Run $run_id completed: $(echo "$conclusion" | tr '[:lower:]' '[:upper:]')"
  echo "$result" | jq -r '.jobs[] | "\(if .conclusion == "success" then "PASS" elif .conclusion == null then .status else .conclusion | ascii_upcase end)  \(.name)"' \
    | sed "s|^|$label |"

  # Step 5: for failed jobs, print the failure log (last 60 lines per job).
  if [[ "$conclusion" != "success" ]]; then
    local failed_job_ids
    failed_job_ids=$(gh run view "$run_id" --repo "$repo" \
      --json jobs \
      --jq '[.jobs[] | select(.conclusion == "failure") | .databaseId] | .[]' \
      2>/dev/null || true)

    for job_id in $failed_job_ids; do
      local job_name
      job_name=$(gh run view "$run_id" --repo "$repo" \
        --json jobs \
        --jq --argjson id "$job_id" \
        '[.jobs[] | select(.databaseId == $id) | .name] | .[0]' 2>/dev/null || true)
      echo ""
      echo "$label === FAILURE: ${job_name:-job $job_id} ==="
      # Use --log-failed to get only the failed step output, keeping output compact.
      gh run view --repo "$repo" --job "$job_id" --log-failed 2>&1 \
        | grep -v "^$" | tail -60 || true
    done

    return 1
  fi

  return 0
}

# ─── Main: run monitors in parallel or series ─────────────────────────────────
exit_code=0
pid_test=""
pid_pgxn=""

case "$REPOS" in
  pgxntool-test)
    # Preserve monitor_one's exact code (2=TIMEOUT, 3=NO_RUNS), don't flatten to 1.
    monitor_one "$REPO_TEST" "$BRANCH" "$SHA_TEST" "$TIMEOUT_TEST" \
      || { r=$?; [[ $r -gt $exit_code ]] && exit_code=$r; }
    ;;
  pgxntool)
    monitor_one "$REPO_PGXN" "$BRANCH" "$SHA_PGXN" "$TIMEOUT_PGXN" \
      || { r=$?; [[ $r -gt $exit_code ]] && exit_code=$r; }
    ;;
  both|*)
    # Run both in parallel. Each writes to stdout (interleaved but prefixed with
    # the repo name for readability). Capture both PIDs and wait for both.
    monitor_one "$REPO_TEST" "$BRANCH" "$SHA_TEST" "$TIMEOUT_TEST" &
    pid_test=$!
    monitor_one "$REPO_PGXN" "$BRANCH" "$SHA_PGXN" "$TIMEOUT_PGXN" &
    pid_pgxn=$!

    wait "$pid_test" || { r=$?; echo "[both] pgxntool-test CI FAILED"; [[ $r -gt $exit_code ]] && exit_code=$r; }
    wait "$pid_pgxn" || { r=$?; echo "[both] pgxntool CI FAILED";      [[ $r -gt $exit_code ]] && exit_code=$r; }
    ;;
esac

# Emit a parseable summary line. Claude should check this line rather than
# parsing the full output. Convention matches the test skill's STATUS line.
if [[ $exit_code -eq 0 ]]; then
  echo "OVERALL: ALL_PASS"
elif [[ $exit_code -eq 2 ]]; then
  echo "OVERALL: TIMEOUT"
elif [[ $exit_code -eq 3 ]]; then
  echo "OVERALL: NO_RUNS"
else
  echo "OVERALL: FAIL"
fi

exit $exit_code
