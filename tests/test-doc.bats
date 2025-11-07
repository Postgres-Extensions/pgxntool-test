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

load helpers

# Helper function to get HTML files (excluding other.html)
get_html() {
  local other_html="$1"
  local html_files=$(cd "$TEST_DIR/doc_repo" && ls doc/*.html 2>/dev/null || true)

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

  # Set TOPDIR
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

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
  local doc_files=$(ls "$TEST_DIR/doc_repo/doc"/*.adoc "$TEST_DIR/doc_repo/doc"/*.asciidoc 2>/dev/null || true)
  [ -n "$doc_files" ]
}

@test "ASCIIDOC='' make install does not create docs" {
  cd "$TEST_DIR/doc_repo"

  # Remove any existing HTML files
  local input=$(ls doc/*.adoc doc/*.asciidoc 2>/dev/null)
  local expected=$(echo "$input" | sed -Ee 's/(adoc|asciidoc)$/html/')
  rm -f $expected

  # Install without ASCIIDOC
  ASCIIDOC='' make install >/dev/null 2>&1 || true

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

  # Run make test
  make test >/dev/null 2>&1 || true

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
  make html >/dev/null 2>&1 || true
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
  make docclean >/dev/null 2>&1 || true

  # Generate with asc extension only
  ASCIIDOC_EXTS='asc' make html >/dev/null 2>&1 || true

  # Should have adoc_doc.html, asc_doc.html, asciidoc_doc.html
  local html=$(get_html "other.html")
  local expected='doc/adoc_doc.html
doc/asc_doc.html
doc/asciidoc_doc.html'

  check_html "$html" "$expected"

  # Clean again
  ASCIIDOC_EXTS='asc' make docclean >/dev/null 2>&1 || true
  local html_after=$(get_html "other.html")
  [ -z "$html_after" ]
}

@test "build works with no doc directory" {
  cd "$TEST_DIR/doc_repo"

  # Generate docs first
  make html >/dev/null 2>&1 || true

  # Remove doc directory
  rm -rf doc

  # These should all work without error
  run make clean
  [ "$status" -eq 0 ]

  run make docclean
  [ "$status" -eq 0 ]

  run make install
  [ "$status" -eq 0 ]
}

@test "doc_repo is still functional" {
  cd "$TEST_DIR/doc_repo"

  # Basic sanity check
  assert_file_exists "Makefile"

  run make --version
  [ "$status" -eq 0 ]
}

# vi: expandtab sw=2 ts=2
