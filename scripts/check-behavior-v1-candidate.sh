#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v forge >/dev/null 2>&1; then
  echo "ERROR: forge not found in PATH" >&2
  exit 127
fi

echo "== BLADE Behavior v1 candidate: automated gates =="
echo "repo: $ROOT"
echo "head: $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
echo "forge: $(forge --version | head -1)"
echo

forge fmt --check
forge build
forge test

echo
echo "== Focused gates =="
forge test --match-contract ActionTest
forge test --match-contract BehaviorActionDispatchTest
forge test --match-contract IntegratedBehaviorExampleTest
forge test --match-contract BehaviorInvariantTest
forge test --match-contract BehaviorRuntimeTest
forge test --match-contract ExplicitExecutorGateTest
forge test --match-contract EmbeddedApplicationBehaviorTest

echo
echo "PASS: automated build/test gates completed."
echo "NOTE: this does not choose an optimization winner or complete the Behavior v1 freeze."
echo
git status --short
