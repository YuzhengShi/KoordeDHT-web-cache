// Package simple provides a simple modulo hash-based "DHT" implementation
// for baseline comparison experiments.
//
// Unlike Chord or Koorde which use consistent hashing, this implementation
// uses simple modulo hashing: hash(key) % N, where N is the number of nodes.
// This approach has a major weakness: when nodes are added/removed, almost
// all keys need to be remapped (~100% key redistribution on membership change).
//
// This package is intended for experimental comparison of cache hit/miss rates
// between simple hashing and consistent hashing approaches.
package simple

import (
	dhtv1 "KoordeDHT/internal/api/dht/v1"
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	client2 "KoordeDHT/internal/node/client"
	"KoordeDHT/internal/node/dht"
	"KoordeDHT/internal/node/storage"
	"context"
	"fmt"
	"math/big"
	"sort"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Node implements a simple modulo hash-based node for baseline comparison.
// It does not perform any DHT routing - instead it uses hash(key) % N
// to determine which node is responsible for a key.
type Node struct {
	lgr   logger.Logger
	s     *storage.Storage
	cp    *client2.Pool // client pool (for API compatibility, not used for routing)
	space domain.Space

	mu           sync.RWMutex
	self         *domain.Node   // This node's identity
	clusterNodes []*domain.Node // All nodes in the cluster (sorted by address)
	nodeIndex    int            // This node's index in the sorted cluster list
}

// New creates a new simple hash node.
//
// Parameters:
//   - self: this node's identity (ID and address)
//   - space: the identifier space configuration
//   - cp: client pool (for API compatibility)
//   - storage: the local storage for this node
//   - opts: optional configuration options
func New(self *domain.Node, space domain.Space, cp *client2.Pool, storage *storage.Storage, opts ...Option) *Node {
	n := &Node{
		lgr:          &logger.NopLogger{},
		s:            storage,
		cp:           cp,
		space:        space,
		self:         self,
		clusterNodes: []*domain.Node{self}, // Initially just self
		nodeIndex:    0,
	}

	// Apply options
	for _, opt := range opts {
		opt(n)
	}

	return n
}

// SetClusterNodes sets the full list of cluster nodes.
// This should be called after New() with the complete cluster membership.
func (n *Node) SetClusterNodes(nodes []*domain.Node) {
	n.mu.Lock()
	defer n.mu.Unlock()

	// Sort nodes by their address (for deterministic ordering)
	sorted := make([]*domain.Node, len(nodes))
	copy(sorted, nodes)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Addr < sorted[j].Addr
	})

	n.clusterNodes = sorted

	// Find our index in the sorted list
	for i, node := range n.clusterNodes {
		if node.Addr == n.self.Addr {
			n.nodeIndex = i
			break
		}
	}

	n.lgr.Info("simple: cluster nodes set",
		logger.F("total_nodes", len(n.clusterNodes)),
		logger.F("self_index", n.nodeIndex),
		logger.FNode("self", n.self))
}

// getResponsibleNodeIndex returns the index of the node responsible for the given ID
// using simple modulo hashing: hash(key) % N
func (n *Node) getResponsibleNodeIndex(id domain.ID) int {
	n.mu.RLock()
	clusterSize := len(n.clusterNodes)
	n.mu.RUnlock()

	if clusterSize == 0 {
		return 0
	}

	// Convert ID to big.Int and compute modulo
	idBig := id.ToBigInt()
	clusterSizeBig := big.NewInt(int64(clusterSize))
	idx := new(big.Int).Mod(idBig, clusterSizeBig)

	return int(idx.Int64())
}

// getResponsibleNode returns the node responsible for the given ID
func (n *Node) getResponsibleNode(id domain.ID) *domain.Node {
	idx := n.getResponsibleNodeIndex(id)

	n.mu.RLock()
	defer n.mu.RUnlock()

	if idx >= 0 && idx < len(n.clusterNodes) {
		return n.clusterNodes[idx]
	}
	return n.self
}

// isResponsible returns true if this node is responsible for the given ID
func (n *Node) isResponsible(id domain.ID) bool {
	idx := n.getResponsibleNodeIndex(id)
	n.mu.RLock()
	defer n.mu.RUnlock()
	return idx == n.nodeIndex
}

// IsResponsibleFor checks if this node is responsible for the given ID.
// This is the PUBLIC version for use by the HTTP server's ownership check.
// It uses modulo-based ownership: hash(key) % N == self.index
func (n *Node) IsResponsibleFor(id domain.ID) bool {
	return n.isResponsible(id)
}

