# pgxntool-test

Test harness for [pgxntool](https://github.com/decibel/pgxntool), a PostgreSQL extension build framework.

## Requirements

- PostgreSQL with development headers
- [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core)
- rsync
- asciidoctor (for documentation tests)

### Installing BATS

```bash
# macOS
brew install bats-core

# Linux (via git)
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

## Running Tests

```bash
# Run all tests
make test

# Run only BATS tests
make test-bats

# Run only legacy string-based tests
make test-legacy
```

## How Tests Work

This test harness validates pgxntool by:
1. Cloning the pgxntool-test-template (a minimal PostgreSQL extension)
2. Injecting pgxntool into it via git subtree
3. Running various pgxntool operations (setup, build, test, dist)
4. Validating the results

See [CLAUDE.md](CLAUDE.md) for detailed documentation.

## Test Organization

- `tests/` - Legacy string-based tests (output comparison)
- `tests-bats/` - Modern BATS tests (semantic assertions)
- `expected/` - Expected outputs for legacy tests
- `lib.sh` - Common test utilities

## Development

When tests fail, check `diffs/*.diff` to see what changed. If the changes are correct, run `make sync-expected` to update expected outputs (legacy tests only).
