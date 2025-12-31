#!/usr/bin/env bats

# Test: Documentation generation
#
# Tests that asciidoc/asciidoctor documentation generation works correctly:
# - ASCIIDOC='' should not create docs during install
# - ASCIIDOC='' make html should fail
# - make test should create docs
# - make clean should not clean docs
# - make docclean should clean docs
# - ASCIIDOC_EXTS controls which extensions are processed

load ../lib/helpers

# Helper function to get HTML files (excluding other.html)
get_html() {
  local other_html="$1"
  # OK to fail: ls returns non-zero if no files match, which is a valid state
  local html_files=$(cd "$TEST_DIR/doc_repo" && ls doc/*.html 2>/dev/null || echo "")

  if [ -z "$html_files" ]; then
    echo ""
    return
  fi

  # Format for easy grepping (one per line)
  local result=""
  for f in $html_files; do
    if [ -n "$other_html" ] && echo "$f" | grep -q "$other_html"; then
      continue
    fi
    if [ -n "$result" ]; then
      result="$result"$'\n'"$f"
    else
      result="$f"
    fi
  done

  echo "$result"
}

# Helper function to check HTML matches expected
check_html() {
  local html="$1"
  local expected="$2"

  if [ "$html" != "$expected" ]; then
    echo "Expected: $expected"
    echo "Got: $html"
    return 1
  fi
  return 0
}

setup_file() {
  # Check if asciidoc or asciidoctor is available
  if ! which asciidoc &>/dev/null && ! which asciidoctor &>/dev/null; then
    skip "asciidoc or asciidoctor not found"
  fi

  # Set TOPDIR to repository root
  setup_topdir

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "doc"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "doc"

  # Create doc_repo if it doesn't exist
  if [ ! -d "$TEST_DIR/doc_repo" ]; then
    rsync -a --delete "$TEST_REPO/" "$TEST_DIR/doc_repo"
  fi
}

@test "documentation source files exist" {
  # OK to fail: ls returns non-zero if no files match, which would mean test should fail
  local doc_files=$(ls "$TEST_DIR/doc_repo/doc"/*.adoc "$TEST_DIR/doc_repo/doc"/*.asciidoc 2>/dev/null || echo "")
  [ -n "$doc_files" ]
}

@test "ASCIIDOC='' make install does not create docs" {
  cd "$TEST_DIR/doc_repo"

  # Remove any existing HTML files
  local input=$(ls doc/*.adoc doc/*.asciidoc 2>/dev/null)
  local expected=$(echo "$input" | sed -Ee 's/(adoc|asciidoc)$/html/')
  rm -f $expected

  # Install without ASCIIDOC (should fail, but we only care about HTML files not being created)
  run env ASCIIDOC='' make install
  # Don't check status - we're testing that HTML files aren't created, not that install succeeds

  # Check no HTML files were created (except other.html which is pre-existing)
  local html=$(get_html "other.html")
  [ -z "$html" ]
}

@test "ASCIIDOC='' make html fails" {
  cd "$TEST_DIR/doc_repo"

  run env ASCIIDOC='' make html
  [ "$status" -ne 0 ]
}

@test "make test creates documentation" {
  cd "$TEST_DIR/doc_repo"

  # Get expected HTML files
  local input=$(ls doc/*.adoc doc/*.asciidoc 2>/dev/null)
  local expected=$(echo "$input" | sed -Ee 's/(adoc|asciidoc)$/html/')

  # Run make test (may fail if PostgreSQL not running, but we only care about HTML generation)
  run make test
  # Don't check status - we're testing that HTML files are created, not that tests pass

  # Check HTML files were created
  local html=$(get_html "other.html")
  check_html "$html" "$expected"
}

@test "make clean does not remove documentation" {
  cd "$TEST_DIR/doc_repo"

  # Get HTML before clean
  local html_before=$(get_html "other.html")

  # Run make clean
  make clean >/dev/null 2>&1

  # Check HTML still exists
  local html_after=$(get_html "other.html")
  [ "$html_before" = "$html_after" ]
}

@test "make docclean removes documentation" {
  cd "$TEST_DIR/doc_repo"

  # Ensure docs exist
  run make html
  assert_success
  local html_before=$(get_html "other.html")
  [ -n "$html_before" ]

  # Run make docclean
  make docclean >/dev/null 2>&1

  # Check HTML files are gone
  local html_after=$(get_html "other.html")
  [ -z "$html_after" ]
}

@test "ASCIIDOC_EXTS='asc' processes only .asc files" {
  cd "$TEST_DIR/doc_repo"

  # Clean first
  run make docclean
  assert_success

  # Generate with asc extension only
  run env ASCIIDOC_EXTS='asc' make html
  assert_success

  # Should have adoc_doc.html, asc_doc.html, asciidoc_doc.html
  local html=$(get_html "other.html")
  local expected='doc/adoc_doc.html
doc/asc_doc.html
doc/asciidoc_doc.html'

  check_html "$html" "$expected"

  # Clean again
  run env ASCIIDOC_EXTS='asc' make docclean
  assert_success
  local html_after=$(get_html "other.html")
  [ -z "$html_after" ]
}

@test "build works with no doc directory" {
  cd "$TEST_DIR/doc_repo"

  # Generate docs first
  run make html
  assert_success

  # Remove doc directory
  rm -rf doc

  # These should all work without error
  run make clean
  assert_success

  run make docclean
  assert_success

  run make install
  assert_success
}

@test "doc_repo is still functional" {
  cd "$TEST_DIR/doc_repo"

  # Basic sanity check
  assert_file_exists "Makefile"

  run make --version
  assert_success
}

# vi: expandtab sw=2 ts=2
