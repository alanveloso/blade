#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/check-behavior-v1-candidate.sh
./scripts/behavior-optimization-campaign.sh
./scripts/behavior-architecture-benchmark.sh

echo
echo "Automated local flow completed."
echo "Manual review still required before adopting an optimization or freezing Behavior v1."
echo "Send the local-evidence/ logs back for ranking/decision."
