#!/bin/bash
# Runs a benchmark on a replica, on the NUMA node of the NIC. The Mu threads get
# the first 6 cores of that node and the main thread gets the 7th. Using
# numactl's order avoids hyperthreads and works with any core numbering.
# Usage: node-run.sh <binary> <args...>

source /local/rdma.env 2>/dev/null
NUMA="${RDMA_NUMA:-0}"
[ "$NUMA" -lt 0 ] 2>/dev/null && NUMA=0

CORES=($(numactl -H | awk -v n="$NUMA" '$1 == "node" && $2 == n && $3 == "cpus:" { for (i = 4; i <= NF; i++) print $i }'))
if [ "${#CORES[@]}" -lt 7 ]; then
  echo "NUMA node $NUMA has fewer than 7 cores" >&2
  exit 1
fi

export DORY_CORE_IDS="${CORES[0]},${CORES[1]},${CORES[2]},${CORES[3]},${CORES[4]},${CORES[5]}"
exec numactl --membind "$NUMA" --physcpubind "${CORES[6]}" -- "$@"
