package dht

// RoutingMetrics captures runtime routing statistics that DHT implementations
// can expose to the HTTP metrics endpoint.
type RoutingMetrics struct {
	Protocol                    string  `json:"protocol"`
	DeBruijnSuccessCount        uint64  `json:"de_bruijn_success"`
	DeBruijnFailureCount        uint64  `json:"de_bruijn_failures"`
	SuccessorFallbackCount      uint64  `json:"successor_fallbacks"`
	AvgDeBruijnSuccessLatencyMs float64 `json:"avg_de_bruijn_success_ms"`
	AvgDeBruijnFailureLatencyMs float64 `json:"avg_de_bruijn_failure_ms"`
	AvgSuccessorFallbackLatency float64 `json:"avg_successor_fallback_ms"`
}
