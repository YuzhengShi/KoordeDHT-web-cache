package chord

import (
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	"sync"
)

type RoutingTable struct {
	self          *domain.Node
	space         domain.Space
	successorList []*domain.Node // For fault tolerance
	fingers       []*domain.Node // Finger table
	predecessor   *domain.Node
	mu            sync.RWMutex
	lgr           logger.Logger
}

func NewRoutingTable(self *domain.Node, space domain.Space, lgr logger.Logger) *RoutingTable {
	return &RoutingTable{
		self:          self,
		space:         space,
		successorList: make([]*domain.Node, space.SuccListSize),
		fingers:       make([]*domain.Node, space.Bits),
		lgr:           lgr,
	}
}

func (rt *RoutingTable) Self() *domain.Node {
	return rt.self
}

func (rt *RoutingTable) Space() *domain.Space {
	return &rt.space
}

func (rt *RoutingTable) SetSuccessor(i int, node *domain.Node) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if i >= 0 && i < len(rt.successorList) {
		rt.successorList[i] = node
		if i == 0 && node != nil {
			// Successor is also the first finger
			rt.fingers[0] = node
		}
	}
}

func (rt *RoutingTable) FirstSuccessor() *domain.Node {
	rt.mu.RLock()
	defer rt.mu.RUnlock()
	if len(rt.successorList) > 0 {
		return rt.successorList[0]
	}
	return nil
}

func (rt *RoutingTable) SuccessorList() []*domain.Node {
	rt.mu.RLock()
	defer rt.mu.RUnlock()
	// Return copy
	out := make([]*domain.Node, len(rt.successorList))
	copy(out, rt.successorList)
	return out
}

func (rt *RoutingTable) GetPredecessor() *domain.Node {
	rt.mu.RLock()
	defer rt.mu.RUnlock()
	return rt.predecessor
}

func (rt *RoutingTable) SetPredecessor(node *domain.Node) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	rt.predecessor = node
}

// ClosestPrecedingNode finds the closest node in the finger table that strictly precedes id.
func (rt *RoutingTable) ClosestPrecedingNode(id domain.ID) *domain.Node {
	rt.mu.RLock()
	defer rt.mu.RUnlock()

	// Scan fingers from furthest to closest
	for i := len(rt.fingers) - 1; i >= 0; i-- {
		finger := rt.fingers[i]
		if finger != nil {
			if finger.ID.Between(rt.self.ID, id) {
				return finger
			}
		}
	}

	// Also check successor list?
	// Standard Chord checks fingers.
	// If no finger is between self and id, return self.
	return rt.self
}

func (rt *RoutingTable) SetFinger(i int, node *domain.Node) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if i >= 0 && i < len(rt.fingers) {
		rt.fingers[i] = node
	}
}

func (rt *RoutingTable) GetFinger(i int) *domain.Node {
	rt.mu.RLock()
	defer rt.mu.RUnlock()
	if i >= 0 && i < len(rt.fingers) {
		return rt.fingers[i]
	}
	return nil
}

// FingerList returns all non-nil finger table entries
func (rt *RoutingTable) FingerList() []*domain.Node {
	rt.mu.RLock()
	defer rt.mu.RUnlock()
	fingers := make([]*domain.Node, 0)
	for _, finger := range rt.fingers {
		if finger != nil {
			fingers = append(fingers, finger)
		}
	}
	return fingers
}