// Join is a no-op for simple hash nodes since membership is static.
// The cluster is fully defined at construction time.
func (n *Node) Join(peers []string) error {
	n.lgr.Info("simple: Join called (no-op for static membership)")
	return nil
}

// Leave is a no-op for simple hash nodes.
func (n *Node) Leave() error {
	n.lgr.Info("simple: Leave called")
	return nil
}

// Stop releases resources.
func (n *Node) Stop() {
	n.lgr.Info("simple: node stopped")
}

// Put stores a resource. For simple hash, it stores locally if we're responsible.
func (n *Node) Put(ctx context.Context, res domain.Resource) error {
	if n.isResponsible(res.Key) {
		return n.StoreLocal(ctx, res)
	}
	// In a full implementation, we would forward to the responsible node
	// For now, we just return an error (the HTTP layer handles forwarding)
	return fmt.Errorf("simple: not responsible for key %s", res.Key.ToHexString(true))
}

// Get retrieves a resource. For simple hash, it retrieves locally if we're responsible.
func (n *Node) Get(ctx context.Context, id domain.ID) (*domain.Resource, error) {
	if n.isResponsible(id) {
		res, err := n.RetrieveLocal(id)
		if err != nil {
			return nil, err
		}
		return &res, nil
	}
	return nil, fmt.Errorf("simple: not responsible for key %s", id.ToHexString(true))
}

// Delete removes a resource.
func (n *Node) Delete(ctx context.Context, id domain.ID) error {
	if n.isResponsible(id) {
		return n.RemoveLocal(id)
	}
	return fmt.Errorf("simple: not responsible for key %s", id.ToHexString(true))
}

// LookUp finds the node responsible for the given ID using modulo hashing.
func (n *Node) LookUp(ctx context.Context, id domain.ID) (*domain.Node, error) {
	responsible := n.getResponsibleNode(id)
	n.lgr.Debug("simple: lookup",
		logger.F("key", id.ToHexString(true)),
		logger.FNode("responsible", responsible))
	return responsible, nil
}

// HandleFindSuccessor processes a FindSuccessor RPC request.
// For simple hash, this just returns the responsible node based on modulo.
func (n *Node) HandleFindSuccessor(ctx context.Context, req *dhtv1.FindSuccessorRequest) (*dhtv1.FindSuccessorResponse, error) {
	if req == nil || len(req.TargetId) == 0 {
		return nil, status.Error(codes.InvalidArgument, "missing target_id")
	}

	target := domain.ID(req.TargetId)
	responsible := n.getResponsibleNode(target)

	return &dhtv1.FindSuccessorResponse{
		Node: responsible.ToProtoDHT(),
	}, nil
}

// Self returns this node's identity.
func (n *Node) Self() *domain.Node {
	return n.self
}

// SuccessorList returns all other nodes in the cluster (for compatibility).
// Simple hash doesn't use successor lists, but we return all nodes for
// the HTTP layer's fallback logic.
func (n *Node) SuccessorList() []*domain.Node {
	n.mu.RLock()
	defer n.mu.RUnlock()

	result := make([]*domain.Node, 0, len(n.clusterNodes))
	for _, node := range n.clusterNodes {
		if node.Addr != n.self.Addr {
			result = append(result, node)
		}
	}
	return result
}

// DeBruijnList returns nil - simple hash doesn't use de Bruijn routing.
func (n *Node) DeBruijnList() []*domain.Node {
	return nil
}

// Predecessor returns nil - simple hash doesn't use predecessor pointers.
func (n *Node) Predecessor() *domain.Node {
	// For simple hash, we can compute our "predecessor" as the node before us in the sorted list
	n.mu.RLock()
	defer n.mu.RUnlock()

	if len(n.clusterNodes) <= 1 {
		return nil
	}

	predIdx := (n.nodeIndex - 1 + len(n.clusterNodes)) % len(n.clusterNodes)
	return n.clusterNodes[predIdx]
}

// HandleLeave processes a leave notification (no-op for simple hash).
func (n *Node) HandleLeave(leaveNode *domain.Node) error {
	return nil
}

// Notify processes a stabilization notification (no-op for simple hash).
func (n *Node) Notify(node *domain.Node) {
	// No-op - simple hash doesn't use stabilization
}

