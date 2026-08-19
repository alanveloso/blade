#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v forge >/dev/null 2>&1; then
  echo "ERROR: forge not found in PATH" >&2
  exit 127
fi

STAMP="${BLADE_CAMPAIGN_STAMP:-$(date +%Y%m%d-%H%M%S)}"
OUT="${BLADE_CAMPAIGN_OUT:-$ROOT/local-evidence/behavior-optimization-$STAMP}"
mkdir -p "$OUT"

run_log() {
  local name="$1"
  shift
  echo "== $name =="
  "$@" 2>&1 | tee "$OUT/$name.log"
}

{
  echo "BLADE Behavior optimization engineering campaign"
  echo "timestamp=$STAMP"
  echo "head=$(git rev-parse HEAD 2>/dev/null || echo n/a)"
  echo "forge=$(forge --version | head -1)"
  echo "default_profile=via_ir=false"
  echo "notes=C1-C5 are measurement candidates; C6 reserve/cap sensitivity is not auto-adopted"
} | tee "$OUT/metadata.txt"

run_log "00-fmt" forge fmt --check
run_log "01-build" forge build
run_log "02-control-none" forge test --match-contract BehaviorV1BenchmarkTest -vv
run_log "03-control-application" forge test --match-contract BehaviorActionBenchmarkTest -vv
run_log "04-pool-candidates" forge test --match-contract PoolCompactionCandidatesTest -vv
run_log "05-compact-context" forge test --match-contract CompactContextCandidateTest -vv
run_log "06-decoder-candidates" forge test --match-contract DecoderCandidatesTest -vv
run_log "07-default-sizes" forge build --sizes

# C1: same source/tests under an experimental compiler profile. The default profile is not changed.
run_log "08-via-ir-full-suite" env FOUNDRY_PROFILE=via_ir forge test
run_log "09-via-ir-control-none" env FOUNDRY_PROFILE=via_ir forge test --match-contract BehaviorV1BenchmarkTest -vv
run_log "10-via-ir-control-application" env FOUNDRY_PROFILE=via_ir forge test --match-contract BehaviorActionBenchmarkTest -vv
run_log "11-via-ir-sizes" env FOUNDRY_PROFILE=via_ir forge build --sizes

cat > "$OUT/C6-NOT-AUTOMATED.txt" <<'NOTE'
C6 (operational caps/reserves) is sensitivity analysis, not a gas contest.
This campaign deliberately does not lower ENGINE_OVERHEAD, POST_CALL_OVERHEAD,
MAX_STRATEGY_RETURN, or MAX_INSTALLED_APPLICATION_BEHAVIORS automatically.
Any candidate that weakens a defensive reserve/cap requires a separate safety argument and approval.
NOTE

touch "$OUT/campaign.complete"
echo
echo "Campaign logs: $OUT"
echo "No product optimization was adopted by this script."
