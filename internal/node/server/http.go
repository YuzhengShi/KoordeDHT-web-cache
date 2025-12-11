package server

import (
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	"KoordeDHT/internal/node/cache"
	"KoordeDHT/internal/node/dht"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"strconv"
	"time"
)

const (
	originCacheTTL = time.Hour
	nearCacheTTL   = 5 * time.Minute
)

// HTTPCacheServer provides HTTP endpoints for web caching functionality
type HTTPCacheServer struct {
	node                 dht.DHTNode
	cache                *cache.WebCache
	hotspotDetector      *cache.HotspotDetector
	port                 int
	server               *http.Server
	lgr                  logger.Logger
	grpcToHTTPPortOffset int
}

// NewHTTPCacheServer creates a new HTTP cache server instance
func NewHTTPCacheServer(
	node dht.DHTNode,
	webCache *cache.WebCache,
	hotspotDetector *cache.HotspotDetector,
	port int,
	lgr logger.Logger,
) *HTTPCacheServer {
	offset := 4080 // default offset used by legacy configs
	if self := node.Self(); self != nil {
		if _, portStr, err := net.SplitHostPort(self.Addr); err == nil {
			if grpcPort, parseErr := strconv.Atoi(portStr); parseErr == nil {
				offset = port - grpcPort
			} else {
				lgr.Warn("NewHTTPCacheServer: failed to parse self gRPC port, falling back to default offset",
					logger.F("self_addr", self.Addr), logger.F("err", parseErr))
			}
		} else {
			lgr.Warn("NewHTTPCacheServer: failed to split self address, falling back to default offset",
				logger.F("self_addr", self.Addr), logger.F("err", err))
		}
	}

	return &HTTPCacheServer{
		node:                 node,
		cache:                webCache,
		hotspotDetector:      hotspotDetector,
		port:                 port,
		lgr:                  lgr,
		grpcToHTTPPortOffset: offset,
	}
}

// Start launches the HTTP server and blocks until stopped
func (s *HTTPCacheServer) Start() error {
	mux := http.NewServeMux()

	// Main cache endpoint
	mux.HandleFunc("/cache", s.handleCacheRequest)

	// Metrics endpoint
	mux.HandleFunc("/metrics", s.handleMetrics)

	// Health check
	mux.HandleFunc("/health", s.handleHealth)

	// Debug endpoint (routing table info)
	mux.HandleFunc("/debug", s.handleDebug)

	// Cluster membership update endpoints (simple hash only)
	mux.HandleFunc("/cluster/remove", s.handleClusterRemove)
	mux.HandleFunc("/cluster/add", s.handleClusterAdd)

	addr := fmt.Sprintf(":%d", s.port)
	s.server = &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	s.lgr.Info("HTTP cache server starting", logger.F("addr", addr))
	return s.server.ListenAndServe()
}

// Stop gracefully shuts down the HTTP server
func (s *HTTPCacheServer) Stop(ctx context.Context) error {
	if s.server != nil {
		return s.server.Shutdown(ctx)
	}
	return nil
}

