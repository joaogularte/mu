#include <atomic>
#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <unistd.h>

#include <dory/crash-consensus.hpp>

#include "helpers.hpp"

// Repeatedly pauses the leader (process 1) and measures the fail-over time on
// the process that takes over. Pausing stops the heartbeat of the leader, as
// `fifo` does, and the leader also stops proposing at that moment.
//
// The total time is measured with a single clock, on the new leader: it starts
// when that process commits its last entry from the old leader and ends when
// its own first proposal is replicated. Since a commit is piggybacked on the
// next entry, the start is one entry earlier than the pause (~1us). The switch
// of permissions is included in the total time; the rest is detection.

using Clock = std::chrono::steady_clock;

static constexpr auto proposeBeforePause = std::chrono::milliseconds(2);

static uint64_t nowNs() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                   Clock::now().time_since_epoch())
                                   .count());
}

static void spinFor(std::chrono::nanoseconds duration) {
  auto until = Clock::now() + duration;
  while (Clock::now() < until) {
    ;
  }
}

static void sendCommand(int fd, char command) {
  if (write(fd, &command, 1) != 1) {
    throw std::runtime_error("Failed to write to the fifo: " +
                             std::string(std::strerror(errno)));
  }
}

static void pauseLeaderRepeatedly(dory::Consensus& consensus, int id,
                                  int rounds, std::vector<uint8_t>& payload,
                                  int payload_size, int settle_ms) {
  std::string fifo("/tmp/fifo-" + std::to_string(id));
  int fd = open(fifo.c_str(), O_WRONLY);
  if (fd == -1) {
    throw std::runtime_error("Could not open the fifo: " +
                             std::string(std::strerror(errno)));
  }

  auto settle = std::chrono::milliseconds(settle_ms);

  for (int round = 0; round < rounds;) {
    // Become the leader again (the lowest id that is alive is the leader)
    while (consensus.propose(&payload[0], payload_size) !=
           dory::ProposeError::NoError) {
      spinFor(std::chrono::microseconds(1));
    }

    bool ok = true;
    auto until = Clock::now() + proposeBeforePause;
    while (ok && Clock::now() < until) {
      ok = consensus.propose(&payload[0], payload_size) ==
           dory::ProposeError::NoError;
    }

    if (!ok) {
      std::cout << "Lost leadership before the pause, retrying" << std::endl;
      std::this_thread::sleep_for(settle);
      continue;
    }

    sendCommand(fd, 'p');
    while (!consensus.blockedResponse()) {
      consensus.propose(&payload[0], payload_size);
    }

    std::this_thread::sleep_for(settle);
    sendCommand(fd, 'c');
    std::this_thread::sleep_for(settle);

    round += 1;
    if (round % 100 == 0) {
      std::cout << "Finished round " << round << std::endl;
    }
  }

  std::cout << "Finished " << rounds << " rounds" << std::endl;
  exit(0);
}

static void measureTakeovers(dory::Consensus& consensus, int id,
                             std::atomic<uint64_t>& commits,
                             std::atomic<uint64_t>& last_commit_ns,
                             std::vector<uint8_t>& payload, int payload_size) {
  std::ofstream total("failover-total-" + std::to_string(id) + ".txt");
  std::ofstream permissions("failover-permissions-" + std::to_string(id) +
                            ".txt");

  uint64_t seen_commits = 0;

  while (true) {
    // Attempt to propose only when there is a leader to take over from
    if (commits.load() == seen_commits) {
      spinFor(std::chrono::microseconds(10));
      continue;
    }

    auto err = consensus.propose(&payload[0], payload_size);
    if (err != dory::ProposeError::NoError) {
      spinFor(std::chrono::microseconds(1));
      continue;
    }

    auto end = nowNs();
    auto elapsed = end - last_commit_ns.load();
    seen_commits = commits.load();

    total << elapsed << std::endl;

    auto switch_ns = consensus.lastPermissionSwitchNs();
    if (switch_ns == 0) {
      std::cout << "Takeover required a hard reset of the connections"
                << std::endl;
    } else {
      permissions << switch_ns << std::endl;
    }
  }
}

int main(int argc, char* argv[]) {
  if (argc < 5) {
    throw std::runtime_error(
        "Provide <process_id> <rounds> <payload_size> <settle_ms>");
  }

  constexpr int nr_procs = 3;
  constexpr int minimum_id = 1;
  int id = atoi(argv[1]);
  if (id < minimum_id || id >= minimum_id + nr_procs) {
    throw std::runtime_error("Invalid id");
  }

  int rounds = atoi(argv[2]);
  int payload_size = atoi(argv[3]);
  int settle_ms = atoi(argv[4]);

  std::vector<int> remote_ids;
  for (int i = 0, min_id = minimum_id; i < nr_procs; i++, min_id++) {
    if (min_id != id) {
      remote_ids.push_back(min_id);
    }
  }

  std::atomic<uint64_t> commits{0};
  std::atomic<uint64_t> last_commit_ns{0};

  // Outstanding requests are disabled, so that a proposal that returns has been
  // replicated.
  dory::Consensus consensus(id, remote_ids, 0, dory::ThreadBank::A);
  consensus.commitHandler([&commits, &last_commit_ns](
                              bool leader, [[maybe_unused]] uint8_t* buf,
                              [[maybe_unused]] size_t len) {
    if (!leader) {
      last_commit_ns.store(nowNs());
      commits.fetch_add(1);
    }
  });

  // Wait enough time for the consensus to become ready
  std::cout << "Wait some time" << std::endl;
  std::this_thread::sleep_for(std::chrono::seconds(5 + 3 - id));

  std::vector<uint8_t> payload(payload_size + 1);
  mkrndstr_ipa(payload_size, &payload[0]);

  if (id == minimum_id) {
    pauseLeaderRepeatedly(consensus, id, rounds, payload, payload_size,
                          settle_ms);
  } else {
    measureTakeovers(consensus, id, commits, last_commit_ns, payload,
                     payload_size);
  }

  return 0;
}
