#!/bin/bash
# Latency vs. throughput (paper section 7.4, Figure 7).
# A batch of B 64-byte requests is replicated as one proposal of B * 64 bytes.
# Throughput comes from main-st (no per-operation timestamps) and the latency of
# the same point from main-st-lat.
# Usage: run-throughput.sh [samples]

source "$( dirname "${BASH_SOURCE[0]}" )/common.sh"

SAMPLES="${1:-150000}"
OUT="$RESULTS_DIR/throughput"
mkdir -p "$OUT"

for outstanding in 1 2 4 8; do
  for batch in 4 8 16 32 64 128; do
    payload=$((batch * 64))
    echo "== outstanding $outstanding, batch $batch"
    run_replicas "$OUT/st-$payload-$outstanding" "" main-st "$payload" "$outstanding" "$SAMPLES"
    run_replicas "$OUT/lat-$payload-$outstanding" "" main-st-lat "$payload" "$outstanding" "$SAMPLES" || continue
    $SCP "${REPLICAS[0]}:$WORK_DIR/dump-st-$payload-$outstanding.txt" "$OUT/"
  done
done

python3 "$PAPER_DIR/summarize.py" throughput "$OUT" | tee "$OUT/summary.csv"