// handleCacheRequest processes cache requests for URLs
//
// Request flow:
//  1. Check local cache (fast path)
//  2. Check if URL is hot (hotspot detection)
//  3. If hot: randomly distribute to any node
//  4. If normal: DHT lookup to find responsible node
//  5. If self is responsible: fetch from origin and cache
//  6. If other node responsible: proxy HTTP request
func (s *HTTPCacheServer) handleCacheRequest(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	url := r.URL.Query().Get("url")
	if url == "" {
		http.Error(w, "missing 'url' query parameter", http.StatusBadRequest)
		return
	}

	// Check if this is a forwarded request (optimization to avoid double lookup)
	isResponsible := r.Header.Get("X-Is-Responsible") == "true"
	fromNode := r.Header.Get("X-Forwarded-From")

	if fromNode != "" {
		s.lgr.Debug("Received forwarded request",
			logger.F("url", url),
			logger.F("from", fromNode),
			logger.F("is_responsible", isResponsible))
	}

	// STEP 1: Compute URL hash (needed to determine responsible node)
	urlHash := s.node.Space().NewIdFromString(url)

	s.lgr.Debug("Computed URL hash",
		logger.F("url", url),
		logger.F("hash", urlHash.ToHexString(true)))

	selfNode := s.node.Self()
	if selfNode == nil {
		s.lgr.Error("handleCacheRequest: self node is nil")
		http.Error(w, "node not initialized", http.StatusInternalServerError)
		return
	}

	// STEP 2: DHT Lookup (find responsible node)
	var responsible *domain.Node
	if !isResponsible {
		// Only do lookup if we haven't been told we're responsible
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		var err error
		responsible, err = s.node.LookUp(ctx, urlHash)
		if err != nil {
			s.lgr.Warn("DHT lookup failed, trying fallback strategies",
				logger.F("url", url),
				logger.F("hash", urlHash.ToHexString(true)),
				logger.F("err", err))
			// Don't return error immediately - try fallback strategies below
			responsible = nil
		}

		if responsible == nil {
			s.lgr.Debug("DHT lookup returned nil, will use fallback strategies",
				logger.F("url", url),
				logger.F("hash", urlHash.ToHexString(true)))
			// Don't return error - continue to ownership check and fallback logic
		}

		s.lgr.Info("DHT lookup complete",
			logger.F("url", url),
			logger.F("hash", urlHash.ToHexString(true)),
			logger.FNode("responsible", responsible),
			logger.F("lookup_latency_ms", time.Since(start).Milliseconds()))
	} else {
		// We've been told we're responsible (forwarded request)
		responsible = selfNode
	}

	// STEP 3: Determine if we own the key
	// Use protocol-specific ownership check to avoid forwarding loops
	ownsKey := false

	// Check if this is a Simple Hash node (has IsResponsibleFor method)
	type simpleHashOwner interface {
		IsResponsibleFor(domain.ID) bool
	}
	if simpleNode, ok := s.node.(simpleHashOwner); ok {
		// Simple Hash: use modulo-based ownership (hash % N == self.index)
		ownsKey = simpleNode.IsResponsibleFor(urlHash)
		s.lgr.Debug("Ownership check (simple hash modulo)",
			logger.F("url", url),
			logger.F("hash", urlHash.ToHexString(true)),
			logger.F("owns_key", ownsKey))
	} else if pred := s.node.Predecessor(); pred != nil {
		// Chord/Koorde: use ring-based ownership (pred, self]
		ownsKey = urlHash.Between(pred.ID, selfNode.ID)
		s.lgr.Debug("Ownership check (pred, self]",
			logger.F("url", url),
			logger.F("hash", urlHash.ToHexString(true)),
			logger.FNode("pred", pred),
			logger.FNode("self", selfNode),
			logger.F("owns_key", ownsKey),
			logger.F("forwarded_header_isResponsible", isResponsible))
	} else {
		// No predecessor yet -> check if lookup returned self
		// If DHT lookup says we're responsible, we should own it
		// (This handles the case where stabilization hasn't completed yet)
		if responsible != nil && responsible.ID.Equal(selfNode.ID) {
			ownsKey = true
			s.lgr.Debug("Ownership check (no predecessor, but lookup returned self)",
				logger.F("url", url),
				logger.F("hash", urlHash.ToHexString(true)),
				logger.F("owns_key", ownsKey))
		} else if len(s.node.SuccessorList()) <= 1 {
			// Single-node scenario - we own everything
			ownsKey = true
		}
	}

	// STEP 4: If we do not own the key, forward it (even if lookup returned self)
	if !ownsKey {
		// FORCE SKIP NEAR CACHE for pure DHT testing
		if false { // if entry, ok := s.cache.Get(url); ok {
			/*
				s.lgr.Info("Cache HIT (near)",
					logger.F("url", url),
					logger.F("size_bytes", entry.Size),
					logger.F("latency_ms", time.Since(start).Milliseconds()))

				statusCode := entry.StatusCode
				if statusCode < 100 {
					statusCode = http.StatusOK
				}

				w.Header().Set("Content-Type", entry.ContentType)
				w.Header().Set("X-Cache", "HIT-NEAR")
				w.Header().Set("X-Entry-Node", s.node.Self().Addr)
				w.Header().Set("X-Latency-Ms", fmt.Sprintf("%.2f", time.Since(start).Seconds()*1000))
				w.WriteHeader(statusCode)
				w.Write(entry.Content)
				return
			*/
		}

		targetNode := responsible

		// Protocol-specific fallback strategies
		// Only use fallbacks that match the DHT protocol being used
		isKoorde := len(s.node.DeBruijnList()) > 0
		isChord := false
		if _, ok := s.node.(interface{ FingerList() []*domain.Node }); ok {
			isChord = true
		}

		// If lookup returned nil or self, try protocol-specific fallbacks
		if targetNode == nil || targetNode.ID.Equal(selfNode.ID) {
			if isKoorde {
				// Koorde-specific: Only use de Bruijn neighbors (not successor list - that's Chord-like)
				s.lgr.Debug("Koorde lookup failed, trying de Bruijn neighbors",
					logger.F("url", url),
					logger.F("hash", urlHash.ToHexString(true)),
					logger.F("debruijn_count", len(s.node.DeBruijnList())))

				for _, db := range s.node.DeBruijnList() {
					if db != nil && !db.ID.Equal(selfNode.ID) {
						targetNode = db
						s.lgr.Info("Using de Bruijn neighbor as Koorde fallback",
							logger.F("url", url),
							logger.FNode("target", targetNode))
						break
					}
				}

				// Retry lookup with longer timeout (still Koorde routing)
				if targetNode == nil || targetNode.ID.Equal(selfNode.ID) {
					s.lgr.Warn("Koorde de Bruijn fallback failed, retrying lookup with longer timeout",
						logger.F("url", url),
						logger.F("hash", urlHash.ToHexString(true)))

					ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
					defer cancel()

					retryResponsible, retryErr := s.node.LookUp(ctx, urlHash)
					if retryErr == nil && retryResponsible != nil && !retryResponsible.ID.Equal(selfNode.ID) {
						targetNode = retryResponsible
						s.lgr.Info("Koorde retry lookup succeeded",
							logger.F("url", url),
							logger.FNode("target", targetNode))
					}
				}
			} else if isChord {
				// Chord-specific: Use finger table or successor list
				s.lgr.Debug("Chord lookup failed, trying finger table and successor list",
					logger.F("url", url),
					logger.F("hash", urlHash.ToHexString(true)))

				// Try finger table first
				if chordNode, ok := s.node.(interface{ FingerList() []*domain.Node }); ok {
					for _, finger := range chordNode.FingerList() {
						if finger != nil && !finger.ID.Equal(selfNode.ID) {
							targetNode = finger
							s.lgr.Info("Using finger table entry as Chord fallback",
								logger.F("url", url),
								logger.FNode("target", targetNode))
							break
						}
					}
				}

				// Fallback to successor list
				if targetNode == nil || targetNode.ID.Equal(selfNode.ID) {
					for _, succ := range s.node.SuccessorList() {
						if succ != nil && !succ.ID.Equal(selfNode.ID) {
							targetNode = succ
							s.lgr.Info("Using successor as Chord fallback",
								logger.F("url", url),
								logger.FNode("target", targetNode))
							break
						}
					}
				}
			} else {
				// Unknown protocol - try generic fallback
				s.lgr.Warn("Unknown DHT protocol, trying generic fallbacks",
					logger.F("url", url),
					logger.F("hash", urlHash.ToHexString(true)))

				// Try successor list as last resort
				for _, succ := range s.node.SuccessorList() {
					if succ != nil && !succ.ID.Equal(selfNode.ID) {
						targetNode = succ
						break
					}
				}
			}
		}

		// Final check: Fail fast if no valid target found (don't assume ownership)
		// This ensures we know when routing fails rather than silently degrading
		if targetNode == nil || targetNode.ID.Equal(selfNode.ID) {
			protocolName := "Unknown"
			if isKoorde {
				protocolName = "Koorde"
			} else if isChord {
				protocolName = "Chord"
			}

			s.lgr.Error("Routing failed: no valid target node found",
				logger.F("url", url),
				logger.F("hash", urlHash.ToHexString(true)),
				logger.F("protocol", protocolName),
				logger.F("lookup_returned", responsible != nil),
				logger.F("debruijn_count", len(s.node.DeBruijnList())),
				logger.F("successor_count", len(s.node.SuccessorList())))

			http.Error(w, fmt.Sprintf("%s routing failed: no responsible node available for key", protocolName), http.StatusServiceUnavailable)
			return
		}

		s.lgr.Info("Forwarding to responsible node",
			logger.F("url", url),
			logger.F("hash", urlHash.ToHexString(true)),
			logger.FNode("responsible_from_lookup", responsible),
			logger.FNode("forward_target", targetNode))

		s.proxyToNode(w, r, url, targetNode.Addr, "MISS-DHT", start)
		return
	}

	// STEP 5: We ARE the responsible node - check local cache first
	if entry, ok := s.cache.Get(url); ok {
		s.lgr.Info("Cache HIT (local)",
			logger.F("url", url),
			logger.F("size_bytes", entry.Size),
			logger.F("latency_ms", time.Since(start).Milliseconds()))

		statusCode := entry.StatusCode
		if statusCode < 100 {
			statusCode = http.StatusOK
		}

		w.Header().Set("Content-Type", entry.ContentType)
		w.Header().Set("X-Cache", "HIT-LOCAL")
		w.Header().Set("X-Node-ID", s.node.Self().ID.ToHexString(true))
		w.Header().Set("X-Latency-Ms", fmt.Sprintf("%.2f", time.Since(start).Seconds()*1000))
		w.WriteHeader(statusCode)
		w.Write(entry.Content)
		return
	}

	// STEP 6: Hotspot detection (only for responsible node)
	isHot := s.hotspotDetector.RecordAccess(url)

	if isHot {
		// Hotspot detected - use random distribution strategy
		avg, total, _ := s.hotspotDetector.GetStats(url)
		s.lgr.Info("Hotspot detected, using random distribution",
			logger.F("url", url),
			logger.F("avg_rate", fmt.Sprintf("%.2f", avg)),
			logger.F("total_requests", total))

		randomNode := s.pickRandomNode()
		if randomNode != "" && randomNode != s.node.Self().Addr {
			s.proxyToNode(w, r, url, randomNode, "MISS-HOT", start)
			return
		}
		// Fall through to fetch from origin if no other node available
	}

	// STEP 7: We ARE the responsible node - fetch from origin
	s.lgr.Info("I am responsible, fetching from origin",
		logger.F("url", url))

	content, contentType, statusCode, err := s.fetchFromOrigin(url)
	if err != nil {
		s.lgr.Error("Origin fetch failed",
			logger.F("url", url),
			logger.F("err", err))
		http.Error(w, fmt.Sprintf("failed to fetch from origin: %v", err), http.StatusBadGateway)
		return
	}

	// STEP 7: Cache the content locally
	if err := s.cache.Put(url, content, contentType, originCacheTTL, statusCode); err != nil {
		s.lgr.Warn("Failed to cache content",
			logger.F("url", url),
			logger.F("size", len(content)),
			logger.F("err", err))
		// Continue anyway - we can still serve the content
	} else {
		s.lgr.Info("Content cached successfully",
			logger.F("url", url),
			logger.F("size_bytes", len(content)))
	}

	// STEP 8: Return content to client
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Cache", "MISS-ORIGIN")
	w.Header().Set("X-Node-ID", s.node.Self().ID.ToHexString(true))
	w.Header().Set("X-Latency-Ms", fmt.Sprintf("%.2f", time.Since(start).Seconds()*1000))
	w.WriteHeader(statusCode)
	w.Write(content)

	s.lgr.Info("Request completed",
		logger.F("url", url),
		logger.F("total_latency_ms", time.Since(start).Milliseconds()),
		logger.F("content_size", len(content)))
}

