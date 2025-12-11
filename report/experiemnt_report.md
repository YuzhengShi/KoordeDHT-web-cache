## Experiment Report

### Table of contents

- [Experiment 2: Cache Hit Rate Under 3-Phase Node Churn (4 → 3 → 4)](#experiment-2-cache-hit-rate-under-3-phase-node-churn-4--3--4)

- [Experiment 3: Throughput Benchmark (Koorde vs Chord)](#experiment-3-throughput-benchmark-koorde-vs-chord)

---

## Experiment 2: Cache Hit Rate Under 3-Phase Node Churn (4 → 3 → 4)

### Experiment introduction

This experiment evaluates **cache hit rate** stability under **node churn** for three routing strategies:
**Simple Hash** (static modulo), **Chord**, and **Koorde** (consistent hashing).

### Experiment settings

| Parameter              | Value                                    |
| ---------------------- | ---------------------------------------- |
| **Node churn pattern** | 4 → 3 → 4 (remove 1 node, then add back) |
| **Unique URLs**        | 200                                      |
| **Requests per phase** | 300                                      |
| **Total requests**     | 900                                      |
| **Request rate**       | 50 req/s                                 |
| **Zipf alpha**         | 1.2                                      |
| **Koorde degree**      | 4                                        |

### Data (results)

### Final ranking (hit rate)

| Rank    | Protocol        | Avg Hit Rate | Failures | Key Redistribution | Verdict                    |
| ------- | --------------- | ------------ | -------- | ------------------ | -------------------------- |
| **1st** | **Chord**       | **38.2%**    | 0        | ~25%               | BEST - consistent hashing  |
| **2nd** | **Koorde**      | **35.3%**    | 0        | ~25%               | Great - consistent hashing |
| **3rd** | **Simple Hash** | **19.0%**    | 0        | ~75%               | WORST - key redistribution |

### Cache hit rate progression

![Hit Rate Comparison](hit_rate_comparison.png)

- **Chord** highest hit rate (consistent hashing preserves cache).
- **Koorde** close behind (consistent hashing preserves cache).
- **Simple Hash** lowest (major remapping on churn).

### Observed hit rate by phase

| Protocol    | Phase 1 | Phase 2 | Phase 3 | Explanation                                |
| ----------- | ------- | ------- | ------- | ------------------------------------------ |
| Simple Hash | 19.7%   | 16.3%   | 21.0%   | Lowest - ~75% cache invalidated each phase |
| Chord       | 33.3%   | 46.7%   | 34.7%   | Highest - ~75% cache preserved             |
| Koorde      | 31.7%   | 41.3%   | 33.0%   | Good - ~75% cache preserved                |

### Why Chord/Koorde improve in Phase 2 (short)

1. Cache already warmed in Phase 1
2. ~75% of cached data preserved (consistent hashing)
3. Fewer nodes (3) means each node handles more popular URLs
4. Popular URLs (Zipf distribution) are more likely to hit cache

### Conclusions

- **Chord**: best hit rate under churn (cache preserved via consistent hashing).
- **Koorde**: close to Chord; also preserves cache via consistent hashing.
- **Simple Hash**: lowest hit rate because `hash % N` remaps most keys when N changes.

### Recommendation

| Use Case                         | Recommended Protocol                              |
| -------------------------------- | ------------------------------------------------- |
| **Production web cache**         | **Chord** (best hit rate) or Koorde               |
| **Latency-critical systems**     | Koorde (slightly lower latency)                   |
| **Simple implementation needed** | Chord (simpler than Koorde)                       |
| **Static cluster, no churn**     | Simple Hash (acceptable)                          |
| **Dynamic cluster with churn**   | **Chord or Koorde** (consistent hashing required) |

### Key takeaway

> **Consistent hashing (Chord/Koorde) preserves ~75% of cached data during node changes, while simple modulo hashing invalidates ~75% of the cache.**

This is why Simple Hash has the **lowest hit rate** despite being functionally correct.

### Analysis

| Metric                     | Simple Hash | Chord     | Koorde |
| -------------------------- | ----------- | --------- | ------ |
| **Avg Hit Rate**           | 19.0%       | **38.2%** | 35.3%  |
| **Keys remapped on churn** | ~75%        | ~25%      | ~25%   |
| **Cache preserved**        | ~25%        | ~75%      | ~75%   |
| **P99 Latency (Phase 1)**  | 72.5ms      | 41.4ms    | 47.5ms |

- **Why Simple Hash is lowest**: when node count changes, `hash % N` changes for most keys (≈ 75% when \(N=4\)), so requests get routed to different nodes and miss previously warmed caches.
- **Why Chord/Koorde are higher**: consistent hashing moves only the affected key ranges (≈ 25% when \(N=4\)), preserving most cached entries across churn.

---

## Experiment 3: Throughput Benchmark (Koorde vs Chord)

### Summary

This experiment compares how Koorde and Chord scale under increasing concurrent load.

### Setup

- **Users tested**: 50, 100, 200, 500, 1000, 2000, 4000
- **Metric**: throughput (Requests Per Second, RPS)
- **Conditions**: Koorde and Chord run under identical conditions
- **Note**: X-axis is equally spaced for clarity and does not represent actual numeric spacing between user counts

### Key observations

- **Chord** achieves significantly higher throughput, saturating around ~3000 RPS.
- **Koorde** saturates earlier (~2200 RPS) and declines at high load (4000 users).
- **Chord** demonstrates better stability and scalability under high concurrency.
- **Koorde** shows more sensitivity to overload conditions.

### Chart

![Throughput Comparison](throughput.png)
