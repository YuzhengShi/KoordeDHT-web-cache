package dht

import (
	dhtv1 "KoordeDHT/internal/api/dht/v1"
	"KoordeDHT/internal/domain"
	"context"
	"time"
)

// DHTNode defines the common interface for a Distributed Hash Table node.
// Both Koorde and Chord implementations must satisfy this interface
// to be used by the server and cache layers.
type DHTNode interface {
	// Join connects the node to an existing DHT network using the provided peer addresses.
	Join(peers []string) error

	// Leave gracefully removes the node from the network.
	Leave() error

	// Stop releases all resources and shuts down the node.
	Stop()

	// Put stores a resource in the DHT.
	Put(ctx context.Context, res domain.Resource) error

	// Get retrieves a resource from the DHT by its ID.
	Get(ctx context.Context, id domain.ID) (*domain.Resource, error)

	// Delete removes a resource from the DHT by its ID.
	Delete(ctx context.Context, id domain.ID) error

	// LookUp finds the successor node responsible for the given ID.
	LookUp(ctx context.Context, id domain.ID) (*domain.Node, error)

	// HandleFindSuccessor processes a FindSuccessor RPC request.
	// This allows the specific DHT implementation (Koorde/Chord) to handle
	// the routing logic (Initial/Step modes for Koorde, etc.).
	HandleFindSuccessor(ctx context.Context, req *dhtv1.FindSuccessorRequest) (*dhtv1.FindSuccessorResponse, error)

	// Self returns the local node information.
	Self() *domain.Node

	// SuccessorList returns the list of successor nodes for fault tolerance.
	SuccessorList() []*domain.Node

	// DeBruijnList returns the list of de Bruijn neighbors (Koorde only).
	DeBruijnList() []*domain.Node

	// Predecessor returns the current predecessor node.
	Predecessor() *domain.Node

	// HandleLeave processes a leave notification from a node.
	HandleLeave(leaveNode *domain.Node) error

	// Notify processes a stabilization notification.
	Notify(node *domain.Node)

	// IsValidID checks if the given ID is valid for the node's space.
	IsValidID(id []byte) error

	// Space returns the identifier space configuration.
	Space() *domain.Space

	// EstimateNetworkSize returns an estimated number of nodes in the network.
	EstimateNetworkSize() int

	// GetAllResourceStored returns all resources stored locally on this node.
	GetAllResourceStored() []domain.Resource

	// StoreLocal stores a resource locally (used by DHT service).
	StoreLocal(ctx context.Context, res domain.Resource) error

	// RetrieveLocal retrieves a resource locally (used by DHT service).
	RetrieveLocal(id domain.ID) (domain.Resource, error)

	// RemoveLocal removes a resource locally (used by DHT service).
	RemoveLocal(id domain.ID) error

	// CreateNewDHT initializes the node as a new DHT network (bootstrap node).
	CreateNewDHT()

	// StartStabilizers starts the background stabilization tasks.
	StartStabilizers(ctx context.Context, stabilizationInterval, deBruijnInterval, storageInterval time.Duration)

	// RoutingMetrics returns live routing statistics for observability.
	RoutingMetrics() RoutingMetrics
}
