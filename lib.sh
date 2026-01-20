#!/usr/env bash

# This needs to be pulled in first because we over-ride some of what's in it!
. $TOPDIR/util.sh

head_log() {
    echo "$@" 1>&2
    echo $0: head $LOG 1>&2
    head $LOG >&2
    echo $0: END LOG 1>&2
    echo '' 1>&2
}

local_repo() {
  # Can't just return $? since errexit is set
  if echo $1 | egrep -q '^(git|https?):'; then
    debug 19 repo $1 is NOT local
    return 1
  else
    debug 19 repo $1 is local
    return 0
  fi
}
find_repo () {
  if local_repo $1; then
    cd $1
    pwd
  fi
}

out () {
  if [ "$1" == "-v" ]; then
    local verbose=1
    shift
  fi

  # NOTE: Thes MUST be error condition tests (|| instead of &&) or else our ERR trap will fire and we'll exit
  [ -z "$verbose" ] || echo '######################################'
  echo '#' $*

  # If we were passed verbose output then don't output unless in verbose mode.
  # Remember we need to invert everything because of ||
  [ -n "$verbose" -a -z "$verboseout" ] || echo '#' $* >&8
  [ -z "$verbose" ] || echo '######################################'
}

clean_log () {
  # Need to strip out temporary path and git hashes out of the log file. The
  # (/private)? bit is to filter out some crap OS X adds.
  # Normalize TEST_DIR to handle double slashes (e.g., /tmp//foo -> /tmp/foo)
  local NORM_TEST_DIR=$(echo "$TEST_DIR" | sed -E 's#([^:])//+#\1/#g')
  sed -i .bak -E \
    -e "s#(/private)?$NORM_TEST_DIR#@TEST_DIR@#g" \
    -e "s#^git fetch $PGXNREPO $PGXNBRANCH#git fetch @PGXNREPO@ @PGXNBRANCH@#" \
    -e "s#$PG_LOCATION#@PG_LOCATION@#g" \
    -f $RESULT_DIR/result.sed \
    $LOG
}

check_log() {
  reset_redirect
  clean_log
}

redirect() {
  # Don't bother if $LOG isn't set
  if [ -z "$LOG" ]; then
    echo '$LOG is not set; not redirecting output'
    return
  fi

  # See http://unix.stackexchange.com/questions/206786/testing-if-a-file-descriptor-is-valid
  if ! { true >&8; } 2>/dev/null; then
    # Save stdout & stderr
    exec 8>&1
    exec 9>&2
    if [ -z "$verboseout" ]; then
  #wc $LOG
      exec >> $LOG
  #wc $LOG >&8
    else
      # Redirect STDOUT to a subproc http://stackoverflow.com/questions/3173131/redirect-copy-of-stdout-to-log-file-from-within-bash-script-itself
      exec > >(tee -ai $LOG)
    fi

    # Always have errors go to both places
    exec 2> >(tee -ai $LOG >&9)
  fi
}

reset_redirect() {
  if { true >&8; } 2>/dev/null; then
    # Restore stdout and close FD #8. Ditto with stderr
    exec >&8 8>&-
    exec 2>&9 9>&-
  fi
}
error() {
  if { true >&9; } 2>/dev/null; then
    echo "$@" >&9
  else
    echo "$@" >&2
  fi
}
error_log() {
  echo "$@" >&2
}
die() {
  return=$1
  shift
  error "$@"
  exit $return
}
debug() {
  level=$1
  if [ $level -le ${DEBUG:=0} ]; then
    shift
    error DEBUG $level: "$@"
  fi
}

# Smart branch detection: if pgxntool-test is on a non-master branch,
# automatically use the same branch from pgxntool if it exists
if [ -z "$PGXNBRANCH" ]; then
  # Detect current branch of pgxntool-test
  TEST_HARNESS_BRANCH=$(git -C "$TOPDIR" symbolic-ref --short HEAD 2>/dev/null || echo "master")
  debug 9 "TEST_HARNESS_BRANCH=$TEST_HARNESS_BRANCH"

  # Default to master if test harness is on master
  if [ "$TEST_HARNESS_BRANCH" = "master" ]; then
    PGXNBRANCH="master"
  else
    # Check if pgxntool is local and what branch it's on
    PGXNREPO_TEMP=${2:-${TOPDIR}/../pgxntool}
    if local_repo "$PGXNREPO_TEMP"; then
      PGXNTOOL_BRANCH=$(git -C "$PGXNREPO_TEMP" symbolic-ref --short HEAD 2>/dev/null || echo "master")
      debug 9 "PGXNTOOL_BRANCH=$PGXNTOOL_BRANCH"

      # Use pgxntool's branch if it's master or matches test harness branch
      if [ "$PGXNTOOL_BRANCH" = "master" ] || [ "$PGXNTOOL_BRANCH" = "$TEST_HARNESS_BRANCH" ]; then
        PGXNBRANCH="$PGXNTOOL_BRANCH"
      else
        # Different branches - use master as safe fallback
        error "WARNING: pgxntool-test is on '$TEST_HARNESS_BRANCH' but pgxntool is on '$PGXNTOOL_BRANCH'"
        error "Using 'master' branch. Set PGXNBRANCH explicitly to override."
        PGXNBRANCH="master"
      fi
    else
      # Remote repo - default to master
      PGXNBRANCH="master"
    fi
  fi
fi

PGXNBRANCH=${PGXNBRANCH:-${1:-master}}
PGXNREPO=${PGXNREPO:-${2:-${TOPDIR}/../pgxntool}}
TEST_TEMPLATE=${TEST_TEMPLATE:-${TOPDIR}/../pgxntool-test-template}
TEST_REPO=$TEST_DIR/repo
debug_vars 9 PGXNBRANCH PGXNREPO TEST_TEMPLATE TEST_REPO

PG_LOCATION=`pg_config --bindir | sed 's#/bin##'`
PGXNREPO=`find_repo $PGXNREPO`
TEST_TEMPLATE=`find_repo $TEST_TEMPLATE`
debug_vars 19 PG_LOCATION PGXNREPO TEST_REPO

redirect

#trap "echo PTD='$TEST_DIR' >&2; echo LOG='$LOG' >&2" EXIT

#head_log 'from lib.sh'

# vi: expandtab sw=2 ts=2
