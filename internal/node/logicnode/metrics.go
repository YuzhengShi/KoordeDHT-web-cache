package logicnode

import (
	"KoordeDHT/internal/node/dht"
	"sync/atomic"
	"time"
)

// routingStats tracks Koorde-specific routing instrumentation.
type routingStats struct {
	deBruijnSuccessCount   atomic.Uint64
	deBruijnFailureCount   atomic.Uint64
	successorFallbackCount atomic.Uint64

	deBruijnSuccessLatency   atomic.Int64
	deBruijnFailureLatency   atomic.Int64
	successorFallbackLatency atomic.Int64
}

func newRoutingStats() *routingStats {
	return &routingStats{}
}

func (s *routingStats) observeDeBruijnSuccess(d time.Duration) {
	s.deBruijnSuccessCount.Add(1)
	s.deBruijnSuccessLatency.Add(d.Nanoseconds())
}

func (s *routingStats) observeDeBruijnFailure(d time.Duration) {
	s.deBruijnFailureCount.Add(1)
	s.deBruijnFailureLatency.Add(d.Nanoseconds())
}

func (s *routingStats) observeSuccessorFallback(d time.Duration) {
	s.successorFallbackCount.Add(1)
	s.successorFallbackLatency.Add(d.Nanoseconds())
}

func (s *routingStats) snapshot() dht.RoutingMetrics {
	return dht.RoutingMetrics{
		Protocol:                    "koorde",
		DeBruijnSuccessCount:        s.deBruijnSuccessCount.Load(),
		DeBruijnFailureCount:        s.deBruijnFailureCount.Load(),
		SuccessorFallbackCount:      s.successorFallbackCount.Load(),
		AvgDeBruijnSuccessLatencyMs: avgMillis(s.deBruijnSuccessLatency.Load(), s.deBruijnSuccessCount.Load()),
		AvgDeBruijnFailureLatencyMs: avgMillis(s.deBruijnFailureLatency.Load(), s.deBruijnFailureCount.Load()),
		AvgSuccessorFallbackLatency: avgMillis(s.successorFallbackLatency.Load(), s.successorFallbackCount.Load()),
	}
}

func avgMillis(totalNano int64, count uint64) float64 {
	if count == 0 {
		return 0
	}
	return float64(totalNano) / float64(count) / 1e6
}