// pickRandomNode selects a random node from the cluster
// Uses successor list + de Bruijn list (Koorde) or finger table (Chord) as source of known nodes
func (s *HTTPCacheServer) pickRandomNode() string {
	// Collect all known nodes
	allNodes := make(map[string]bool)

	// Add successors (both Chord and Koorde)
	for _, succ := range s.node.SuccessorList() {
		if succ != nil {
			allNodes[succ.Addr] = true
		}
	}

	// Add de Bruijn neighbors (Koorde only - returns nil for Chord)
	deBruijnList := s.node.DeBruijnList()
	for _, db := range deBruijnList {
		if db != nil {
			allNodes[db.Addr] = true
		}
	}

	// For Chord: also use finger table entries
	// Check if this is Chord (no de Bruijn list) and try to get finger table
	if len(deBruijnList) == 0 {
		// Likely Chord - try to get finger table if available
		// Use type assertion to check if node has FingerList method
		if chordNode, ok := s.node.(interface{ FingerList() []*domain.Node }); ok {
			for _, finger := range chordNode.FingerList() {
				if finger != nil {
					allNodes[finger.Addr] = true
				}
			}
		}
	}

	// Add predecessor
	if pred := s.node.Predecessor(); pred != nil {
		allNodes[pred.Addr] = true
	}

	// Convert to slice
	nodes := make([]string, 0, len(allNodes))
	for addr := range allNodes {
		// Don't include self
		if addr != s.node.Self().Addr {
			nodes = append(nodes, addr)
		}
	}

	if len(nodes) == 0 {
		// Fallback to self if no other nodes known
		s.lgr.Warn("No other nodes known, using self for random selection")
		return s.node.Self().Addr
	}

	// Random selection
	return nodes[rand.Intn(len(nodes))]
}

