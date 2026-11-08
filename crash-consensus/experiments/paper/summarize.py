#!/usr/bin/env python3
"""Prints CSV summaries of the results of the run-*.sh scripts. Unlike
demo/src/stats.cpp, it keeps every sample, so that the tail stays visible."""

import glob
import os
import re
import sys

REQUEST_SIZE = 64


def read_samples(path):
    with open(path) as f:
        return sorted(int(line) for line in f if line.strip().isdigit())


def percentile(samples, p):
    return samples[(len(samples) - 1) * p // 100]


def stats_ns(samples):
    return [
        len(samples),
        percentile(samples, 1),
        percentile(samples, 50),
        percentile(samples, 99),
        sum(samples) // len(samples),
        samples[-1],
    ]


STATS_HEADER = "samples,p1_ns,p50_ns,p99_ns,mean_ns,max_ns"


def dump_params(path):
    return map(int, re.fullmatch(r"dump-st-(\d+)-(\d+)\.txt", os.path.basename(path)).groups())


def latency(out):
    print("payload_bytes," + STATS_HEADER)
    rows = []
    for path in glob.glob(os.path.join(out, "dump-st-*.txt")):
        payload, _ = dump_params(path)
        rows.append([payload] + stats_ns(read_samples(path)))
    for row in sorted(rows):
        print(",".join(map(str, row)))


def throughput(out):
    print("outstanding,batch,ops_per_us,p50_latency_us,p1_latency_us,p99_latency_us")
    rows = []
    for path in glob.glob(os.path.join(out, "dump-st-*.txt")):
        payload, outstanding = dump_params(path)
        samples = read_samples(path)

        with open(os.path.join(out, "st-%d-%d-1.log" % (payload, outstanding))) as f:
            match = re.search(r"Replicated (\d+) commands of size \d+ bytes in (\d+) ns", f.read())
        if match is None or not samples:
            continue

        commands, elapsed_ns = map(int, match.groups())
        batch = payload // REQUEST_SIZE
        rows.append(
            [
                outstanding,
                batch,
                round(commands * batch / (elapsed_ns / 1000), 2),
                percentile(samples, 50) / 1000,
                percentile(samples, 1) / 1000,
                percentile(samples, 99) / 1000,
            ]
        )
    for row in sorted(rows):
        print(",".join(map(str, row)))


def failover(out):
    print("metric," + STATS_HEADER)
    for metric in ["total", "permissions"]:
        for path in sorted(glob.glob(os.path.join(out, "failover-%s-*.txt" % metric))):
            samples = read_samples(path)
            if samples:
                print(",".join(map(str, [metric] + stats_ns(samples))))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: summarize.py <latency|throughput|failover> <results-dir>")
    {"latency": latency, "throughput": throughput, "failover": failover}[sys.argv[1]](sys.argv[2])
