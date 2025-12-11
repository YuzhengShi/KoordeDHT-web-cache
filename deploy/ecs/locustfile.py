"""
Locust Throughput Test for Koorde/Chord DHT Web Cache.
Designed for distributed testing on AWS ECS.
"""

import os
import random
import time
import json
from datetime import datetime
from locust import HttpUser, task, between, events

# Configuration from environment
URL_POOL_SIZE = int(os.environ.get("URL_POOL_SIZE", "100"))
PROTOCOL_NAME = os.environ.get("PROTOCOL", "DHT").upper()

# Test URLs using httpbin.org
ENDPOINTS = [
    "/json",
    "/html",
    "/uuid",
    "/headers",
    "/bytes/1024",
    "/bytes/2048",
    "/status/200",
]

# Generate URL pool
url_pool = [f"https://httpbin.org{ENDPOINTS[i % len(ENDPOINTS)]}?id={i}" for i in range(URL_POOL_SIZE)]

# Zipf weights for realistic access pattern
def zipf_weights(n, alpha=1.2):
    weights = [1.0 / (i ** alpha) for i in range(1, n + 1)]
    total = sum(weights)
    return [w / total for w in weights]

WEIGHTS = zipf_weights(len(url_pool))


# Statistics tracking
class Stats:
    def __init__(self):
        self.reset()
    
    def reset(self):
        self.requests = 0
        self.hits = 0
        self.misses = 0
        self.errors = 0
        self.start_time = time.time()
    
    def record_hit(self):
        self.requests += 1
        self.hits += 1
    
    def record_miss(self):
        self.requests += 1
        self.misses += 1
    
    def record_error(self):
        self.requests += 1
        self.errors += 1
    
    @property
    def rps(self):
        elapsed = time.time() - self.start_time
        return self.requests / elapsed if elapsed > 0 else 0
    
    @property
    def hit_rate(self):
        total = self.hits + self.misses
        return (self.hits / total * 100) if total > 0 else 0

stats = Stats()


class ThroughputUser(HttpUser):
    """
    High-throughput user for RPS testing.
    Minimal wait time to maximize requests per second.
    """
    
    # ~10 requests/second per user
    wait_time = between(0.05, 0.15)
    
    def _get_url(self):
        """Select URL with Zipf distribution."""
        return random.choices(url_pool, weights=WEIGHTS, k=1)[0]
    
    @task
    def cache_request(self):
        """Make cache request and record result."""
        url = self._get_url()
        
        try:
            with self.client.get(
                f"/cache?url={url}",
                catch_response=True,
                name="/cache"
            ) as response:
                if response.status_code == 200:
                    cache_status = response.headers.get("X-Cache", "")
                    if "HIT" in cache_status.upper():
                        stats.record_hit()
                    else:
                        stats.record_miss()
                    response.success()
                else:
                    stats.record_error()
                    response.failure(f"HTTP {response.status_code}")
        except Exception:
            stats.record_error()


# Event handlers
@events.test_start.add_listener
def on_start(environment, **kwargs):
    stats.reset()
    print("\n" + "=" * 60)
    print(f" {PROTOCOL_NAME} THROUGHPUT TEST (ECS)")
    print("=" * 60)
    print(f" Target: {environment.host}")
    print(f" URL Pool: {URL_POOL_SIZE} URLs")
    print(f" Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60 + "\n")


@events.test_stop.add_listener
def on_stop(environment, **kwargs):
    elapsed = time.time() - stats.start_time
    
    result = {
        "protocol": PROTOCOL_NAME,
        "host": environment.host,
        "duration_sec": round(elapsed, 2),
        "total_requests": stats.requests,
        "throughput_rps": round(stats.rps, 2),
        "cache_hit_rate": round(stats.hit_rate, 2),
        "hits": stats.hits,
        "misses": stats.misses,
        "errors": stats.errors
    }
    
    print("\n" + "=" * 60)
    print(f" {PROTOCOL_NAME} THROUGHPUT RESULTS")
    print("=" * 60)
    print(f" Duration:     {result['duration_sec']} sec")
    print(f" Requests:     {result['total_requests']}")
    print(f" Throughput:   {result['throughput_rps']} RPS")
    print(f" Hit Rate:     {result['cache_hit_rate']}%")
    print(f" Errors:       {result['errors']}")
    print("=" * 60 + "\n")

