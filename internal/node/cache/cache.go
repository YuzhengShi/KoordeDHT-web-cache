package cache

import (
	"container/list"
	"fmt"
	"sync"
	"time"
)

// Entry represents a cached item with expiration and LRU tracking
type Entry struct {
	URL         string
	Content     []byte
	ContentType string
	StatusCode  int
	Expiration  time.Time
	Size        int
	CreatedAt   time.Time
	AccessCount int64
	element     *list.Element // Pointer for O(1) LRU operations
}

// WebCache is a thread-safe LRU cache with TTL expiration and capacity limits
type WebCache struct {
	capacityBytes int               // Maximum cache size in bytes
	entries       map[string]*Entry // Map for O(1) lookup
	lru           *list.List        // Doubly-linked list for LRU
	mu            sync.RWMutex      // Reader/writer lock
	currentBytes  int               // Current cache size in bytes

	// Metrics
	hits      int64
	misses    int64
	evictions int64
	stores    int64
}

// NewWebCache creates a new cache with the given capacity in megabytes
func NewWebCache(capacityMB int) *WebCache {
	return &WebCache{
		capacityBytes: capacityMB * 1024 * 1024,
		entries:       make(map[string]*Entry),
		lru:           list.New(),
		currentBytes:  0,
	}
}

// Get retrieves an entry from the cache
// Returns (entry, true) if found and not expired
// Returns (nil, false) if not found or expired
func (wc *WebCache) Get(url string) (*Entry, bool) {
	wc.mu.Lock()
	defer wc.mu.Unlock()

	entry, ok := wc.entries[url]
	if !ok {
		wc.misses++
		return nil, false
	}

	// Check expiration
	if time.Now().After(entry.Expiration) {
		// Expired, remove it
		wc.evictEntry(url)
		wc.misses++
		return nil, false
	}

	// Valid entry - move to front (most recently used)
	wc.lru.MoveToFront(entry.element)
	entry.AccessCount++
	wc.hits++

	return entry, true
}

// Put inserts or updates an entry in the cache
// If the cache is full, it evicts the least recently used entries
func (wc *WebCache) Put(url string, content []byte, contentType string, ttl time.Duration, statusCode int) error {
	wc.mu.Lock()
	defer wc.mu.Unlock()

	size := len(content)

	// Check if entry already exists (update case)
	if existing, ok := wc.entries[url]; ok {
		// Update existing entry
		wc.currentBytes -= existing.Size
		wc.currentBytes += size

		existing.Content = content
		existing.ContentType = contentType
		existing.StatusCode = statusCode
		existing.Expiration = time.Now().Add(ttl)
		existing.Size = size
		existing.AccessCount++

		// Move to front
		wc.lru.MoveToFront(existing.element)
		return nil
	}

	// New entry - check capacity
	if size > wc.capacityBytes {
		return fmt.Errorf("content size (%d bytes) exceeds cache capacity (%d bytes)", size, wc.capacityBytes)
	}

	// Evict LRU entries until we have space
	for wc.currentBytes+size > wc.capacityBytes && wc.lru.Len() > 0 {
		// Remove least recently used (back of list)
		oldest := wc.lru.Back()
		if oldest != nil {
			oldURL := oldest.Value.(string)
			wc.evictEntry(oldURL)
		}
	}

	// Insert new entry
	entry := &Entry{
		URL:         url,
		Content:     content,
		ContentType: contentType,
		StatusCode:  statusCode,
		Expiration:  time.Now().Add(ttl),
		Size:        size,
		CreatedAt:   time.Now(),
		AccessCount: 1,
	}

	// Add to front of LRU list
	entry.element = wc.lru.PushFront(url)
	wc.entries[url] = entry
	wc.currentBytes += size
	wc.stores++

	return nil
}

// evictEntry removes an entry from the cache (must be called with lock held)
func (wc *WebCache) evictEntry(url string) {
	entry, ok := wc.entries[url]
	if !ok {
		return
	}

	// Remove from LRU list
	if entry.element != nil {
		wc.lru.Remove(entry.element)
	}

	// Remove from map and update size
	delete(wc.entries, url)
	wc.currentBytes -= entry.Size
	wc.evictions++
}

// Delete removes a specific entry (for cache invalidation)
func (wc *WebCache) Delete(url string) bool {
	wc.mu.Lock()
	defer wc.mu.Unlock()

	if _, ok := wc.entries[url]; ok {
		wc.evictEntry(url)
		return true
	}
	return false
}

// CleanExpired removes all expired entries
// Should be called periodically (e.g., every hour)
func (wc *WebCache) CleanExpired() int {
	wc.mu.Lock()
	defer wc.mu.Unlock()

	now := time.Now()
	cleaned := 0

	// Collect expired URLs
	expired := make([]string, 0)
	for url, entry := range wc.entries {
		if now.After(entry.Expiration) {
			expired = append(expired, url)
		}
	}

	// Remove them
	for _, url := range expired {
		wc.evictEntry(url)
		cleaned++
	}

	return cleaned
}

// GetMetrics returns cache statistics
func (wc *WebCache) GetMetrics() CacheMetrics {
	wc.mu.RLock()
	defer wc.mu.RUnlock()

	total := wc.hits + wc.misses
	hitRate := 0.0
	if total > 0 {
		hitRate = float64(wc.hits) / float64(total)
	}

	return CacheMetrics{
		Hits:          wc.hits,
		Misses:        wc.misses,
		Evictions:     wc.evictions,
		Stores:        wc.stores,
		HitRate:       hitRate,
		EntryCount:    len(wc.entries),
		SizeBytes:     wc.currentBytes,
		CapacityBytes: wc.capacityBytes,
		Utilization:   float64(wc.currentBytes) / float64(wc.capacityBytes),
	}
}

// CacheMetrics contains cache performance statistics
type CacheMetrics struct {
	Hits          int64
	Misses        int64
	Evictions     int64
	Stores        int64
	HitRate       float64
	EntryCount    int
	SizeBytes     int
	CapacityBytes int
	Utilization   float64
}

// Clear removes all entries from the cache
func (wc *WebCache) Clear() {
	wc.mu.Lock()
	defer wc.mu.Unlock()

	wc.entries = make(map[string]*Entry)
	wc.lru = list.New()
	wc.currentBytes = 0
}

// Size returns the current number of entries
func (wc *WebCache) Size() int {
	wc.mu.RLock()
	defer wc.mu.RUnlock()
	return len(wc.entries)
}
