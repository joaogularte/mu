#!/bin/bash
# Fail-over time (paper section 7.3, Figure 6).
# Usage: run-failover.sh [rounds]
# The maximum score comes from the paper. The paper does not report the scan
# interval: 40us is an estimate from its ~600us of detection time.

source "$( dirname "${BASH_SOURCE[0]}" )/common.sh"

ROUNDS="${1:-1000}"
PAYLOAD="${PAYLOAD:-64}"
SETTLE_MS="${SETTLE_MS:-200}"
HB_MAX_SCORE="${HB_MAX_SCORE:-15}"
HB_SCAN_US="${HB_SCAN_US:-40}"
OUT="$RESULTS_DIR/failover"
mkdir -p "$OUT"

run_replicas "$OUT/run" "DORY_HB_MAX_SCORE=$HB_MAX_SCORE DORY_HB_SCAN_US=$HB_SCAN_US" \
  main-failover "$ROUNDS" "$PAYLOAD" "$SETTLE_MS" || exit 1

$SCP "${REPLICAS[1]}:$WORK_DIR/failover-*-2.txt" "$OUT/"

grep -c "hard reset" "$OUT/run-2.log" | sed 's/^/takeovers with a hard reset: /'
python3 "$PAPER_DIR/summarize.py" failover "$OUT" | tee "$OUT/summary.csv"
