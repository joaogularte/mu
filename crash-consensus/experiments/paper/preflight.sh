#!/bin/bash
# Checks what the experiments need. Run it on the client (node3).

source "$( dirname "${BASH_SOURCE[0]}" )/common.sh"

for tool in memcached numactl python3; do
  command -v "$tool" >/dev/null || echo "FAIL: $tool not found on the client"
done

for host in "${REPLICAS[@]}"; do
  echo "== $host"
  $SSH "$host" "
    source /local/rdma.env 2>/dev/null || echo 'FAIL: /local/rdma.env not found'
    for bin in main-st main-st-lat main-failover; do
      [ -x $BIN_DIR/\$bin ] || echo \"FAIL: \$bin is not built\"
    done
    ibv_devinfo -d \$RDMA_DEV -i \$RDMA_PORT | grep -E 'state|active_mtu|link_layer'
    ibv_devinfo -d \$RDMA_DEV -i \$RDMA_PORT | grep -q 'active_mtu:.*4096' ||
      echo 'FAIL: the active MTU is not 4096, but the QPs use a path MTU of 4096'
    ibv_devices | awk 'NR > 2 && NF { last = \$1 } END { print last }' | grep -qx \"\$RDMA_DEV\" ||
      echo 'FAIL: Mu uses the last RDMA device, which is not the selected one'
    echo \"NUMA node of the NIC: \$RDMA_NUMA\"
    [ \"\$(ulimit -l)\" = unlimited ] || echo \"FAIL: memlock limit is \$(ulimit -l)\"
    grep -H . /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
  " || echo "FAIL: cannot SSH into $host from the client"
done
