#!/bin/bash
# Fail-over time for several numbers of replicas (run-failover.sh for each).
# Usage: run-failover-sweep.sh [rounds]
# With n replicas, the replicas are 10.10.1.1..n: process 1 (node0) is always
# the leader that is paused and process 2 (node1) the one that takes over.
# The numbers of replicas are interleaved (3, 5, ..., 3, 5, ...), so that a
# drift over time does not look like an effect of n.

SWEEP_N="${SWEEP_N:-3 5 7 9 11}"
REPS="${REPS:-3}"
MAX_REPLICAS="${MAX_REPLICAS:-11}"

# Every replica that a run may use, to clean up after a run that timed out.
# Plain assignments: `VAR=x source ...` would restore VAR after the source.
NR_REPLICAS="$MAX_REPLICAS"
REPLICAS=""
source "$( dirname "${BASH_SOURCE[0]}" )/common.sh"

ROUNDS="${1:-1000}"
BASE="${BASE:-$RESULTS_DIR/failover-sweep}"

for n in $SWEEP_N; do
  if [ "$n" -lt 3 ] || [ "$n" -gt "$MAX_REPLICAS" ]; then
    echo "!! n=$n is outside 3..$MAX_REPLICAS (MAX_REPLICAS)"
    exit 1
  fi
done

mkdir -p "$BASE"
# The IB topology: replicas behind different switches have different latencies
sudo -n iblinkinfo > "$BASE/iblinkinfo.txt" 2>&1 ||
  echo "iblinkinfo failed, see $BASE/iblinkinfo.txt"

failed=""
for rep in $(seq 1 "$REPS"); do
  for n in $SWEEP_N; do
    out="$BASE/n$n/rep$rep"
    rm -rf "$out"
    echo "== $(date '+%F %T') n=$n rep=$rep"
    stop_replicas main-failover
    REPLICAS="" NR_REPLICAS="$n" OUT="$out" "$PAPER_DIR/run-failover.sh" "$ROUNDS" ||
      failed="$failed n$n/rep$rep"
  done
done

summary="$BASE/summary.csv"
echo "n,rep,metric,samples,p1_ns,p50_ns,p99_ns,mean_ns,max_ns,hard_resets" > "$summary"
for n in $SWEEP_N; do
  for rep in $(seq 1 "$REPS"); do
    out="$BASE/n$n/rep$rep"
    [ -f "$out/summary.csv" ] || continue
    resets=$(grep -c "hard reset" "$out/run-2.log" 2>/dev/null)
    tail -n +2 "$out/summary.csv" | sed "s/^/$n,$rep,/; s/\$/,${resets:-0}/" >> "$summary"
  done
done

echo "== summary ($summary)"
cat "$summary"
[ -z "$failed" ] || { echo "!! failed runs:$failed"; exit 1; }
