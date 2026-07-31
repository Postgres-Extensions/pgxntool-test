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
#   0 : ALL_PASS  — every workflow run triggered by this push succeeded (or
#                   legitimately skipped, e.g. Claude Code Review on a draft
#                   PR or an untrusted fork)
#   1 : FAIL      — one or more workflow runs failed
#   2 : TIMEOUT   — run(s) did not complete within the timeout
#   3 : NO_RUNS   — no workflow run was found for this branch/SHA after waiting
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
DISCOVER_INTERVAL=5 # seconds between polls while discovering/settling run set

# Every workflow run GitHub actually triggers for a push is included by
# default and must succeed (or legitimately skip) for OVERALL: ALL_PASS -
# there is no hand-maintained list of "expected" workflow names to keep in
# sync every time a workflow is added, renamed, or removed. Add a workflow's
# display name here only for the rare case where it fires on a push but
# should never gate this check (e.g. known-flaky, or informational-only).
EXCLUDE_WORKFLOWS=()

if [[ ${#EXCLUDE_WORKFLOWS[@]} -eq 0 ]]; then
  EXCLUDE_JSON="[]"
else
  EXCLUDE_JSON=$(printf '%s\n' "${EXCLUDE_WORKFLOWS[@]}" | jq -R . | jq -s .)
fi

# ─── Helper: discover every run for a commit, excluding EXCLUDE_WORKFLOWS ────
_list_runs() {
  local repo="$1" sha="$2"
  # NOTE: gh's own --jq flag is a plain jq expression string - it does not
  # accept extra jq flags like --argjson. Pipe gh's raw JSON into a real jq
  # invocation instead so $exclude can be bound.
  gh run list --repo "$repo" --commit "$sha" \
    --json databaseId,workflowName 2>/dev/null \
    | jq --argjson exclude "$EXCLUDE_JSON" \
        '[.[] | select(([.workflowName] | inside($exclude)) | not)]' \
    || echo "[]"
}

# ─── Helper: wait for a run to appear, then poll until done ──────────────────
monitor_one() {
  local repo="$1"
  local branch="$2"
  local sha="$3"
  local timeout="$4"
  local label="[$repo]"
  local elapsed=0

  echo "$label Waiting for CI run(s) on branch '$branch'..."

  # Step 1a: resolve a concrete commit to key off. If no SHA was given,
  # take the branch's most recent run of any workflow and use its headSha -
  # this keeps "which workflows fired for this push" well defined, instead
  # of `--branch --limit 1` picking a single, possibly-wrong-workflow run
  # directly (the original bug this script had).
  local resolved_sha="$sha"
  if [[ -z "$resolved_sha" && -n "$branch" ]]; then
    while [[ -z "$resolved_sha" && $elapsed -lt $timeout ]]; do
      resolved_sha=$(gh run list --repo "$repo" --branch "$branch" --limit 1 \
        --json headSha --jq '.[0].headSha // empty' 2>/dev/null || true)
      if [[ -z "$resolved_sha" ]]; then
        sleep "$DISCOVER_INTERVAL"
        elapsed=$((elapsed + DISCOVER_INTERVAL))
      fi
    done
  fi
  if [[ -z "$resolved_sha" ]]; then
    echo "$label ERROR: no CI run found after ${timeout}s" >&2
    return 3  # NO_RUNS (distinct from FAIL/TIMEOUT; see exit-code table)
  fi

  # Step 1b: discover every (non-excluded) workflow run tied to that commit,
  # then settle briefly to catch sibling runs GitHub hasn't indexed yet.
  # Workflows triggered by the same push event normally all appear within a
  # few seconds of each other; settling stops once the discovered count has
  # held steady for two consecutive polls, or 30s have passed since the
  # first run appeared, whichever comes first.
  local run_list="[]"
  local count=0
  local stable_polls=0
  local since_first_found=0
  local found_any=0
  while [[ $elapsed -lt $timeout ]]; do
    local new_list new_count
    new_list=$(_list_runs "$repo" "$resolved_sha")
    new_count=$(echo "$new_list" | jq 'length')

    if [[ "$new_count" -gt 0 ]]; then
      found_any=1
    fi
    if [[ "$new_count" -eq "$count" ]]; then
      stable_polls=$((stable_polls + 1))
    else
      stable_polls=0
    fi
    run_list="$new_list"
    count="$new_count"

    if [[ $found_any -eq 1 ]]; then
      if [[ $stable_polls -ge 2 || $since_first_found -ge 30 ]]; then
        break
      fi
      since_first_found=$((since_first_found + DISCOVER_INTERVAL))
    fi

    sleep "$DISCOVER_INTERVAL"
    elapsed=$((elapsed + DISCOVER_INTERVAL))
  done

  if [[ "$count" -eq 0 ]]; then
    echo "$label ERROR: no CI run found after ${timeout}s" >&2
    return 3
  fi

  declare -A run_names=()
  local rid name
  while IFS=$'\t' read -r rid name; do
    run_names[$rid]="$name"
    echo "$label Run $rid ($name) found"
  done < <(echo "$run_list" | jq -r '.[] | [.databaseId, .workflowName] | @tsv')

  # Step 2: extract the BRANCHES line as soon as a job starts. We use the
  # direct jobs API (fast ~1s) rather than the zip-download log path (slow
  # 3-10s), checking only each run's first job — all jobs in the CI test
  # matrix emit the same BRANCHES line, and it's fine to come up empty for
  # runs that never emit it (e.g. Claude Code Review).
  local branches_line=""
  local attempts=0
  while [[ -z "$branches_line" && $elapsed -lt $timeout ]]; do
    for rid in "${!run_names[@]}"; do
      local first_job_id
      first_job_id=$(gh run view "$rid" --repo "$repo" \
        --json jobs --jq '[.jobs[].databaseId][0] // empty' 2>/dev/null || true)
      [[ -z "$first_job_id" ]] && continue

      # grep may return non-zero if the line isn't present in this run's log
      # at all, or not yet — that's fine.
      # No '^' anchor: the logs API prefixes every line with an ISO-8601
      # timestamp (e.g. "2026-07-29T20:54:15Z === BRANCHES: ..."), so an
      # anchored match never fires. The step also gets echoed (with
      # unexpanded ${VARS}) before it runs, so more than one line can match;
      # `tail -1` keeps the last (actual, expanded) occurrence.
      branches_line=$(gh api "repos/${repo}/actions/jobs/${first_job_id}/logs" \
        2>/dev/null | grep "=== BRANCHES:" | tail -1 \
        | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z //' || true)
      [[ -n "$branches_line" ]] && break
    done

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
  local pending=("${!run_names[@]}")
  while [[ ${#pending[@]} -gt 0 && $elapsed -lt $timeout ]]; do
    local still_pending=()
    for rid in "${pending[@]}"; do
      local result
      result=$(gh run view "$rid" --repo "$repo" \
        --json status,conclusion,jobs \
        --jq '{status: .status, conclusion: .conclusion,
               jobs: [.jobs[] | {name: .name, status: .status, conclusion: .conclusion}]}' \
        2>/dev/null || true)

      if [[ -z "$result" ]]; then
        still_pending+=("$rid")
        continue
      fi

      if [[ "$(echo "$result" | jq -r '.status')" == "completed" ]]; then
        results[$rid]="$result"
        conclusions[$rid]=$(echo "$result" | jq -r '.conclusion')
      else
        still_pending+=("$rid")
      fi
    done
    pending=("${still_pending[@]}")

    if [[ ${#pending[@]} -gt 0 ]]; then
      local pending_desc=""
      for rid in "${pending[@]}"; do pending_desc+="${run_names[$rid]}, "; done
      echo "$label Polling... (still running: ${pending_desc%, })"
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    fi
  done

  if [[ ${#pending[@]} -gt 0 ]]; then
    local pending_desc=""
    for rid in "${pending[@]}"; do pending_desc+="${run_names[$rid]}, "; done
    echo "$label ERROR: timed out after ${timeout}s waiting on: ${pending_desc%, }" >&2
    return 2
  fi

  # Step 4: report per-run, per-job outcomes.
  # "skipped" is a legitimate outcome, not a failure: e.g. Claude Code
  # Review's single job intentionally no-ops on draft PRs and PRs from
  # untrusted forks (see claude-code-review.yml's job-level `if:`), which
  # surfaces as the whole run concluding "skipped" rather than "success".
  local overall_ok=1
  for rid in "${!run_names[@]}"; do
    local name="${run_names[$rid]}"
    local conclusion="${conclusions[$rid]}"
    echo "$label Run $rid ($name) completed: $(echo "$conclusion" | tr '[:lower:]' '[:upper:]')"
    echo "${results[$rid]}" | jq -r '.jobs[] | "\(if .conclusion == "success" or .conclusion == "skipped" then .conclusion | ascii_upcase elif .conclusion == null then .status else .conclusion | ascii_upcase end)  \(.name)"' \
      | sed "s|^|$label |"

    # Step 5: for a failing run, print the failure log (last 60 lines per job).
    if [[ "$conclusion" != "success" && "$conclusion" != "skipped" ]]; then
      overall_ok=0
      local job_id
      for job_id in $(echo "${results[$rid]}" | jq -r \
        '[.jobs[] | select(.conclusion == "failure") | .databaseId] | .[]' 2>/dev/null || true); do
        local job_name
        job_name=$(echo "${results[$rid]}" | jq -r \
          --argjson id "$job_id" \
          '[.jobs[] | select(.databaseId == $id) | .name] | .[0]' 2>/dev/null || true)
        echo ""
        echo "$label === FAILURE ($name): ${job_name:-job $job_id} ==="
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
