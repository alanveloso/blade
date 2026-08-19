#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v forge >/dev/null 2>&1; then
  echo "ERROR: forge not found in PATH" >&2
  exit 127
fi

STAMP="${BLADE_ARCH_STAMP:-$(date +%Y%m%d-%H%M%S)}"
OUT="${BLADE_ARCH_OUT:-$ROOT/local-evidence/behavior-architecture-$STAMP}"
mkdir -p "$OUT"

{
  echo "BLADE paired Behavior architecture engineering benchmark"
  echo "timestamp=$STAMP"
  echo "head=$(git rev-parse HEAD 2>/dev/null || echo n/a)"
  echo "forge=$(forge --version | head -1)"
  echo "comparison=external STATICCALL product locus vs embedded research counterfactual"
  echo "claim=engineering measurement only; not JAAMAS evidence"
} | tee "$OUT/metadata.txt"

forge test --match-contract BehaviorArchitectureBenchmarkTest -vv 2>&1 | tee "$OUT/step-gas.log"
forge build --sizes 2>&1 | tee "$OUT/sizes.log"
touch "$OUT/benchmark.complete"

echo "Architecture benchmark logs: $OUT"
