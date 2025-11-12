package cache

import (
	"math"
	"sync"
	"time"
)

// HotspotDetector tracks request frequencies using exponential decay
// to identify "hot" URLs that should be distributed across the cluster
type HotspotDetector struct {
	threshold float64 // Requests/second threshold for hotspot classification
	decayRate float64 // Exponential decay factor γ (typically 0.6-0.8)

	entries map[string]*HotspotEntry
	mu      sync.RWMutex
}

// HotspotEntry tracks the decayed average request rate for a URL
type HotspotEntry struct {
	Average         float64 // Exponentially decayed average: H_t = γ·H_{t-1} + N_t
	LastRequestTime int64   // Unix timestamp of last request (seconds)
	TotalRequests   int64   // Total requests seen (for debugging)
}

// NewHotspotDetector creates a new detector with the given parameters
//
// Recommended values:
//   - threshold: 1000 (URLs with >1000 req/sec are considered hot)
//   - decayRate: 0.65 (balances responsiveness vs. stability)
func NewHotspotDetector(threshold, decayRate float64) *HotspotDetector {
	return &HotspotDetector{
		threshold: threshold,
		decayRate: decayRate,
		entries:   make(map[string]*HotspotEntry),
	}
}

// RecordAccess records a request for the given URL and updates its hotness score
//
// Returns true if the URL is now classified as "hot" (above threshold)
//
// Algorithm: Exponential Moving Average
//   If same second:    H_t = H_{t-1} + 1
//   If different second: H_t = γ^Δt · H_{t-1} + 1
//   where Δt = seconds since last request
func (hd *HotspotDetector) RecordAccess(url string) bool {
	hd.mu.Lock()
	defer hd.mu.Unlock()

	now := time.Now().Unix()

	entry, exists := hd.entries[url]
	if !exists {
		// First request for this URL
		hd.entries[url] = &HotspotEntry{
			Average:         1.0,
			LastRequestTime: now,
			TotalRequests:   1,
		}
		return false // Can't be hot on first request
	}

	entry.TotalRequests++

	if entry.LastRequestTime == now {
		// Same second - just increment
		entry.Average += 1.0
	} else {
		// Different second - apply exponential decay
		secondsElapsed := float64(now - entry.LastRequestTime)
		decayFactor := math.Pow(hd.decayRate, secondsElapsed)
		entry.Average = entry.Average*decayFactor + 1.0
		entry.LastRequestTime = now
	}

	// Check if now hot
	isHot := entry.Average >= hd.threshold
	return isHot
}

// IsHot checks if a URL is currently classified as hot
func (hd *HotspotDetector) IsHot(url string) bool {
	hd.mu.RLock()
	defer hd.mu.RUnlock()

	entry, exists := hd.entries[url]
	if !exists {
		return false
	}

	// Apply decay based on time since last access
	now := time.Now().Unix()
	secondsElapsed := float64(now - entry.LastRequestTime)
	decayedAverage := entry.Average * math.Pow(hd.decayRate, secondsElapsed)

	return decayedAverage >= hd.threshold
}

// GetHotURLs returns a list of currently hot URLs
func (hd *HotspotDetector) GetHotURLs() []string {
	hd.mu.RLock()
	defer hd.mu.RUnlock()

	now := time.Now().Unix()
	hotURLs := make([]string, 0)

	for url, entry := range hd.entries {
		secondsElapsed := float64(now - entry.LastRequestTime)
		decayedAverage := entry.Average * math.Pow(hd.decayRate, secondsElapsed)

		if decayedAverage >= hd.threshold {
			hotURLs = append(hotURLs, url)
		}
	}

	return hotURLs
}

// GetStats returns statistics for a specific URL
func (hd *HotspotDetector) GetStats(url string) (average float64, total int64, isHot bool) {
	hd.mu.RLock()
	defer hd.mu.RUnlock()

	entry, exists := hd.entries[url]
	if !exists {
		return 0, 0, false
	}

	// Apply decay
	now := time.Now().Unix()
	secondsElapsed := float64(now - entry.LastRequestTime)
	decayedAverage := entry.Average * math.Pow(hd.decayRate, secondsElapsed)

	return decayedAverage, entry.TotalRequests, decayedAverage >= hd.threshold
}

// Clear removes all tracked URLs
func (hd *HotspotDetector) Clear() {
	hd.mu.Lock()
	defer hd.mu.Unlock()
	hd.entries = make(map[string]*HotspotEntry)
}

// CleanStale removes entries that haven't been accessed recently
// Called periodically to prevent unbounded memory growth
func (hd *HotspotDetector) CleanStale(maxAge time.Duration) int {
	hd.mu.Lock()
	defer hd.mu.Unlock()

	now := time.Now().Unix()
	cleaned := 0
	staleURLs := make([]string, 0)

	for url, entry := range hd.entries {
		age := now - entry.LastRequestTime
		if time.Duration(age)*time.Second > maxAge {
			staleURLs = append(staleURLs, url)
		}
	}

	for _, url := range staleURLs {
		delete(hd.entries, url)
		cleaned++
	}

	return cleaned
}