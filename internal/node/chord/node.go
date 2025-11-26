package chord

import (
	dhtv1 "KoordeDHT/internal/api/dht/v1"
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	client2 "KoordeDHT/internal/node/client"
	"KoordeDHT/internal/node/ctxutil"
	"KoordeDHT/internal/node/dht"
	"KoordeDHT/internal/node/storage"
	"context"
	"fmt"
	"sync"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Node struct {
	lgr logger.Logger
	s   *storage.Storage
	cp  *client2.Pool
	rt  *RoutingTable

	// Chord specific state
	mu sync.RWMutex
}

func New(space domain.Space, clientpool *client2.Pool, storage *storage.Storage, opts ...Option) *Node {
	n := &Node{
		lgr: &logger.NopLogger{},
		cp:  clientpool,
		s:   storage,
	}
	// Apply options
	for _, opt := range opts {
		opt(n)
	}

	// Initialize routing table if not set
	if n.rt == nil {
		// We need a self node. If not provided via options (which sets rt), we can't create rt properly without ID.
		// But usually ID is passed or generated before creating Node.
		// In main.go, routingtable is created before logicnode.
		// So we should expect WithRoutingTable option to be used.
	}

	return n
}

// Join connects the node to an existing DHT network.
func (n *Node) Join(peers []string) error {
	if len(peers) == 0 {
		return fmt.Errorf("join: no bootstrap peers provided")
	}
	self := n.rt.Self()
	var succ *domain.Node
	var lastErr error

	// Try each peer
	for _, addr := range peers {
		if addr == self.Addr {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), n.cp.FailureTimeout())
		cli, conn, err := n.cp.DialEphemeral(addr)
		if err != nil {
			lastErr = fmt.Errorf("join: failed to dial bootstrap %s: %w", addr, err)
			cancel()
			continue
		}

		// Chord Join: find successor of self.ID
		succ, lastErr = client2.FindSuccessorStart(ctx, cli, n.Space(), self.ID)
		cancel()
		conn.Close()

		if lastErr == nil && succ != nil {
			if succ.ID.Equal(self.ID) {
				return fmt.Errorf("join: there is already a node with the same ID")
			}
			n.lgr.Info("join: candidate successor found",
				logger.F("bootstrap", addr),
				logger.FNode("successor", succ))
			break
		}
	}

	if succ == nil {
		return fmt.Errorf("join: all bootstrap attempts failed: %w", lastErr)
	}

	// Update routing table
	n.rt.SetSuccessor(0, succ)

	n.lgr.Info("join: completed successfully",
		logger.FNode("self", self),
		logger.FNode("successor", succ))
	return nil
}

func (n *Node) Leave() error {
	return nil // TODO implementation
}

func (n *Node) Stop() {
	if n.cp != nil {
		_ = n.cp.Close()
	}
}

func (n *Node) Put(ctx context.Context, res domain.Resource) error {
	if err := ctxutil.CheckContext(ctx); err != nil {
		return err
	}
	succ, err := n.LookUp(ctx, res.Key)
	if err != nil {
		return err
	}
	if succ.ID.Equal(n.rt.Self().ID) {
		return n.StoreLocal(ctx, res)
	}

	// Forward to successor
	sres := []domain.Resource{res}
	cli, err := n.cp.GetFromPool(succ.Addr)
	if err != nil {
		return err
	}
	_, err = client2.StoreRemote(ctx, cli, sres)
	return err
}

func (n *Node) Get(ctx context.Context, id domain.ID) (*domain.Resource, error) {
	if err := ctxutil.CheckContext(ctx); err != nil {
		return nil, err
	}
	succ, err := n.LookUp(ctx, id)
	if err != nil {
		return nil, err
	}
	if succ.ID.Equal(n.rt.Self().ID) {
		res, err := n.RetrieveLocal(id)
		if err != nil {
			return nil, err
		}
		return &res, nil
	}

	cli, err := n.cp.GetFromPool(succ.Addr)
	if err != nil {
		return nil, err
	}
	return client2.RetrieveRemote(ctx, cli, n.Space(), id)
}

func (n *Node) Delete(ctx context.Context, id domain.ID) error {
	if err := ctxutil.CheckContext(ctx); err != nil {
		return err
	}
	succ, err := n.LookUp(ctx, id)
	if err != nil {
		return err
	}
	if succ.ID.Equal(n.rt.Self().ID) {
		return n.RemoveLocal(id)
	}

	cli, err := n.cp.GetFromPool(succ.Addr)
	if err != nil {
		return err
	}
	return client2.RemoveRemote(ctx, cli, id)
}

