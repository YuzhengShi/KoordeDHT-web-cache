package server

import (
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	"KoordeDHT/internal/node/cache"
	"KoordeDHT/internal/node/logicnode"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"time"
)

// HTTPCacheServer provides HTTP endpoints for web caching functionality
type HTTPCacheServer struct {
	node    *logicnode.Node
	cache   *cache.WebCache
	hotspot *cache.HotspotDetector
	port    int
	lgr     logger.Logger
	server  *http.Server
}

// NewHTTPCacheServer creates a new HTTP cache server instance
func NewHTTPCacheServer(
	node *logicnode.Node,
	webCache *cache.WebCache,
	hotspot *cache.HotspotDetector,
	port int,
	lgr logger.Logger,
) *HTTPCacheServer {
	return &HTTPCacheServer{
		node:    node,
		cache:   webCache,
		hotspot: hotspot,
		port:    port,
		lgr:     lgr,
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
//   1. Check local cache (fast path)
//   2. Check if URL is hot (hotspot detection)
//   3. If hot: randomly distribute to any node
//   4. If normal: DHT lookup to find responsible node
//   5. If self is responsible: fetch from origin and cache
//   6. If other node responsible: proxy HTTP request
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
			s.lgr.Error("DHT lookup failed",
				logger.F("url", url),
				logger.F("hash", urlHash.ToHexString(true)),
				logger.F("err", err))
			http.Error(w, fmt.Sprintf("DHT lookup failed: %v", err), http.StatusInternalServerError)
			return
		}

		if responsible == nil {
			s.lgr.Error("DHT lookup returned nil node",
				logger.F("url", url),
				logger.F("hash", urlHash.ToHexString(true)))
			http.Error(w, "no responsible node found", http.StatusInternalServerError)
			return
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

	// STEP 3: Determine if we own the key based on local interval (pred, self]
	// ALWAYS check actual ownership, even if X-Is-Responsible header is set
	// (to prevent proxy loops if request arrives at wrong node)
	ownsKey := false
	if pred := s.node.Predecessor(); pred != nil {
		ownsKey = urlHash.Between(pred.ID, selfNode.ID)
		s.lgr.Debug("Ownership check (pred, self]",
			logger.F("url", url),
			logger.F("hash", urlHash.ToHexString(true)),
			logger.FNode("pred", pred),
			logger.FNode("self", selfNode),
			logger.F("owns_key", ownsKey),
			logger.F("forwarded_header_isResponsible", isResponsible))
	} else {
		// No predecessor yet -> operate conservatively (assume ownership only in single-node scenario)
		if len(s.node.SuccessorList()) <= 1 {
			ownsKey = true
		}
	}

	// STEP 4: If we do not own the key, forward it (even if lookup returned self)
	if !ownsKey {
		if entry, ok := s.cache.Get(url); ok {
			s.lgr.Warn("Found stale cache entry for non-owned URL, removing",
				logger.F("url", url),
				logger.F("size_bytes", entry.Size))
			s.cache.Delete(url)
		}

		targetNode := responsible
		if targetNode == nil || targetNode.ID.Equal(selfNode.ID) {
			// Fallback to first known successor that is not self
			for _, succ := range s.node.SuccessorList() {
				if succ != nil && !succ.ID.Equal(selfNode.ID) {
					targetNode = succ
					break
				}
			}
		}

		if targetNode == nil || targetNode.ID.Equal(selfNode.ID) {
			s.lgr.Error("Unable to determine responsible node for forwarding",
				logger.F("url", url),
				logger.F("hash", urlHash.ToHexString(true)))
			http.Error(w, "no responsible node available", http.StatusServiceUnavailable)
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

		w.Header().Set("Content-Type", entry.ContentType)
		w.Header().Set("X-Cache", "HIT-LOCAL")
		w.Header().Set("X-Node-ID", s.node.Self().ID.ToHexString(true))
		w.Header().Set("X-Latency-Ms", fmt.Sprintf("%.2f", time.Since(start).Seconds()*1000))
		w.Write(entry.Content)
		return
	}

	// STEP 6: Hotspot detection (only for responsible node)
	isHot := s.hotspot.RecordAccess(url)

	if isHot {
		// Hotspot detected - use random distribution strategy
		avg, total, _ := s.hotspot.GetStats(url)
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

	content, contentType, err := s.fetchFromOrigin(url)
	if err != nil {
		s.lgr.Error("Origin fetch failed",
			logger.F("url", url),
			logger.F("err", err))
		http.Error(w, fmt.Sprintf("failed to fetch from origin: %v", err), http.StatusBadGateway)
		return
	}

	// STEP 7: Cache the content locally
	if err := s.cache.Put(url, content, contentType, 1*time.Hour); err != nil {
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
	w.Write(content)

	s.lgr.Info("Request completed",
		logger.F("url", url),
		logger.F("total_latency_ms", time.Since(start).Milliseconds()),
		logger.F("content_size", len(content)))
}

// pickRandomNode selects a random node from the cluster
// Uses successor list + de Bruijn list as source of known nodes
func (s *HTTPCacheServer) pickRandomNode() string {
	// Collect all known nodes
	allNodes := make(map[string]bool)

	// Add successors
	for _, succ := range s.node.SuccessorList() {
		if succ != nil {
			allNodes[succ.Addr] = true
		}
	}

	// Add de Bruijn neighbors
	for _, db := range s.node.DeBruijnList() {
		if db != nil {
			allNodes[db.Addr] = true
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

	// Calculate HTTP port: HTTP port = gRPC port + 4080
	// This matches the convention used in local-cluster configs:
	// node0: 4000 -> 8080, node1: 4001 -> 8081, etc.
	httpPort := grpcPort + 4080

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

	// Forward response to client
	w.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
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
func (s *HTTPCacheServer) fetchFromOrigin(url string) ([]byte, string, error) {
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
		return nil, "", fmt.Errorf("origin request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("origin returned status %d", resp.StatusCode)
	}

	content, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", fmt.Errorf("failed to read origin response: %w", err)
	}

	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	s.lgr.Info("Origin fetch successful",
		logger.F("url", url),
		logger.F("size_bytes", len(content)),
		logger.F("content_type", contentType))

	return content, contentType, nil
}

// handleMetrics returns cache and hotspot statistics as JSON
func (s *HTTPCacheServer) handleMetrics(w http.ResponseWriter, r *http.Request) {
	cacheMetrics := s.cache.GetMetrics()
	hotURLs := s.hotspot.GetHotURLs()

	// Routing table info
	succCount := len(s.node.SuccessorList())
	deBruijnCount := len(s.node.DeBruijnList())
	hasPred := s.node.Predecessor() != nil

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

	succList := s.node.SuccessorList()
	if len(succList) == 0 || succList[0] == nil {
		healthy = false
		status = "NOT_INITIALIZED"
	}

	response := map[string]interface{}{
		"healthy": healthy,
		"status":  status,
		"node_id": s.node.Self().ID.ToHexString(true),
	}

	w.Header().Set("Content-Type", "application/json")

	if !healthy {
		w.WriteHeader(http.StatusServiceUnavailable)
	}

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
