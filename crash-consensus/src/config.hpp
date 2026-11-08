#pragma once

#include <cstdlib>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace dory {
namespace ConsensusConfig {

static constexpr bool nameThreads = true;
static const char handoverThreadName[] = "thd_handover";
static const char consensusThreadName[] = "thd_consensus";
static const char switcherThreadName[] = "thd_switcher";
static const char heartbeatThreadName[] = "thd_heartbeat";
static const char followerThreadName[] = "thd_follower";
static const char fileWatcherThreadName[] = "thd_filewatcher";

static constexpr int handoverThreadBankAB_ID = 0;
static constexpr int fileWatcherThreadBankAB_ID = 10;

static constexpr int consensusThreadBankA_ID = 2;
static constexpr int consensusThreadBankB_ID = 12;

static constexpr int switcherThreadBankA_ID = 4;
static constexpr int switcherThreadBankB_ID = 14;

static constexpr int heartbeatThreadBankA_ID = 6;
static constexpr int heartbeatThreadBankB_ID = 16;

static constexpr int followerThreadBankA_ID = 8;
static constexpr int followerThreadBankB_ID = 18;

// Failure detector knobs. The defaults favor stability over detection speed
// (a follower scans every ~51ms, so it detects a failure in ~2.4s). The paper
// uses a maximum score of 15. Set the following environment variables to
// override them:
//   DORY_HB_MAX_SCORE: maximum score of a replica (at least 3)
//   DORY_HB_SCAN_US:   busy-wait this many us between scans, on every replica
struct HeartbeatConfig {
  HeartbeatConfig() {
    if (char const *env = std::getenv("DORY_HB_MAX_SCORE")) {
      maxScore = std::stoi(env);
    }

    if (char const *env = std::getenv("DORY_HB_SCAN_US")) {
      scanIntervalUs = std::stoi(env);
    }

    if (maxScore < 3 || scanIntervalUs < 0) {
      throw std::runtime_error("Invalid heartbeat configuration");
    }
  }

  int maxScore = 50;
  int scanIntervalUs = 0;  // 0 keeps the default sleep-based scanning
};

struct ThreadConfig {
  ThreadConfig()
      : pinThreads{true},
        handoverThreadCoreID{handoverThreadBankAB_ID},
        consensusThreadCoreID{consensusThreadBankA_ID},
        switcherThreadCoreID{switcherThreadBankA_ID},
        heartbeatThreadCoreID{heartbeatThreadBankA_ID},
        followerThreadCoreID{followerThreadBankA_ID},
        fileWatcherThreadCoreID{fileWatcherThreadBankAB_ID},
        prefix{""} {
    // Format: handover,consensus,switcher,heartbeat,follower,filewatcher
    if (char const *env = std::getenv("DORY_CORE_IDS")) {
      std::vector<int> ids;
      std::stringstream ss(env);
      std::string id;
      while (std::getline(ss, id, ',')) {
        ids.push_back(std::stoi(id));
      }

      if (ids.size() != 6) {
        throw std::runtime_error("DORY_CORE_IDS needs 6 core ids");
      }

      handoverThreadCoreID = ids[0];
      consensusThreadCoreID = ids[1];
      switcherThreadCoreID = ids[2];
      heartbeatThreadCoreID = ids[3];
      followerThreadCoreID = ids[4];
      fileWatcherThreadCoreID = ids[5];
    }
  }

  bool pinThreads;

  // If pinThreads is true, make sure to set the core id appropriately.
  // You can use `numatcl -H` to see which cores each numa domain has.
  // In hyperthreaded CPUs, numactl first lists the non-hyperthreaded cores
  // and then the hyperthreaded ones.

  int handoverThreadCoreID;
  int consensusThreadCoreID;
  int switcherThreadCoreID;
  int heartbeatThreadCoreID;
  int followerThreadCoreID;
  int fileWatcherThreadCoreID;
  std::string prefix;
};

}  // namespace ConsensusConfig
}  // namespace dory
