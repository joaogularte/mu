# Paper experiments on CloudLab

Scripts for three experiments of the paper, on the 4 `c6220` nodes of the
[mu-cloudlab-ib](https://github.com/joaogularte/mu-cloudlab-ib) profile:
`node0..node2` are replicas 1..3 (`10.10.1.1..3`) and `node3` is the client and
the memcached registry (`10.10.1.4:9999`).

| Script | Paper | Output in `~/mu-results` |
|---|---|---|
| `run-latency.sh` | Section 7.1, Figure 3 (standalone bars) | `latency/` |
| `run-failover.sh` | Section 7.3, Figure 6 | `failover/` |
| `run-throughput.sh` | Section 7.4, Figure 7 | `throughput/` |

Each script writes the raw samples, the logs of all the replicas and a
`summary.csv`.

## Setup

The profile clones `LPD-EPFL/mu`, which does not have these changes. Copy this
tree over `/local/mu` on all 4 nodes from your machine, once `/local/setup.log`
says `fim`:

```sh
for node in <node0> <node1> <node2> <node3>; do
  rsync -az --delete --exclude .git --exclude build --exclude .deps ./ "$node":/local/mu/
done
```

On all 4 nodes, build the library and the benchmarks (`/local/repository/build-mu.sh`
also works, but it builds the Redis, Memcached and Liquibook experiments too):

```sh
cd /local/mu
./build.py crash-consensus
crash-consensus/demo/using_conan_fully/build.sh gcc-release
```

`node3` must be able to SSH into the replicas without a password. If it cannot,
connect to it with `ssh -A`. Then check the setup from `node3` and fix anything
reported as `FAIL`:

```sh
cd /local/mu/crash-consensus/experiments/paper
./preflight.sh
```

## Running

From the same directory on `node3`:

```sh
./run-latency.sh        # ~5 min
./run-failover.sh       # ~10 min
./run-throughput.sh     # ~30 min
```

Start with a short run of each script (`./run-failover.sh 20`,
`./run-latency.sh 10000`, `./run-throughput.sh 5000`).

## How each experiment works

- **Latency**: `main-st-lat` proposes in a tight loop on process 1, with 1
  outstanding request as in the top-level README. Payloads: 32 to 512 bytes.
- **Fail-over**: `main-failover` pauses the leader through its FIFO, measures the
  takeover on process 2, resumes the old leader, waits until it is the leader
  again and repeats. `failover-total-2.txt` has the total times and
  `failover-permissions-2.txt` the permission switches. Detection is the
  difference between the two. It uses a single clock, so the nodes do not need
  synchronized clocks.
- **Throughput**: every combination of 1, 2, 4, 8 outstanding requests and batches
  of 4 to 128 requests of 64 bytes.

## Differences from the paper

- **Hardware**: the paper uses ConnectX-4 and EDR (100 Gbps) with Xeon E5-2640 v4;
  `c6220` has ConnectX-3 and FDR (56 Gbps). Expect different absolute numbers, and
  especially a lower throughput ceiling.
- **Failure detector**: `run-failover.sh` sets a maximum score of 15, from the
  paper. The paper does not give the scan interval: the 40 us is an estimate from
  its ~600 us of detection time. If replicas change leaders without a pause, raise
  `HB_MAX_SCORE` or `HB_SCAN_US`. The paper's recovery threshold (6) is not in the
  code, which uses a single threshold (2).
- **Fail-over start time**: the paper does not say how it timed the fail-over. Here
  it starts at the last entry that the new leader committed from the old leader.
- **Batching**: the paper does not detail it. Here a batch is one proposal of
  `batch * 64` bytes, and the latency of a batch is the latency of its requests.
- **Outliers**: `summary.csv` keeps every sample, unlike `demo/src/stats.cpp`, which
  drops values above 40 us.
