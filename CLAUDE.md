# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Source code for the "Microsecond Consensus for Microsecond Applications" (Mu) paper: an RDMA-based crash-fault-tolerant consensus library (`crash-consensus`), plus the experiments that replicate Redis, Memcached and Liquibook on top of it. It targets Linux hosts with RDMA (ibverbs) NICs. It will not build or run on macOS. The system dependencies are listed in `Dockerfile` and the README (libibverbs, libmemcached, conan 1.x, cmake, ninja, clang/gcc, gtest, numactl, libhugetlbfs, ...).

## Build

Every top-level directory is a separate **conan 1.x package** (`dory-<name>/0.0.1`) with its own `conanfile.py` and `src/CMakeLists.txt`. The root `Makefile` builds them in dependency order and runs `conan create` on each, installing it into the local conan cache. `build.py` wraps that Makefile:

```sh
./build.py crash-consensus              # build one target plus its local deps (default: gcc, release)
./build.py -c clang -b debug all        # compiler: gcc|clang; build type: debug|release|relwithdebinfo|minsizerel
./build.py clean                        # drop .deps/ stamps (forces a rebuild check)
./build.py distclean                    # also rm */build and `conan remove -f "dory-*"`
```

- Builds are incremental. Stamp files in `.deps/` are compared with source mtimes, and changing a dependency rebuilds the packages that depend on it. If a target has a `build.sh`, the Makefile runs that script instead of `conan create`.
- The local dependency graph is declared in the "editable area" of the `Makefile`. Update it whenever you add a package or a dependency:
  - `memstore`, `ctrl` ← `shared`, `extern`
  - `conn` ← `shared`, `ctrl`, `memstore`
  - `crypto` ← `shared`, `memstore`
  - `crash-consensus`, `demo` ← `extern`, `shared`, `memstore`, `ctrl`, `conn` (`neb` also ← `crypto`)
- Compiler and warning flags live in `conan/exports/compiler-options/compileroptions.py`. Packages pull them in through `python_requires = "dory-compiler-options/0.0.1@dory/stable"`. The profiles live in `conan/profiles/{gcc,clang}-{build_type}.profile`, and the build selects one via `CONAN_DEFAULT_PROFILE_PATH`.
- Log level is a per-package conan option, for example `dory-crash-consensus:log_level=INFO`. It is compiled in as `SPDLOG_ACTIVE_LEVEL`.

Full crash-consensus pipeline (from the README):

```sh
./build.py crash-consensus
crash-consensus/libgen/export.sh gcc-release            # static+shared libcrashconsensus -> crash-consensus/libgen/exported
crash-consensus/demo/using_conan_fully/build.sh gcc-release   # main-st, main-st-lat, fifo, ... in build/bin
crash-consensus/experiments/build.sh                    # patched redis/memcached + latency clients
crash-consensus/experiments/liquibook/build.sh
export LD_LIBRARY_PATH=$PWD/crash-consensus/experiments/exported:$LD_LIBRARY_PATH
```

`libgen/export.sh` merges every dependency's `.a` into a single `libcrashconsensus.a` and `.so`. The experiments link against it through the C API (`crash-consensus.h`). They apply source patches to the upstream tarballs (`redis-2.8.24.patch`, `memcached-1.5.19.patch`, `liquibook/step*.patch`), so changes to the replicated apps belong in those patches.

## Tests, formatting, CI

- Unit tests exist only for `neb`, using gtest: `CONAN_DEFAULT_PROFILE_PATH="$(pwd)/conan/profiles/gcc-release.profile" conan test ./neb/test dory-neb/0.0.1 --build=missing`. Alternatively, `neb/test/build.sh` produces `neb/test/build/bin/main`; filter tests with `--gtest_filter=...`.
- `test/integration/crypto` and `test/bench/crypto` are standalone conan/cmake projects, each with its own `build.sh`.
- Formatting: `./format.sh [files...]` runs clang-format with the repo's `.clang-format`, which is Google-based. GitHub Actions runs a clang-format **v6** lint over all `.cpp`/`.hpp` files on master and on PRs, so run it before committing.
- CircleCI builds `all` with gcc and with clang, in both release and debug, then runs the neb tests.

