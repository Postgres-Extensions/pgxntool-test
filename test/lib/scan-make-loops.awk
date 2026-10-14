# Lists the loops in one makefile, one "<file>\t<context>\t<kind>\t<text>" line
# each, <text> being the whole logical line containing the loop with each run
# of blanks collapsed to one space; make-loops.bats fingerprints it.
# test/standard/make-loops.bats says what counts as a loop and why; the header
# of test/lib/pgxntool-loops.txt describes the context keys.
#
# Usage: awk -v file=<name to print> -f scan-make-loops.awk <makefile>
#
# Every logical line is searched for both kinds of loop; classifying the line
# (recipe, define body, assignment, rule header, directive, other) only picks
# its context key and which text is searched:
#   - recipe and define body lines: all of it, minus shell comment lines
#   - assignments: the value, whose start counts as command position
#   - rule headers: the prerequisites, plus any `; recipe` (taken from the raw
#     line, since make doesn't strip comments from it)
#   - everything else: the line minus its make comment
# A for/while/until at command position counts only when a `do` follows it in
# the searched text, except in a define body, where every one counts.

BEGIN {
  # Shell command position: start of the text, after a separator or opening
  # character (quotes included, since `sh -c "..."` bodies are real shell),
  # after a keyword that starts a command list, or at the start of $(shell).
  CMDPOS = "(^|[;&|(){!`\"']|(^|[^A-Za-z0-9_])(do|then|else|elif)[ \t]|\\$+[({]shell[ \t])[ \t]*"
  # `for NAME` must be followed by in/;/do, so prose ("for a reason") and
  # awk's `for(i in A)` don't match.
  LOOP = "(for[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]+in([ \t;]|$)|[ \t]*;|[ \t]+do([ \t;]|$))|for[ \t]*\\(\\(|while([ \t({!]|$)|until([ \t({!]|$))"
  SHELL_LOOP = CMDPOS LOOP
  # The `do` that a real loop's keyword must be followed by outside a define
  # body: after a separator, or right after `for NAME`.
  DO_AFTER = "[;&)}][ \t]*do([ \t]|$)"
  FOR_NAME_DO = "^for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+do([ \t;]|$)"
}

# Physical lines are buffered until one doesn't end in an odd number of
# backslashes. phys[] keeps them apart because a shell comment ends at its own
# physical line even when that line is continued.
{
  if (match($0, /\\+$/) && RLENGTH % 2 == 1) {
    phys[++np] = substr($0, 1, length($0) - 1)
    next
  }
  phys[++np] = $0
  logical()
  np = 0
}
END { if (np) logical() }

function logical(   i, raw, r, t, p, s, name, key) {
  raw = phys[1]
  for (i = 2; i <= np; i++) raw = raw " " phys[i]
  logical_text = norm(raw)

  # Like make, only lines that don't start with a tab can nest or end a define.
  if (defdepth) {
    if (raw !~ /^\t/) {
      if (np == 1 && raw ~ /^[ \t]*endef([ \t#]|$)/) { defdepth--; return }
      if (raw ~ /^[ \t]*((override|export|private)[ \t]+)*define([ \t]|$)/) defdepth++
    }
    recipe("define:" defname)
    return
  }

  # A tab-led line is a recipe line only while a rule's recipe can follow;
  # elsewhere make parses it as an ordinary line (e.g. an indented assignment).
  if (inrule && raw ~ /^\t/) { recipe(ctx); return }

  r = raw
  sub(/^[ \t]+/, "", r)
  p = find0(r, "#")
  t = p ? substr(r, 1, p - 1) : r
  if (t ~ /^[ \t]*$/) return

  if (t ~ /^((override|export|private)[ \t]+)*define([ \t]|$)/) {
    name = t
    sub(/^((override|export|private)[ \t]+)*define[ \t]*/, "", name)
    sub(/[ \t]*(:::=|::=|:=|[+?!]?=)[ \t]*$/, "", name)
    defname = norm(name)
    defdepth = 1
    inrule = 0
    return
  }

  # Conditionals don't end a rule's recipe; the other directives do.
  if (t ~ /^(ifeq|ifneq|ifdef|ifndef|else|endif)([ \t(]|$)/) {
    search(t, "toplevel")
    return
  }
  if (t ~ /^(-?include|sinclude|-?load|vpath|unexport|undefine)([ \t]|$)/) {
    search(t, "toplevel")
    inrule = 0
    return
  }

  p = find0(t, ":=")
  if (p && (substr(t, p, 1) == "=" || substr(t, p) ~ /^(:=|::=|:::=)/)) {
    name = substr(t, 1, p - 1)
    if (substr(t, p, 1) == "=") sub(/[+?!]$/, "", name)
    sub(/^((override|export|private)[ \t]+)+/, "", name)
    key = "var:" norm(name)
    search_foreach(t, key)
    match(substr(t, p), /^:*=/)
    search_shell(substr(t, p + RLENGTH), key)
    inrule = 0
    return
  }

  if (p) {
    ctx = "rule:" norm(substr(t, 1, p - 1))
    inrule = 1
    s = find0(substr(r, p + 1), ";#")
    if (s && substr(r, p + s, 1) == ";") {
      search(substr(r, 1, p + s - 1), ctx)
      search(substr(r, p + s + 1), ctx)
    } else {
      search(t, ctx)
    }
    return
  }

  search(t, "toplevel")
  inrule = 0
}

# A recipe line, or a define body line (which make may later run as one).
# A physical line whose first non-blank character (after the @+- prefixes, on
# a recipe's first line) is # is a shell comment: skipped, but its newline
# still ends the command before it, hence the ";".
function recipe(key,   i, p, sh) {
  sh = ""
  for (i = 1; i <= np; i++) {
    p = phys[i]
    if (i == 1) sub(/^[ \t@+-]*/, "", p)
    else sub(/^[ \t]+/, "", p)
    sh = sh (p ~ /^#/ ? " ;" : " " p)
  }
  search(sh, key)
}

function search(s, key) {
  search_foreach(s, key)
  search_shell(s, key)
}

function search_foreach(s, key) {
  while (match(s, /\$+[({]foreach[ \t]/)) {
    emit(key, "foreach")
    s = substr(s, RSTART + RLENGTH)
  }
}

function search_shell(s, key,   at, m, kind) {
  while (match(s, SHELL_LOOP)) {
    at = RSTART
    m = substr(s, RSTART, RLENGTH)
    match(m, /for|while|until/)
    at += RSTART - 1
    kind = substr(m, RSTART, RLENGTH)
    m = substr(m, RSTART)
    if (key ~ /^define:/ || substr(s, at + RLENGTH) ~ DO_AFTER || m ~ FOR_NAME_DO)
      emit(key, kind)
    # Resume just past the keyword's first character; the "_" keeps the
    # remainder's start from counting as command position.
    s = "_" substr(s, at + 1)
  }
}

function emit(key, kind) {
  print file "\t" key "\t" kind "\t" logical_text
}

# Position of the first character of s that is in set and outside any
# $(...)/${...} reference, or 0. $$ and backslash-escaped characters never
# match.
function find0(s, set,   i, n, c, d) {
  n = length(s)
  d = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; continue }
    if (d) {
      if (c == "(" || c == "{") d++
      else if (c == ")" || c == "}") d--
      continue
    }
    if (c == "$") {
      c = substr(s, i + 1, 1)
      if (c == "(" || c == "{") d++
      i++
      continue
    }
    if (index(set, c)) return i
  }
  return 0
}

function norm(s) {
  gsub(/[ \t]+/, " ", s)
  sub(/^ /, "", s)
  sub(/ $/, "", s)
  return s
}
