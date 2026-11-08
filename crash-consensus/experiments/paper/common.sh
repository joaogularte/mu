#!/bin/bash
# Shared by the run-*.sh scripts. They run on the client (node3 of the
# mu-cloudlab-ib profile) and drive the replicas over SSH.

set -u

PAPER_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
BIN_DIR="$PAPER_DIR/../../demo/using_conan_fully/build/bin"

REPLICAS=(${REPLICAS:-10.10.1.1 10.10.1.2 10.10.1.3})
REGISTRY_IP="${REGISTRY_IP:-10.10.1.4}"
REGISTRY_PORT="${REGISTRY_PORT:-9999}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/mu-results}"
RUN_TIMEOUT_S="${RUN_TIMEOUT_S:-1800}"
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes"
SCP="scp -q -o StrictHostKeyChecking=no -o BatchMode=yes"
WORK_DIR=/tmp/mu-run

reset_registry() {
  pkill -x memcached 2>/dev/null
  sleep 1
  memcached -d -l "$REGISTRY_IP" -p "$REGISTRY_PORT"
  sleep 1
}

stop_replicas() {
  local binary=$1
  for host in "${REPLICAS[@]}"; do
    $SSH "$host" "pkill -KILL -x $binary" 2>/dev/null
  done
  sleep 2
}

# Usage: run_replicas <log-prefix> <extra-env> <binary> <args after the id>
# Returns once process 1 exits. A process takes the id of its place in REPLICAS.
run_replicas() {
  local prefix=$1 extra_env=$2 binary=$3
  shift 3

  stop_replicas "$binary"
  reset_registry

  local first_pid="" id=1
  for host in "${REPLICAS[@]}"; do
    $SSH "$host" "mkdir -p $WORK_DIR && cd $WORK_DIR && rm -f failover-*.txt dump-st-*.txt &&
      DORY_REGISTRY_IP=$REGISTRY_IP:$REGISTRY_PORT $extra_env \
      timeout $RUN_TIMEOUT_S $PAPER_DIR/node-run.sh $BIN_DIR/$binary $id $*" \
      > "$prefix-$id.log" 2>&1 &
    [ "$id" = 1 ] && first_pid=$!
    id=$((id + 1))
  done

  wait "$first_pid"
  local status=$?
  stop_replicas "$binary"
  wait 2>/dev/null

  if [ "$status" != 0 ]; then
    echo "!! process 1 exited with status $status, see $prefix-1.log"
  fi
  return "$status"
}