## Running

- Processes rendezvous through a **memcached registry**: `memstore` (`MemoryStore`) publishes and looks up QP info by key. Every node needs `DORY_REGISTRY_IP=<host>:<port>` set, with memcached running there. Restart memcached between runs, or run `crash-consensus/experiments/deploy/reset_registry.sh`, because stale keys break connection setup.
- Experiments need at least 3 replicas started at nearly the same time, e.g. `main-st <process_id> <payload_size> <outstanding_reqs>`, launched under `numactl --membind 0`. The replicated Redis and Memcached builds read `SID` (own id) and `IDS=1,2,3` from the environment. The README walks through each experiment.
- `fifo /tmp/fifo-<id>` plus input `p` pauses a leader to force a leader switch, and `c` resumes it.
- `crash-consensus/experiments/paper/` has the CloudLab scripts for the latency, fail-over and throughput experiments of the paper. See its README.
- Runtime overrides: `DORY_HB_MAX_SCORE` and `DORY_HB_SCAN_US` tune the failure detector (the defaults detect in ~2.4s, not the paper's ~600us), and `DORY_CORE_IDS` overrides the thread pinning in `config.hpp`.

## crash-consensus architecture (`crash-consensus/src`)

- **Public API**: `crash-consensus.hpp` (`dory::Consensus`, a pimpl over `RdmaConsensus`) and its C wrapper, `crash-consensus.h` / `crash-consensus-c-wrapper.cpp`. These are the only headers that get packaged. `ProposeError` is duplicated in three places (the C++ API, the C API, and `RdmaConsensus::ProposeError`), so any change must be made in all three.
- **Setup** (`RdmaConsensus::run` in `consensus.cpp`): opens the last RDMA device and binds port 0. It registers a single 2 GiB shared MR, which `OverlayAllocator` splits into per-process scratchpads (`memory.hpp`) and the replication log (`log/`). It then creates two separate connection sets through `ConnectionExchanger`, each with its own CQ: **replication** and **leader election** (the latter also gets a loopback QP).
- **Replication path**: the leader calls `propose()`, which RDMA-writes log entries straight into the followers' logs and waits for a majority through `FixedSizeMajorityOperation` + `SequentialQuorumWaiter` (the fast path). After a leader change, or when the fast path fails, the slow path (`slow-path.hpp`: `CatchUpWithFollowers`, `LogSlotReader`) reads the remote logs, adopts any value it finds, and updates the followers. `log-recycling.hpp` reclaims log space. Commits are piggybacked, so an entry only commits once the next proposal is replicated.
- **Followers** (`follower.hpp`) poll the local log in a dedicated thread and call the user's `commitHandler(leader, buf, len)`.
- **Leader election** (`leader-switch.hpp`): `LeaderHeartbeat` writes and reads heartbeat counters, and `LeaderSwitcher` / `LeaderPermissionAsker` handle failover. Write permission is enforced by changing QP access flags on the replicas. The consensus thread loops on `checkAndApplyConnectionPermissionsOK`, and the `ask_reset` flag lets `propose()` request a hard reset.
- **Threads and pinning**: `config.hpp` fixes the core IDs for the handover, consensus, switcher, heartbeat, follower and file-watcher threads, in two banks (`ThreadBank::A`/`B`) so that two instances can share a machine. These threads busy-poll, so check the core layout (`numactl -H`) before you change the IDs.

## Other packages

- `extern`: thin wrappers over ibverbs and libmemcached.
- `shared`: logger (spdlog), units, pinning, `branching.hpp` (`likely`/`unlikely`).
- `ctrl`: device, port and PD/MR/CQ control block.
- `conn`: RC queue pairs and the QP exchanger.
- `memstore`: the registry described above.
- `crypto`: ed25519 signing, through a prebuilt Rust FFI lib (`crypto/lib`) or libsodium.
- `neb`: non-equivocating broadcast, with sync and async variants, a `membership` file and scripts under `neb/scripts`.
- `demo`: a minimal usage example of these packages.
