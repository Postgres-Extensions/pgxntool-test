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
#   0 : ALL_PASS  — every monitored workflow run for this push succeeded (or
#                   legitimately skipped, e.g. Claude Code Review on a draft
#                   PR or an untrusted fork)
#   1 : FAIL      — one or more workflow runs failed
#   2 : TIMEOUT   — run(s) did not complete within the timeout
#   3 : NO_RUNS   — not all expected CI runs were found for this branch after waiting
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

# Workflows that GitHub triggers on every PR push (opened/synchronize/reopened),
# in both pgxntool and pgxntool-test. "CI" is the real test matrix and is
# treated as primary: its === BRANCHES: === line and per-job breakdown are
# extracted. "Claude Code Review" fires on the same push (event
# pull_request_target) but only emits a single review job, so a naive
# commit-based `gh run list` with no workflow filter can nondeterministically
# return either run for the same commit. Both are looked up by exact workflow
# name so the right run is never ambiguous.
#
# claude.yml and protect-label.yml are NOT included here: they trigger on
# comment/review/label events, never on a plain push, so there is no run to
# wait for on an ordinary push.
PUSH_WORKFLOWS=("CI" "Claude Code Review")

# ─── Helper: wait for a run to appear, then poll until done ──────────────────
monitor_one() {
  local repo="$1"
  local branch="$2"
  local sha="$3"
  local timeout="$4"
  local label="[$repo]"
  local elapsed=0

  # Step 1: find the run ID for every workflow expected on this push.
  # When a SHA is provided, wait up to 30s for GitHub to index runs for that
  # exact commit before falling back to the branch lookup. Without this wait,
  # rapid pushes cause the branch fallback to pick up the previous run instead
  # of the new one. Each workflow is looked up by name (-w/--workflow) so a
  # commit or branch can never resolve to the wrong workflow's run.
  declare -A run_ids=()
  local sha_wait=0
  local SHA_INDEX_WAIT=30  # seconds to wait for SHA indexing before branch fallback
  echo "$label Waiting for CI run(s) on branch '$branch'..."
  while [[ ${#run_ids[@]} -lt ${#PUSH_WORKFLOWS[@]} ]]; do
    local wf
    for wf in "${PUSH_WORKFLOWS[@]}"; do
      [[ -n "${run_ids[$wf]:-}" ]] && continue
      local found=""
      if [[ -n "$sha" ]]; then
        found=$(gh run list --repo "$repo" --commit "$sha" --workflow "$wf" \
          --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
      fi
      if [[ -z "$found" && -n "$branch" && ( -z "$sha" || $sha_wait -ge $SHA_INDEX_WAIT ) ]]; then
        # Only fall back to branch once the SHA wait window has elapsed (or no SHA given).
        # NOTE: this can pick up a different run of the same workflow if two
        # pushes happen rapidly on the same branch.
        found=$(gh run list --repo "$repo" --branch "$branch" --workflow "$wf" \
          --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
      fi
      [[ -n "$found" ]] && run_ids[$wf]="$found"
    done
    if [[ ${#run_ids[@]} -lt ${#PUSH_WORKFLOWS[@]} ]]; then
      sleep 5
      elapsed=$((elapsed + 5))
      sha_wait=$((sha_wait + 5))
      if [[ $elapsed -ge $timeout ]]; then
        local missing=""
        for wf in "${PUSH_WORKFLOWS[@]}"; do
          [[ -z "${run_ids[$wf]:-}" ]] && missing+="$wf, "
        done
        echo "$label ERROR: no run found after ${timeout}s for: ${missing%, }" >&2
        return 3  # NO_RUNS (distinct from FAIL/TIMEOUT; see exit-code table)
      fi
    fi
  done
  local wf
  for wf in "${PUSH_WORKFLOWS[@]}"; do
    echo "$label Run ${run_ids[$wf]} ($wf) found"
  done

  # Step 2: extract the BRANCHES line as soon as CI's first job starts.
  # We use the direct jobs API (fast ~1s) rather than the zip-download log path
  # (slow 3-10s). We only need one job — all CI jobs emit the same BRANCHES
  # line. Only the CI run emits this line; Claude Code Review does not.
  local ci_run_id="${run_ids[CI]}"
  local branches_line=""
  local attempts=0
  while [[ -z "$branches_line" && $elapsed -lt $timeout ]]; do
    local first_job_id
    first_job_id=$(gh run view "$ci_run_id" --repo "$repo" \
      --json jobs --jq '[.jobs[].databaseId][0] // empty' 2>/dev/null || true)

    if [[ -n "$first_job_id" ]]; then
      # grep may return non-zero if the line isn't present yet — that's fine.
      # No '^' anchor: the logs API prefixes every line with an ISO-8601
      # timestamp (e.g. "2026-07-29T20:54:15Z === BRANCHES: ..."), so an
      # anchored match never fires. The step also gets echoed (with
      # unexpanded ${VARS}) before it runs, so more than one line can match;
      # `tail -1` keeps the last (actual, expanded) occurrence.
      branches_line=$(gh api "repos/${repo}/actions/jobs/${first_job_id}/logs" \
        2>/dev/null | grep "=== BRANCHES:" | tail -1 \
        | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z //' || true)
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

  # Step 3: poll every run until each is completed.
  declare -A results=()
  declare -A conclusions=()
  local pending=("${PUSH_WORKFLOWS[@]}")
  while [[ ${#pending[@]} -gt 0 && $elapsed -lt $timeout ]]; do
    local still_pending=()
    for wf in "${pending[@]}"; do
      local rid="${run_ids[$wf]}"
      local result
      result=$(gh run view "$rid" --repo "$repo" \
        --json status,conclusion,jobs \
        --jq '{status: .status, conclusion: .conclusion,
               jobs: [.jobs[] | {name: .name, status: .status, conclusion: .conclusion}]}' \
        2>/dev/null || true)

      if [[ -z "$result" ]]; then
        still_pending+=("$wf")
        continue
      fi

      if [[ "$(echo "$result" | jq -r '.status')" == "completed" ]]; then
        results[$wf]="$result"
        conclusions[$wf]=$(echo "$result" | jq -r '.conclusion')
      else
        still_pending+=("$wf")
      fi
    done
    pending=("${still_pending[@]}")

    if [[ ${#pending[@]} -gt 0 ]]; then
      local pending_desc=""
      for wf in "${pending[@]}"; do pending_desc+="$wf, "; done
      echo "$label Polling... (still running: ${pending_desc%, })"
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    fi
  done

  if [[ ${#pending[@]} -gt 0 ]]; then
    echo "$label ERROR: timed out after ${timeout}s waiting on: ${pending[*]}" >&2
    return 2
  fi

  # Step 4: report per-run, per-job outcomes.
  # "skipped" is a legitimate outcome, not a failure: Claude Code Review's
  # single job intentionally no-ops on draft PRs and PRs from untrusted forks
  # (see claude-code-review.yml's job-level `if:`), which surfaces as the
  # whole run concluding "skipped" rather than "success".
  local overall_ok=1
  for wf in "${PUSH_WORKFLOWS[@]}"; do
    local rid="${run_ids[$wf]}"
    local conclusion="${conclusions[$wf]}"
    echo "$label Run $rid ($wf) completed: $(echo "$conclusion" | tr '[:lower:]' '[:upper:]')"
    echo "${results[$wf]}" | jq -r '.jobs[] | "\(if .conclusion == "success" or .conclusion == "skipped" then .conclusion | ascii_upcase elif .conclusion == null then .status else .conclusion | ascii_upcase end)  \(.name)"' \
      | sed "s|^|$label |"

    # Step 5: for a failing run, print the failure log (last 60 lines per job).
    if [[ "$conclusion" != "success" && "$conclusion" != "skipped" ]]; then
      overall_ok=0
      local job_id
      for job_id in $(echo "${results[$wf]}" | jq -r \
        '[.jobs[] | select(.conclusion == "failure") | .databaseId] | .[]' 2>/dev/null || true); do
        local job_name
        job_name=$(echo "${results[$wf]}" | jq -r \
          --argjson id "$job_id" \
          '[.jobs[] | select(.databaseId == $id) | .name] | .[0]' 2>/dev/null || true)
        echo ""
        echo "$label === FAILURE ($wf): ${job_name:-job $job_id} ==="
        # Use --log-failed to get only the failed step output, keeping output compact.
        gh run view --repo "$repo" --job "$job_id" --log-failed 2>&1 \
          | grep -v "^$" | tail -60 || true
      done
    fi
  done

  [[ $overall_ok -eq 1 ]] && return 0
  return 1
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
