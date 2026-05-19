# .github/workflows — CI Architecture

## Workflow files

- **`ci.yml`** — main CI for pgxntool-test pull requests. Runs a `resolve` job
  (determines which pgxntool branch to test against), then calls `run-tests.yml`.
- **`run-tests.yml`** — reusable workflow (`workflow_call`). Single source of truth
  for all test steps (PostgreSQL matrix, checkouts, git config, pgtap install, etc.).
  Called by both `ci.yml` here and by `pgxntool/ci.yml` for the commit-with-no-tests path.

## Cross-repo reusable workflow — tradeoffs and constraints

`run-tests.yml` is referenced from **pgxntool** as:
```yaml
uses: Postgres-Extensions/pgxntool-test/.github/workflows/run-tests.yml@<ref>
```

GitHub Actions requires the `uses:` ref to be a **static string** — expressions are
not supported. This creates an unavoidable structural constraint:

### Merge order requirement

**pgxntool-test MUST be merged before pgxntool** whenever both repos change in the
same feature branch. Here's why:

- pgxntool's `ci.yml` pins to `run-tests.yml@master`
- While developing on a branch, pgxntool's `ci.yml` temporarily uses `@<branch>`
- When it's time to merge, pgxntool-test must land on master first so that
  `run-tests.yml@master` exists before pgxntool's CI tries to use it

### What this means for `run-tests.yml` changes

- Changes to `run-tests.yml` are always tested through **pgxntool-test's own CI**
  (which uses `./.github/workflows/run-tests.yml` — a local ref that always sees
  the current branch version).
- pgxntool's CI (commit-with-no-tests path) uses `run-tests.yml@master`. Until
  pgxntool-test merges, pgxntool CI will use the old master version.
- These two scenarios are mutually exclusive in practice: the commit-with-no-tests
  path only runs when there is NO paired test PR. If you're changing `run-tests.yml`,
  you have a paired test PR, so pgxntool's test job is skipped anyway.

### The @branch → @master transition

While developing on a feature branch, pgxntool's `ci.yml` uses `@<branch>` so CI
can find `run-tests.yml` before it lands on master. Before pgxntool can be merged,
pgxntool-test must merge first and then pgxntool's ref must be updated to `@master`.

**For Claude**: This transition is NOT automatic. You must get explicit user approval
before leaving a `@<branch>` ref in pgxntool's `ci.yml`. Do not assume this will be
handled at merge time — the user merges directly from the PR page with no manual steps.
The safe approach is to coordinate the merge order explicitly with the user.

## Expanding the matrix

The PostgreSQL version matrix (`pg: [17, 16, 15, 14, 13, 12]`) is hardcoded in
`run-tests.yml`. GitHub Actions does not support passing a matrix as a workflow_call
input. To add or remove a PG version, edit `run-tests.yml` directly.
