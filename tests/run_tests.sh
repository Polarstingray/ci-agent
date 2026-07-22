#!/usr/bin/env bash
# Run the full repman-ci test suite.
# Usage:
#   ./tests/run_tests.sh               # run all tests
#   ./tests/run_tests.sh --install-bats # clone bats-core locally then exit
#   ./tests/run_tests.sh --unit-only    # run only Python unit tests
#   ./tests/run_tests.sh --shell-only   # run only bats shell tests
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(dirname "$TESTS_DIR")"

# --- Handle --install-bats flag ---
if [[ "${1:-}" == "--install-bats" ]]; then
    git clone https://github.com/bats-core/bats-core "$TESTS_DIR/bats-core" --depth=1 -q
    echo "bats-core installed at $TESTS_DIR/bats-core/bin/bats"
    exit 0
fi

RUN_UNIT=1
RUN_SHELL=1
if [[ "${1:-}" == "--unit-only" ]];  then RUN_SHELL=0; fi
if [[ "${1:-}" == "--shell-only" ]]; then RUN_UNIT=0;  fi

FAIL=0

# --- Python unit tests ---
if [[ "$RUN_UNIT" == 1 ]]; then
    echo "=== Python unit tests ==="

    VENV="$REPO_ROOT/.venv"
    if [[ ! -d "$VENV" ]]; then
        python3 -m venv "$VENV"
    fi
    "$VENV/bin/pip" install --quiet -r "$REPO_ROOT/requirements.txt"

    "$VENV/bin/pytest" "$TESTS_DIR/unit/" -v || FAIL=1
    echo ""
fi

# --- Shell tests (bats) ---
if [[ "$RUN_SHELL" == 1 ]]; then
    # Locate bats: system-wide, or a local clone under tests/bats-core/
    BATS=""
    if command -v bats >/dev/null 2>&1; then
        BATS="$(command -v bats)"
    elif [[ -x "$TESTS_DIR/bats-core/bin/bats" ]]; then
        BATS="$TESTS_DIR/bats-core/bin/bats"
    fi

    if [[ -z "$BATS" ]]; then
        echo "WARNING: bats not found. Skipping shell tests."
        echo "  Install system bats:  sudo apt install bats  (or brew install bats-core)"
        echo "  Or install locally:   $0 --install-bats"
        echo ""
    else
        echo "=== Shell integration tests ==="
        "$BATS" "$TESTS_DIR/integration/" || FAIL=1
        echo ""

        echo "=== End-to-end tests ==="
        "$BATS" "$TESTS_DIR/e2e/" || FAIL=1
        echo ""
    fi
fi

# --- Cross-repo e2e (repman-ci -> repman), real crypto, no mocks ---
# Runs only when the repman client repo is available; otherwise skipped so the
# default suite has no hard dependency on a sibling checkout.
if [[ "$RUN_SHELL" == 1 ]]; then
    REPMAN_DIR="${REPMAN_DIR:-$(cd "$REPO_ROOT/../repman" 2>/dev/null && pwd || true)}"
    if [[ -n "$REPMAN_DIR" && -d "$REPMAN_DIR" ]]; then
        echo "=== Cross-repo e2e (repman-ci -> repman) ==="
        REPMAN_DIR="$REPMAN_DIR" "$TESTS_DIR/e2e/cross_repo_install.sh" || FAIL=1
        echo ""
    else
        echo "NOTE: repman client repo not found — skipping cross-repo e2e."
        echo "  Set REPMAN_DIR=/path/to/repman to enable it."
        echo ""
    fi
fi

if [[ "$FAIL" == 1 ]]; then
    echo "=== TESTS FAILED ==="
    exit 1
fi

echo "=== All tests passed ==="
