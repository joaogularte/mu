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

The profile clones this fork ([joaogularte/mu](https://github.com/joaogularte/mu))
into `/local/mu`, but only if `/local/mu` does not exist yet. In an experiment
created before the profile switched to the fork, or to get newer commits, update
the clone on all 4 nodes:

```sh
cd /local/mu
git remote set-url origin https://github.com/joaogularte/mu.git
git pull
```

Once `/local/setup.log` says `fim`, build the library and the benchmarks on all 4
nodes, as your user (not root):

```sh
/local/repository/build-mu.sh
source ~/.bashrc
```

`build-mu.sh` sets up the Conan profile, then runs `./build.py crash-consensus`
and `crash-consensus/demo/using_conan_fully/build.sh gcc-release`, which build
`main-st`, `main-st-lat` and `main-failover`. It does not build the Redis,
Memcached and Liquibook experiments. It also adds `source /local/rdma.env` to
`~/.bashrc`. Run it again after a `git pull`.

`node3` must be able to SSH into the replicas without a password, since the
scripts use `ssh -o BatchMode=yes`. Otherwise `preflight.sh` reports
`Permission denied (publickey)`. Create a key on `node3` and add it to the
replicas:

```sh
# node3
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
# node0, node1 and node2
echo '<the line printed above>' >> ~/.ssh/authorized_keys
```

Connecting to `node3` with `ssh -A` also works, but only if your key is loaded in
your local agent (`ssh-add -l`), and not inside a `tmux` session started before
the connection.

Then check the setup from `node3` and fix anything reported as `FAIL`:

```sh
cd /local/mu/crash-consensus/experiments/paper
./preflight.sh
```

## Running

From the same directory on `node3` (the client):

```sh
./run-latency.sh        # ~5 min
./run-failover.sh       # ~10 min
./run-throughput.sh     # ~30 min
```

Start with a short run of each script (`./run-failover.sh 20`,
`./run-latency.sh 10000`, `./run-throughput.sh 5000`).

## Scaling the number of replicas

The scripts take the replicas from `NR_REPLICAS` (default 3), as
`10.10.1.1..NR_REPLICAS`, or from an explicit `REPLICAS="ip ip ..."`. The
registry defaults to the client's own IP (`RDMA_IP` in `/local/rdma.env`), so
the client can be any node after the replicas. With a 12-node experiment,
`node0..node10` are replicas 1..11 and `node11` (`10.10.1.12`) is the client.
Only `main-failover` takes the number of processes (as a 5th argument); the
latency and throughput benchmarks still use 3.

Check all the replicas, then run the sweep from the client:

```sh
NR_REPLICAS=11 ./preflight.sh
NR_REPLICAS=11 ./run-failover.sh 20       # short check with every replica
./run-failover-sweep.sh                   # ~2.5 h with the defaults
```

`run-failover-sweep.sh [rounds]` runs `run-failover.sh` for each n in `SWEEP_N`
(default `3 5 7 9 11`), `REPS` times (default 3), interleaved: 3, 5, ..., 11,
3, 5, ... For every n, process 1 (`node0`) is the leader that is paused and
process 2 (`node1`) the one that takes over, so the measured roles stay on the
same machines. It writes to `~/mu-results/failover-sweep` (or `BASE`):

| Path | Content |
|---|---|
| `n<N>/rep<R>/` | The output of `run-failover.sh` for that run |
| `iblinkinfo.txt` | IB topology at the start (needs passwordless `sudo`) |
| `summary.csv` | `n,rep,metric,samples,p1_ns,p50_ns,p99_ns,mean_ns,max_ns,hard_resets` |

`hard_resets` counts takeovers that took the slow path; they are not in the
`permissions` samples.

The new leader waits for every other replica, not a majority, to grant it
permissions (`waitForApprovalStep1` and `waitForApprovalStep2` in
`src/leader-switch.hpp`). The `permissions` time is therefore the slowest of
n-1 replicas. The paused leader still replies and only grants (one
`ibv_modify_qp`); the other n-2 replicas revoke and grant (two). The same wait
means that a replica that has really crashed blocks the takeover: the
experiment only pauses the heartbeat of the leader.

The heartbeat scan reads every other replica, so its work per iteration grows
with n. `HB_SCAN_US` stays the same for every n; compare the detection time
(`total - permissions`) across n before reading it as a cost of the protocol.

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
