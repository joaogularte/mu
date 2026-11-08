#!/bin/bash
# Standalone replication latency (paper section 7.1, Figure 3).
# Usage: run-latency.sh [samples]

source "$( dirname "${BASH_SOURCE[0]}" )/common.sh"

SAMPLES="${1:-1000000}"
OUT="$RESULTS_DIR/latency"
mkdir -p "$OUT"

for payload in 32 50 64 128 256 512; do
  echo "== payload $payload"
  run_replicas "$OUT/run-$payload" "" main-st-lat "$payload" 1 "$SAMPLES" || continue
  $SCP "${REPLICAS[0]}:$WORK_DIR/dump-st-$payload-1.txt" "$OUT/"
done

python3 "$PAPER_DIR/summarize.py" latency "$OUT" | tee "$OUT/summary.csv"
