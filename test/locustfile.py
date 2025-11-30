"""
Locust load testing script for Koorde Web Cache.

This script tests the latency and performance of the Koorde distributed web cache
deployed on either LocalStack (local) or AWS (production).

Usage:
    # LocalStack deployment
    locust -f locustfile.py --host http://localhost:9000

    # AWS deployment
    locust -f locustfile.py --host http://<load-balancer-dns>

    # Headless mode with specific parameters
    locust -f locustfile.py --host http://localhost:9000 --users 50 --spawn-rate 5 --run-time 5m --headless
"""

import random
import time
from locust import HttpUser, task, between, events
from locust.runners import MasterRunner, WorkerRunner


# Test URLs - using httpbin.org for reliable testing
HTTPBIN_ENDPOINTS = [
    "/json",
    "/html",
    "/xml",
    "/robots.txt",
    "/deny",
    "/status/200",
    "/status/201",
    "/status/202",
    "/bytes/1024",
    "/bytes/2048",
    "/bytes/4096",
    "/base64/SFRUUEJJTiBpcyBhd2Vzb21l",
    "/uuid",
    "/user-agent",
    "/headers",
]

# Generate URL pool with Zipf distribution characteristics
# More URLs = better representation of real-world skewed access patterns
URL_POOL_SIZE = 300
url_pool = []

for i in range(URL_POOL_SIZE):
    endpoint = HTTPBIN_ENDPOINTS[i % len(HTTPBIN_ENDPOINTS)]
    # Add query parameter to make URLs unique
    url_pool.append(f"https://httpbin.org{endpoint}?id={i}")


class KoordeCacheUser(HttpUser):
    """
    Simulates a user accessing the Koorde web cache.
    
    Uses Zipf distribution to simulate realistic access patterns where
    some URLs are accessed much more frequently than others.
    """
    
    # Wait between 0.5 and 2 seconds between requests
    wait_time = between(0.5, 2)
    
    def on_start(self):
        """Called when a user starts. Initialize Zipf distribution."""
        # Zipf distribution: alpha=1.2 creates realistic skew
        # Higher alpha = more skewed (some URLs accessed much more)
        self.zipf_alpha = 1.2
        self.zipf_weights = self._generate_zipf_weights()
    
    def _generate_zipf_weights(self):
        """Generate Zipf distribution weights for URL selection."""
        weights = []
        for i in range(1, len(url_pool) + 1):
            weights.append(1.0 / (i ** self.zipf_alpha))
        
        # Normalize weights
        total = sum(weights)
        return [w / total for w in weights]
    
    def _select_url_zipf(self):
        """Select a URL using Zipf distribution."""
        return random.choices(url_pool, weights=self.zipf_weights, k=1)[0]
    
    @task(10)
    def cache_request_zipf(self):
        """
        Make a cache request using Zipf distribution (most common pattern).
        Weight: 10 (90% of requests)
        """
        url = self._select_url_zipf()
        with self.client.get(
            f"/cache?url={url}",
            catch_response=True,
            name="/cache [Zipf]"
        ) as response:
            if response.status_code == 200:
                # Extract custom headers for analysis
                cache_status = response.headers.get("X-Cache", "UNKNOWN")
                latency = response.headers.get("X-Latency-Ms", "0")
                node_id = response.headers.get("X-Node-Id", "UNKNOWN")
                
                # Log cache hit/miss for analysis
                if "HIT" in cache_status:
                    response.success()
                elif "MISS" in cache_status:
                    response.success()
                else:
                    response.failure(f"Unexpected cache status: {cache_status}")
            else:
                response.failure(f"Got status code {response.status_code}")
    
    @task(1)
    def cache_request_random(self):
        """
        Make a random cache request (cold cache simulation).
        Weight: 1 (10% of requests)
        """
        url = random.choice(url_pool)
        with self.client.get(
            f"/cache?url={url}",
            catch_response=True,
            name="/cache [Random]"
        ) as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"Got status code {response.status_code}")
    
    @task(1)
    def health_check(self):
        """
        Periodic health check.
        Weight: 1 (occasional)
        """
        with self.client.get("/health", catch_response=True, name="/health") as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"Health check failed: {response.status_code}")
    
    @task(1)
    def metrics_check(self):
        """
        Periodic metrics check.
        Weight: 1 (occasional)
        """
        with self.client.get("/metrics", catch_response=True, name="/metrics") as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"Metrics check failed: {response.status_code}")


# Custom statistics tracking
total_latency = 0.0
request_count = 0


@events.request.add_listener
def on_request(request_type, name, response_time, response_length, exception, context, **kwargs):
    """Track custom metrics from response headers."""
    global total_latency, request_count
    
    if exception is None and hasattr(context, 'headers'):
        try:
            latency_ms = float(context.headers.get("X-Latency-Ms", "0"))
            total_latency += latency_ms
            request_count += 1
        except ValueError:
            pass


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    """Print summary statistics when test stops."""
    print("\n" + "="*60)
    print("KOORDE CACHE LATENCY TEST SUMMARY")
    print("="*60)
    
    if request_count > 0:
        avg_latency = total_latency / request_count if request_count > 0 else 0
        
        print(f"Total Requests: {request_count}")
        print(f"Average Latency: {avg_latency:.2f} ms")
    else:
        print("No requests completed")
    
    print("="*60 + "\n")
