package main

import (
	"flag"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

type Metrics struct {
	total   int64
	success int64
	failed  int64
	hits    int64
	misses  int64
	latency int64 // nanoseconds
}

func main() {
	target := flag.String("target", "http://localhost:8080", "Target node")
	numURLs := flag.Int("urls", 100, "Number of unique URLs")
	requests := flag.Int("requests", 1000, "Total requests")
	rate := flag.Float64("rate", 50, "Requests per second")
	zipf := flag.Float64("zipf", 1.2, "Zipf alpha (must be > 1.0)")
	output := flag.String("output", "results.csv", "Output file")

	flag.Parse()

	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Printf("Koorde Cache Workload Generator\n")
	fmt.Printf("Target: %s\n", *target)
	fmt.Printf("URLs: %d\n", *numURLs)
	fmt.Printf("Requests: %d\n", *requests)
	fmt.Printf("Rate: %.2f req/sec\n", *rate)
	fmt.Printf("Zipf: %.2f\n", *zipf)
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	// Validate parameters
	if *numURLs < 2 {
		fmt.Printf("Error: --urls must be >= 2 (got %d)\n", *numURLs)
		os.Exit(1)
	}
	// Go's rand.NewZipf requires exponent (alpha) > 1
	if *zipf <= 1.0 {
		fmt.Printf("Error: --zipf must be > 1.0 (got %.2f)\n", *zipf)
		fmt.Println("Hint: For web cache workloads, try --zipf between 1.1 and 2.0")
		fmt.Println("      (higher values = more skewed distribution = more realistic)")
		os.Exit(1)
	}

	// Generate URLs (use real, accessible URLs for testing)
	// Options: httpbin.org (fast, reliable), example.com (simple), or custom
	urls := make([]string, *numURLs)
	
	// Use httpbin.org endpoints which are designed for testing
	httpbinEndpoints := []string{
		"/json", "/html", "/xml", "/robots.txt", "/deny",
		"/status/200", "/status/201", "/status/202", "/status/204",
		"/bytes/1024", "/bytes/2048", "/bytes/4096",
		"/base64/SFRUUEJJTiBpcyBhd2Vzb21l", "/base64/VGVzdCBtZXNzYWdl",
		"/delay/1", "/delay/2",
	}
	
	for i := 0; i < *numURLs; i++ {
		// Cycle through httpbin endpoints for variety
		endpoint := httpbinEndpoints[i%len(httpbinEndpoints)]
		urls[i] = fmt.Sprintf("https://httpbin.org%s", endpoint)
	}

	// Create Zipf distribution
	// Parameters: rng, exponent (alpha), q, imax
	// - exponent (alpha) must be > 1.0 (Go requirement)
	// - q must be > 1.0 (we use 1.5)
	// - imax must be >= 1 (we use numURLs-1)
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	zipfGen := rand.NewZipf(rng, *zipf, 1.5, uint64(*numURLs-1))
	if zipfGen == nil {
		fmt.Printf("Error: Failed to create Zipf distribution (alpha=%.2f, q=1.5, imax=%d)\n",
			*zipf, *numURLs-1)
		fmt.Println("This should not happen if validation passed. Please report this bug.")
		os.Exit(1)
	}

	// Open output
	file, err := os.Create(*output)
	if err != nil {
		fmt.Printf("Error creating file: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	file.WriteString("timestamp,url_id,latency_ms,status,cache_status,node_id\n")

	var metrics Metrics
	var mu sync.Mutex

	// Generate workload
	interval := time.Duration(float64(time.Second) / *rate)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	start := time.Now()

	for i := 0; i < *requests; i++ {
		<-ticker.C

		idx := zipfGen.Uint64()
		// Ensure index is within bounds (should always be, but safety check)
		if idx >= uint64(len(urls)) {
			idx = idx % uint64(len(urls))
		}
		url := urls[idx]

		go func(urlID uint64, url string) {
			reqStart := time.Now()

			fullURL := fmt.Sprintf("%s/cache?url=%s", *target, url)
			resp, err := http.Get(fullURL)

			latency := time.Since(reqStart)
			atomic.AddInt64(&metrics.total, 1)
			atomic.AddInt64(&metrics.latency, latency.Nanoseconds())

			if err != nil {
				atomic.AddInt64(&metrics.failed, 1)
				return
			}
			defer resp.Body.Close()

			atomic.AddInt64(&metrics.success, 1)

			cacheStatus := resp.Header.Get("X-Cache")
			nodeID := resp.Header.Get("X-Node-ID")

			if cacheStatus == "HIT-LOCAL" {
				atomic.AddInt64(&metrics.hits, 1)
			} else {
				atomic.AddInt64(&metrics.misses, 1)
			}

			mu.Lock()
			fmt.Fprintf(file, "%s,%d,%.2f,%d,%s,%s\n",
				time.Now().Format(time.RFC3339),
				urlID,
				float64(latency.Microseconds())/1000.0,
				resp.StatusCode,
				cacheStatus,
				nodeID,
			)
			mu.Unlock()
		}(idx, url)

		if (i+1)%100 == 0 {
			fmt.Printf("Progress: %d/%d (%.1f%%)\n",
				i+1, *requests, float64(i+1)/float64(*requests)*100)
		}
	}

	// Wait a bit for last requests
	time.Sleep(5 * time.Second)

	// Print summary
	total := atomic.LoadInt64(&metrics.total)
	success := atomic.LoadInt64(&metrics.success)
	hits := atomic.LoadInt64(&metrics.hits)
	misses := atomic.LoadInt64(&metrics.misses)
	avgLatency := float64(atomic.LoadInt64(&metrics.latency)) / float64(success) / 1e6

	fmt.Println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Println("Summary:")
	fmt.Printf("  Total: %d\n", total)
	fmt.Printf("  Success: %d (%.1f%%)\n", success, float64(success)/float64(total)*100)
	fmt.Printf("  Avg Latency: %.2f ms\n", avgLatency)
	fmt.Printf("  Cache Hits: %d\n", hits)
	fmt.Printf("  Cache Misses: %d\n", misses)
	fmt.Printf("  Hit Rate: %.1f%%\n", float64(hits)/float64(hits+misses)*100)
	fmt.Printf("  Duration: %s\n", time.Since(start).Round(time.Second))
	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Printf("\nResults saved to: %s\n", *output)
}