func (n *Node) LookUp(ctx context.Context, id domain.ID) (*domain.Node, error) {
	// Chord lookup logic
	// Find successor of id

	// 1. Check if id is in (self, successor]
	self := n.rt.Self()
	succ := n.rt.FirstSuccessor()
	if succ == nil {
		return nil, fmt.Errorf("lookup: successor is nil")
	}

	if id.Between(self.ID, succ.ID) || id.Equal(succ.ID) {
		return succ, nil
	}

	// 2. Find closest preceding node in finger table
	closest := n.rt.ClosestPrecedingNode(id)

	// 3. If closest is self, we are stuck (shouldn't happen if finger table is correct)
	// forward to successor
	if closest.ID.Equal(self.ID) {
		closest = succ
	}

	// 4. Forward query to closest
	cli, err := n.cp.GetFromPool(closest.Addr)
	if err != nil {
		return nil, err
	}

	// Use FindSuccessor RPC
	// We can use Initial mode for simplicity, as Chord doesn't need Step state
	return client2.FindSuccessorStart(ctx, cli, n.Space(), id)
}

func (n *Node) HandleFindSuccessor(ctx context.Context, req *dhtv1.FindSuccessorRequest) (*dhtv1.FindSuccessorResponse, error) {
	if req == nil || len(req.TargetId) == 0 {
		return nil, status.Error(codes.InvalidArgument, "missing target_id")
	}
	target := domain.ID(req.TargetId)

	succ, err := n.LookUp(ctx, target)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "lookup failed: %v", err)
	}

	return &dhtv1.FindSuccessorResponse{Node: succ.ToProtoDHT()}, nil
}

func (n *Node) Self() *domain.Node {
	return n.rt.Self()
}

func (n *Node) SuccessorList() []*domain.Node {
	return n.rt.SuccessorList()
}

func (n *Node) Predecessor() *domain.Node {
	return n.rt.GetPredecessor()
}

func (n *Node) HandleLeave(leaveNode *domain.Node) error {
	// TODO
	return nil
}

func (n *Node) Notify(node *domain.Node) {
	if node == nil {
		return
	}

	pred := n.rt.GetPredecessor()
	self := n.rt.Self()

	// If we have no predecessor, or if node is between pred and self, update predecessor
	if pred == nil {
		n.rt.SetPredecessor(node)
		n.lgr.Info("Notify: set predecessor (was nil)",
			logger.FNode("new_pred", node))
	} else if node.ID.Between(pred.ID, self.ID) {
		n.rt.SetPredecessor(node)
		n.lgr.Info("Notify: updated predecessor",
			logger.FNode("old_pred", pred),
			logger.FNode("new_pred", node))
	}
}

func (n *Node) IsValidID(id []byte) error {
	return n.rt.Space().IsValidID(id)
}

func (n *Node) Space() *domain.Space {
	return n.rt.Space()
}

func (n *Node) EstimateNetworkSize() int {
	return 1
}

func (n *Node) GetAllResourceStored() []domain.Resource {
	return n.s.All()
}

func (n *Node) StoreLocal(ctx context.Context, res domain.Resource) error {
	n.s.Put(res)
	return nil
}

func (n *Node) RetrieveLocal(id domain.ID) (domain.Resource, error) {
	return n.s.Get(id)
}

func (n *Node) RemoveLocal(id domain.ID) error {
	return n.s.Delete(id)
}

func (n *Node) DeBruijnList() []*domain.Node {
	return nil // Chord doesn't use De Bruijn
}

func (n *Node) RoutingMetrics() dht.RoutingMetrics {
	return dht.RoutingMetrics{Protocol: "chord"}
}

// FingerList returns all non-nil finger table entries (Chord-specific)
func (n *Node) FingerList() []*domain.Node {
	return n.rt.FingerList()
}

func (n *Node) CreateNewDHT() {
	self := n.rt.Self()
	n.rt.SetSuccessor(0, self)
	n.rt.SetPredecessor(nil)
	n.lgr.Info("CreateNewDHT: initialized new Chord ring", logger.FNode("self", self))
}

// StartStabilizers starts the background stabilization tasks.
// Note: Actual implementation is in stabilization.go, but we need to ensure method signature matches interface.
// Wait, if I put it here, it might conflict with stabilization.go if I defined it there too.
// I should NOT define it here if it's in stabilization.go.
// But I need to make sure stabilization.go has the correct package and receiver.
// stabilization.go is in package chord.
// So I will omit StartStabilizers from here and rely on stabilization.go.