// proxyToNode forwards the request to another node via HTTP
func (s *HTTPCacheServer) proxyToNode(
	w http.ResponseWriter,
	r *http.Request,
	url string,
	nodeAddr string, // e.g., "10.0.1.89:4000" (gRPC addr)
	cacheStatus string,
	start time.Time,
) {
	// Extract host and gRPC port from "host:port" (gRPC address format)
	host, portStr, err := net.SplitHostPort(nodeAddr)
	if err != nil {
		// nodeAddr might already be just "host" - can't determine HTTP port
		s.lgr.Error("Proxy failed: cannot parse node address",
			logger.F("node_addr", nodeAddr),
			logger.F("err", err))
		http.Error(w, fmt.Sprintf("invalid node address: %s", nodeAddr), http.StatusInternalServerError)
		return
	}

	// Parse gRPC port
	var grpcPort int
	_, err = fmt.Sscanf(portStr, "%d", &grpcPort)
	if err != nil {
		s.lgr.Error("Proxy failed: cannot parse gRPC port",
			logger.F("node_addr", nodeAddr),
			logger.F("port_str", portStr),
			logger.F("err", err))
		http.Error(w, fmt.Sprintf("invalid gRPC port: %s", portStr), http.StatusInternalServerError)
		return
	}

	// Calculate HTTP port using the configured offset (derived from this node)
	httpPort := grpcPort + s.grpcToHTTPPortOffset

	// Construct HTTP URL (using calculated HTTP port, not self's port)
	proxyURL := fmt.Sprintf("http://%s:%d/cache?url=%s", host, httpPort, url)

	s.lgr.Debug("Proxying request",
		logger.F("url", url),
		logger.F("proxy_url", proxyURL),
		logger.F("target_node", nodeAddr))

	// Create request with forwarding headers
	req, err := http.NewRequestWithContext(r.Context(), "GET", proxyURL, nil)
	if err != nil {
		s.lgr.Error("Failed to create proxy request",
			logger.F("proxy_url", proxyURL),
			logger.F("err", err))
		http.Error(w, "proxy request creation failed", http.StatusInternalServerError)
		return
	}

	// Add headers to prevent loops and enable optimizations
	req.Header.Set("X-Forwarded-From", s.node.Self().Addr)
	req.Header.Set("X-Is-Responsible", "true") // Tell target it's responsible
	req.Header.Set("X-Original-Request-Time", start.Format(time.RFC3339Nano))

	// Send request
	client := &http.Client{
		Timeout: 10 * time.Second,
	}

	resp, err := client.Do(req)
	if err != nil {
		s.lgr.Error("Proxy request failed",
			logger.F("proxy_url", proxyURL),
			logger.F("err", err))
		http.Error(w, fmt.Sprintf("proxy failed: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Read response
	content, err := io.ReadAll(resp.Body)
	if err != nil {
		s.lgr.Error("Failed to read proxy response",
			logger.F("proxy_url", proxyURL),
			logger.F("err", err))
		http.Error(w, "failed to read proxy response", http.StatusInternalServerError)
		return
	}

	// Determine content type once for headers and optional caching
	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	// Opportunistically cache successful proxy responses locally so future
	// requests avoid another remote hop.
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		if err := s.cache.Put(url, content, contentType, nearCacheTTL, resp.StatusCode); err != nil {
			s.lgr.Warn("Failed to cache proxied content",
				logger.F("url", url),
				logger.F("size", len(content)),
				logger.F("err", err))
		} else {
			s.lgr.Debug("Cached proxied content locally",
				logger.F("url", url),
				logger.F("size_bytes", len(content)))
		}
	}

	// Forward response to client
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Cache", cacheStatus)
	w.Header().Set("X-Responsible-Node", nodeAddr)
	w.Header().Set("X-Entry-Node", s.node.Self().Addr)
	w.Header().Set("X-Latency-Ms", fmt.Sprintf("%.2f", time.Since(start).Seconds()*1000))

	// Copy additional headers from proxy response
	if cacheHdr := resp.Header.Get("X-Cache"); cacheHdr != "" {
		w.Header().Set("X-Cache-Origin", cacheHdr)
	}

	w.WriteHeader(resp.StatusCode)
	w.Write(content)

	s.lgr.Info("Request proxied successfully",
		logger.F("url", url),
		logger.F("target_node", nodeAddr),
		logger.F("total_latency_ms", time.Since(start).Milliseconds()),
		logger.F("size_bytes", len(content)))
}

// fetchFromOrigin fetches content from the original URL
func (s *HTTPCacheServer) fetchFromOrigin(url string) ([]byte, string, int, error) {
	s.lgr.Debug("Fetching from origin", logger.F("url", url))

	client := &http.Client{
		Timeout: 30 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			// Allow up to 10 redirects
			if len(via) >= 10 {
				return fmt.Errorf("too many redirects")
			}
			return nil
		},
	}

	resp, err := client.Get(url)
	if err != nil {
		return nil, "", 0, fmt.Errorf("origin request failed: %w", err)
	}
	defer resp.Body.Close()

	statusCode := resp.StatusCode
	if statusCode < 200 || statusCode >= 300 {
		return nil, "", statusCode, fmt.Errorf("origin returned status %d", statusCode)
	}

	content, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", statusCode, fmt.Errorf("failed to read origin response: %w", err)
	}

	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	s.lgr.Info("Origin fetch successful",
		logger.F("url", url),
		logger.F("size_bytes", len(content)),
		logger.F("content_type", contentType),
		logger.F("status_code", statusCode))

	return content, contentType, statusCode, nil
}

