package chord

import (
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	client2 "KoordeDHT/internal/node/client"
	"context"
	"math/big"
	"time"
)

// StartStabilizers starts the background stabilization goroutines.
func (n *Node) StartStabilizers(ctx context.Context, stabilizationInterval, deBruijnInterval, storageInterval time.Duration) {
	go n.stabilizeLoop(ctx, stabilizationInterval)
	go n.fixFingersLoop(ctx)
	go n.checkPredecessorLoop(ctx)
}

func (n *Node) stabilizeLoop(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			n.stabilize()
		}
	}
}

func (n *Node) fixFingersLoop(ctx context.Context) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	nextFinger := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			n.fixFinger(nextFinger)
			nextFinger = (nextFinger + 1) % n.rt.Space().Bits
		}
	}
}

func (n *Node) checkPredecessorLoop(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			n.checkPredecessor()
		}
	}
}

func (n *Node) stabilize() {
	// 1. Get successor
	succ := n.rt.FirstSuccessor()
	if succ == nil {
		return
	}

	// 2. Ask successor for its predecessor
	ctx, cancel := context.WithTimeout(context.Background(), n.cp.FailureTimeout())
	cli, err := n.cp.GetFromPool(succ.Addr)
	if err != nil {
		cancel()
		return
	}

	x, err := client2.GetPredecessor(ctx, cli, n.Space())
	cancel()

	if err != nil {
		n.lgr.Warn("stabilize: failed to get predecessor", logger.F("err", err))
		return
	}

	// 3. If x is between self and successor, x is our new successor
	if x != nil {
		if x.ID.Between(n.rt.Self().ID, succ.ID) {
			n.rt.SetSuccessor(0, x)
			succ = x
		}
	}

	// 4. Notify successor about self
	ctx, cancel = context.WithTimeout(context.Background(), n.cp.FailureTimeout())
	cli, err = n.cp.GetFromPool(succ.Addr)
	if err != nil {
		cancel()
		return
	}
	err = client2.Notify(ctx, cli, n.rt.Self())
	cancel()
	if err != nil {
		n.lgr.Warn("stabilize: failed to notify successor", logger.F("err", err))
	}

	// 5. Update successor list (ask successor for its list)
	ctx, cancel = context.WithTimeout(context.Background(), n.cp.FailureTimeout())
	list, err := client2.GetSuccessorList(ctx, cli, n.Space())
	cancel()
	if err == nil {
		// New list = [succ] + list[:len-1]
		newList := make([]*domain.Node, len(list)+1)
		newList[0] = succ
		copy(newList[1:], list)
		// Truncate to configured size
		if len(newList) > n.rt.Space().SuccListSize {
			newList = newList[:n.rt.Space().SuccListSize]
		}
		// Update local list (SetSuccessorList logic needed in RoutingTable)
		// For now, just update individual entries
		for i, node := range newList {
			n.rt.SetSuccessor(i, node)
		}
	}
}

func (n *Node) fixFinger(i int) {
	// Calculate ID: (self + 2^i) mod 2^Bits
	// This is the standard Chord finger table entry calculation
	
	if i < 0 || i >= n.rt.Space().Bits {
		return // Invalid finger index
	}

	self := n.rt.Self()
	space := n.rt.Space()

	// Compute 2^i as a big integer
	twoToI := new(big.Int).Lsh(big.NewInt(1), uint(i))
	
	// Convert self.ID to big.Int
	selfBig := self.ID.ToBigInt()
	
	// Compute (self + 2^i) mod 2^Bits
	maxID := new(big.Int).Lsh(big.NewInt(1), uint(space.Bits))
	fingerTargetBig := new(big.Int).Add(selfBig, twoToI)
	fingerTargetBig.Mod(fingerTargetBig, maxID)

	// Convert back to ID
	fingerTarget := make(domain.ID, space.ByteLen)
	fingerTargetBytes := fingerTargetBig.Bytes()
	if len(fingerTargetBytes) > 0 {
		// Copy bytes right-aligned (big-endian)
		copy(fingerTarget[space.ByteLen-len(fingerTargetBytes):], fingerTargetBytes)
	}

	// Mask unused bits if identifier size is not byte-aligned
	extraBits := space.ByteLen*8 - space.Bits
	if extraBits > 0 {
		mask := byte(0xFF >> extraBits)
		fingerTarget[0] &= mask
	}

	// Find successor of fingerTarget
	ctx, cancel := context.WithTimeout(context.Background(), n.cp.FailureTimeout())
	defer cancel()

	succ, err := n.LookUp(ctx, fingerTarget)
	if err != nil {
		n.lgr.Debug("fixFinger: lookup failed",
			logger.F("finger_index", i),
			logger.F("target", fingerTarget.ToHexString(true)),
			logger.F("err", err))
		return
	}

	// Update finger table
	n.rt.SetFinger(i, succ)
	n.lgr.Debug("fixFinger: updated finger",
		logger.F("finger_index", i),
		logger.F("target", fingerTarget.ToHexString(true)),
		logger.FNode("successor", succ))
}

func (n *Node) checkPredecessor() {
	pred := n.rt.GetPredecessor()
	if pred == nil {
		return
	}
	// Ping predecessor
	ctx, cancel := context.WithTimeout(context.Background(), n.cp.FailureTimeout())
	cli, err := n.cp.GetFromPool(pred.Addr)
	if err != nil {
		n.rt.SetPredecessor(nil)
		cancel()
		return
	}
	err = client2.Ping(ctx, cli)
	cancel()
	if err != nil {
		n.rt.SetPredecessor(nil)
	}
}