// IsValidID checks if the given ID is valid for this node's space.
func (n *Node) IsValidID(id []byte) error {
	return n.space.IsValidID(id)
}

// Space returns the identifier space configuration.
func (n *Node) Space() *domain.Space {
	return &n.space
}

// EstimateNetworkSize returns the known cluster size.
func (n *Node) EstimateNetworkSize() int {
	n.mu.RLock()
	defer n.mu.RUnlock()
	return len(n.clusterNodes)
}

// GetAllResourceStored returns all resources stored locally.
func (n *Node) GetAllResourceStored() []domain.Resource {
	return n.s.All()
}

// StoreLocal stores a resource locally.
func (n *Node) StoreLocal(ctx context.Context, res domain.Resource) error {
	n.s.Put(res)
	return nil
}

// RetrieveLocal retrieves a resource locally.
func (n *Node) RetrieveLocal(id domain.ID) (domain.Resource, error) {
	return n.s.Get(id)
}

// RemoveLocal removes a resource locally.
func (n *Node) RemoveLocal(id domain.ID) error {
	return n.s.Delete(id)
}

// CreateNewDHT initializes the node (no-op for simple hash - already initialized).
func (n *Node) CreateNewDHT() {
	n.lgr.Info("simple: CreateNewDHT called (cluster already initialized)")
}

// StartStabilizers starts background tasks (no-op for simple hash).
// Simple hash doesn't need stabilization since membership is static.
func (n *Node) StartStabilizers(ctx context.Context, stabilizationInterval, deBruijnInterval, storageInterval time.Duration) {
	n.lgr.Info("simple: stabilizers not needed for static membership")
}

// RoutingMetrics returns routing statistics.
func (n *Node) RoutingMetrics() dht.RoutingMetrics {
	return dht.RoutingMetrics{
		Protocol: "simple",
	}
}

// ClusterNodes returns all nodes in the cluster (for debugging/metrics).
func (n *Node) ClusterNodes() []*domain.Node {
	n.mu.RLock()
	defer n.mu.RUnlock()

	result := make([]*domain.Node, len(n.clusterNodes))
	copy(result, n.clusterNodes)
	return result
}

// RemoveNode removes a node from the cluster membership.
// This is used to update membership when a node leaves or fails.
// After removal, keys will be remapped using hash(key) % (N-1).
func (n *Node) RemoveNode(addr string) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	// Find and remove the node with the given address
	newCluster := make([]*domain.Node, 0, len(n.clusterNodes)-1)
	found := false
	for _, node := range n.clusterNodes {
		if node.Addr == addr {
			found = true
			continue
		}
		newCluster = append(newCluster, node)
	}

	if !found {
		return fmt.Errorf("simple: node %s not found in cluster", addr)
	}

	n.clusterNodes = newCluster

	// Recalculate our own index in the new cluster
	for i, node := range n.clusterNodes {
		if node.Addr == n.self.Addr {
			n.nodeIndex = i
			break
		}
	}

	n.lgr.Info("simple: node removed from cluster",
		logger.F("removed_addr", addr),
		logger.F("new_cluster_size", len(n.clusterNodes)),
		logger.F("self_index", n.nodeIndex))

	return nil
}

// AddNode adds a node to the cluster membership.
// This is used to update membership when a new node joins.
// After addition, keys will be remapped using hash(key) % (N+1).
func (n *Node) AddNode(addr string) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	// Check if node already exists
	for _, node := range n.clusterNodes {
		if node.Addr == addr {
			n.lgr.Debug("simple: node already in cluster",
				logger.F("addr", addr))
			return nil // Already exists, no-op
		}
	}

	// Create a new node with a generated ID based on address
	newNodeID := n.space.NewIdFromString(addr)
	newNode := &domain.Node{
		ID:   newNodeID,
		Addr: addr,
	}

	// Add to cluster and re-sort
	n.clusterNodes = append(n.clusterNodes, newNode)
	sort.Slice(n.clusterNodes, func(i, j int) bool {
		return n.clusterNodes[i].Addr < n.clusterNodes[j].Addr
	})

	// Recalculate our own index in the new cluster
	for i, node := range n.clusterNodes {
		if node.Addr == n.self.Addr {
			n.nodeIndex = i
			break
		}
	}

	n.lgr.Info("simple: node added to cluster",
		logger.F("added_addr", addr),
		logger.F("new_cluster_size", len(n.clusterNodes)),
		logger.F("self_index", n.nodeIndex))

	return nil
}