// handleMetrics returns cache and hotspot statistics as JSON
func (s *HTTPCacheServer) handleMetrics(w http.ResponseWriter, r *http.Request) {
	cacheMetrics := s.cache.GetMetrics()
	hotURLs := s.hotspotDetector.GetHotURLs()

	// Routing table info
	succCount := len(s.node.SuccessorList())
	deBruijnCount := len(s.node.DeBruijnList())
	hasPred := s.node.Predecessor() != nil
	routingStats := s.node.RoutingMetrics()

	response := map[string]interface{}{
		"node": map[string]interface{}{
			"id":   s.node.Self().ID.ToHexString(true),
			"addr": s.node.Self().Addr,
		},
		"cache": map[string]interface{}{
			"hits":           cacheMetrics.Hits,
			"misses":         cacheMetrics.Misses,
			"evictions":      cacheMetrics.Evictions,
			"stores":         cacheMetrics.Stores,
			"hit_rate":       cacheMetrics.HitRate,
			"entry_count":    cacheMetrics.EntryCount,
			"size_bytes":     cacheMetrics.SizeBytes,
			"capacity_bytes": cacheMetrics.CapacityBytes,
			"utilization":    cacheMetrics.Utilization,
		},
		"hotspots": map[string]interface{}{
			"count": len(hotURLs),
			"urls":  hotURLs,
		},
		"routing": map[string]interface{}{
			"successor_count": succCount,
			"debruijn_count":  deBruijnCount,
			"has_predecessor": hasPred,
			"stats": map[string]interface{}{
				"protocol":                  routingStats.Protocol,
				"de_bruijn_success":         routingStats.DeBruijnSuccessCount,
				"de_bruijn_failures":        routingStats.DeBruijnFailureCount,
				"successor_fallbacks":       routingStats.SuccessorFallbackCount,
				"avg_de_bruijn_success_ms":  routingStats.AvgDeBruijnSuccessLatencyMs,
				"avg_de_bruijn_failure_ms":  routingStats.AvgDeBruijnFailureLatencyMs,
				"avg_successor_fallback_ms": routingStats.AvgSuccessorFallbackLatency,
			},
		},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// handleHealth returns node health status
func (s *HTTPCacheServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	// Check if node is properly initialized
	healthy := true
	status := "READY"
	self := s.node.Self()
	nodeID := ""
	if self == nil {
		healthy = false
		status = "NOT_INITIALIZED"
	} else {
		nodeID = self.ID.ToHexString(true)
	}

	succList := s.node.SuccessorList()
	successorReady := len(succList) > 0
	if !successorReady {
		healthy = false
		if status == "READY" {
			status = "NOT_INITIALIZED"
		}
	}

	routingStats := s.node.RoutingMetrics()
	deBruijnList := s.node.DeBruijnList()
	requiredDeBruijn := s.node.Space().GraphGrade
	deBruijnCount := len(deBruijnList)
	deBruijnReady := true
	if routingStats.Protocol == "koorde" {
		// Require at least 1 de Bruijn neighbor for readiness (full degree may exceed cluster size)
		deBruijnReady = deBruijnCount >= 1
		if !deBruijnReady {
			healthy = false
			status = "DEBRUIJN_NOT_READY"
		}
	}

	response := map[string]interface{}{
		"healthy": healthy,
		"status":  status,
		"node_id": nodeID,
		"details": map[string]interface{}{
			"protocol":           routingStats.Protocol,
			"successor_ready":    successorReady,
			"successor_count":    len(succList),
			"de_bruijn_ready":    deBruijnReady,
			"de_bruijn_count":    deBruijnCount,
			"required_de_bruijn": requiredDeBruijn,
		},
	}

	w.Header().Set("Content-Type", "application/json")

	if !healthy {
		w.WriteHeader(http.StatusServiceUnavailable)
	}

	json.NewEncoder(w).Encode(response)
}

// handleClusterRemove handles membership update requests for simple hash nodes.
// POST /cluster/remove?node=localhost:4003
// This endpoint only works for simple hash protocol nodes.
func (s *HTTPCacheServer) handleClusterRemove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed, use POST", http.StatusMethodNotAllowed)
		return
	}

	nodeAddr := r.URL.Query().Get("node")
	if nodeAddr == "" {
		http.Error(w, "missing 'node' query parameter", http.StatusBadRequest)
		return
	}

	// Type assertion to check if this is a simple hash node with RemoveNode method
	type nodeRemover interface {
		RemoveNode(addr string) error
	}

	remover, ok := s.node.(nodeRemover)
	if !ok {
		http.Error(w, "cluster membership update only supported for simple hash protocol", http.StatusBadRequest)
		return
	}

	// Remove the node from cluster membership
	if err := remover.RemoveNode(nodeAddr); err != nil {
		s.lgr.Warn("Failed to remove node from cluster",
			logger.F("node", nodeAddr),
			logger.F("err", err))
		http.Error(w, fmt.Sprintf("failed to remove node: %v", err), http.StatusInternalServerError)
		return
	}

	s.lgr.Info("Node removed from cluster membership",
		logger.F("removed_node", nodeAddr))

	// Return success response
	response := map[string]interface{}{
		"success":      true,
		"removed_node": nodeAddr,
		"message":      "node removed from cluster membership",
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// handleClusterAdd handles node addition requests for simple hash nodes.
// POST /cluster/add?node=localhost:4003
// This endpoint only works for simple hash protocol nodes.
func (s *HTTPCacheServer) handleClusterAdd(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed, use POST", http.StatusMethodNotAllowed)
		return
	}

	nodeAddr := r.URL.Query().Get("node")
	if nodeAddr == "" {
		http.Error(w, "missing 'node' query parameter", http.StatusBadRequest)
		return
	}

	// Type assertion to check if this is a simple hash node with AddNode method
	type nodeAdder interface {
		AddNode(addr string) error
	}

	adder, ok := s.node.(nodeAdder)
	if !ok {
		http.Error(w, "cluster membership update only supported for simple hash protocol", http.StatusBadRequest)
		return
	}

	// Add the node to cluster membership
	if err := adder.AddNode(nodeAddr); err != nil {
		s.lgr.Warn("Failed to add node to cluster",
			logger.F("node", nodeAddr),
			logger.F("err", err))
		http.Error(w, fmt.Sprintf("failed to add node: %v", err), http.StatusInternalServerError)
		return
	}

	s.lgr.Info("Node added to cluster membership",
		logger.F("added_node", nodeAddr))

	// Return success response
	response := map[string]interface{}{
		"success":    true,
		"added_node": nodeAddr,
		"message":    "node added to cluster membership",
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// handleDebug returns detailed routing table information
func (s *HTTPCacheServer) handleDebug(w http.ResponseWriter, r *http.Request) {
	self := s.node.Self()
	pred := s.node.Predecessor()
	succList := s.node.SuccessorList()
	deBruijnList := s.node.DeBruijnList()

	// Build response
	response := map[string]interface{}{
		"self": map[string]string{
			"id":   self.ID.ToHexString(true),
			"addr": self.Addr,
		},
	}

	if pred != nil {
		response["predecessor"] = map[string]string{
			"id":   pred.ID.ToHexString(true),
			"addr": pred.Addr,
		}
	} else {
		response["predecessor"] = nil
	}

	// Successors
	successors := make([]map[string]string, 0, len(succList))
	for _, succ := range succList {
		if succ != nil {
			successors = append(successors, map[string]string{
				"id":   succ.ID.ToHexString(true),
				"addr": succ.Addr,
			})
		}
	}
	response["successors"] = successors

	// De Bruijn
	deBruijn := make([]map[string]string, 0, len(deBruijnList))
	for _, db := range deBruijnList {
		if db != nil {
			deBruijn = append(deBruijn, map[string]string{
				"id":   db.ID.ToHexString(true),
				"addr": db.Addr,
			})
		}
	}
	response["de_bruijn_list"] = deBruijn

	// Calculate routing table size
	routingTableBytes := 0
	routingTableBytes += 8 // self pointer
	if pred != nil {
		routingTableBytes += 8
	}
	routingTableBytes += len(succList) * 8
	routingTableBytes += len(deBruijnList) * 8

	response["routing_table_bytes"] = routingTableBytes

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}
