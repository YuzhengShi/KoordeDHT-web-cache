package main

// In-memory model of a stabilised Chord / Koorde ring, used to count lookup
// hops at sizes that cannot be run for real. The routing decisions are not
// re-implemented: Koorde uses logicnode.InitStep / DecideStep and Chord uses
// chord.NextHop / chord.ClosestPreceding, the same functions the node code
// calls. What is modelled here is only the ring (sorted node IDs), the routing
// tables a stabilised node would hold, and the walk from node to node.

import (
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/node/chord"
	"KoordeDHT/internal/node/logicnode"
	"bytes"
	"fmt"
	"math/big"
	"math/rand"
	"sort"
)

// WindowMode selects how Koorde's de Bruijn window is built.
type WindowMode int

const (
	// WindowRealistic follows fixDeBruijn (logicnode/worker.go): the node
	// estimates N from the gap to its successor (EstimateSizeFromGap),
	// computes target = k*m - x (ComputeFaultTolerantTarget), takes the anchor
	// = predecessor of successor(target), and fills window[0] = anchor and
	// window[i] = i-th successor of the anchor.
	WindowRealistic WindowMode = iota
	// WindowTrueN is WindowRealistic with the true N instead of the one-gap
	// estimate (a sensitivity check, not what a node does).
	WindowTrueN
	// WindowTextbook is predecessor(k*m) and its k-1 successors. The phase 1
	// hop tests use this.
	WindowTextbook
)

func (m WindowMode) String() string {
	return [...]string{"realistic", "trueN", "textbook"}[m]
}

// Ring is a set of nodes sorted by ID.
type Ring struct {
	Sp    domain.Space
	Nodes []*domain.Node
	idx   map[*domain.Node]int
}

// NewRing builds a ring from distinct IDs.
func NewRing(sp domain.Space, ids []domain.ID) *Ring {
	sorted := append([]domain.ID(nil), ids...)
	sort.Slice(sorted, func(i, j int) bool { return bytes.Compare(sorted[i], sorted[j]) < 0 })
	r := &Ring{Sp: sp, idx: make(map[*domain.Node]int, len(ids))}
	for i, id := range sorted {
		if i > 0 && bytes.Equal(id, sorted[i-1]) {
			panic("duplicate node ID")
		}
		n := &domain.Node{ID: id}
		r.Nodes = append(r.Nodes, n)
		r.idx[n] = i
	}
	return r
}

// RandomIDs returns n distinct uniform random IDs of the space.
func RandomIDs(sp domain.Space, n int, rng *rand.Rand) []domain.ID {
	seen := make(map[string]bool, n)
	out := make([]domain.ID, 0, n)
	for len(out) < n {
		id := randomID(sp, rng)
		if !seen[string(id)] {
			seen[string(id)] = true
			out = append(out, id)
		}
	}
	return out
}

func randomID(sp domain.Space, rng *rand.Rand) domain.ID {
	id := make(domain.ID, sp.ByteLen)
	rng.Read(id)
	if extra := sp.ByteLen*8 - sp.Bits; extra > 0 {
		id[0] &= byte(0xFF >> extra)
	}
	return id
}

func (r *Ring) N() int { return len(r.Nodes) }

// succIdx is the index of successor(id): the first node with ID >= id, wrapping.
func (r *Ring) succIdx(id domain.ID) int {
	i := sort.Search(len(r.Nodes), func(i int) bool { return bytes.Compare(r.Nodes[i].ID, id) >= 0 })
	if i == len(r.Nodes) {
		return 0
	}
	return i
}

// predIdx is the index of the last node with ID <= id, wrapping.
func (r *Ring) predIdx(id domain.ID) int {
	i := sort.Search(len(r.Nodes), func(i int) bool { return bytes.Compare(r.Nodes[i].ID, id) > 0 })
	return (i - 1 + len(r.Nodes)) % len(r.Nodes)
}

func (r *Ring) next(i int, by int) int { return (i + by) % len(r.Nodes) }

// ---- Chord ----

// ChordTables holds the finger table of every node: finger[i] =
// successor(id + 2^i) for i in [0, Bits), as fixFinger (chord/stabilization.go)
// converges to. The successor list is the next SuccListSize nodes.
type ChordTables struct {
	Ring    *Ring
	Fingers [][]*domain.Node
}

func BuildChord(r *Ring) *ChordTables {
	t := &ChordTables{Ring: r, Fingers: make([][]*domain.Node, r.N())}
	maxID := new(big.Int).Lsh(big.NewInt(1), uint(r.Sp.Bits))
	pow := make([]*big.Int, r.Sp.Bits)
	for i := range pow {
		pow[i] = new(big.Int).Lsh(big.NewInt(1), uint(i))
	}
	for k, n := range r.Nodes {
		f := make([]*domain.Node, r.Sp.Bits)
		self := n.ID.ToBigInt()
		for i := range f {
			target := new(big.Int).Add(self, pow[i])
			target.Mod(target, maxID)
			f[i] = r.Nodes[r.succIdx(bigToID(r.Sp, target))]
		}
		t.Fingers[k] = f
	}
	return t
}

func bigToID(sp domain.Space, v *big.Int) domain.ID {
	id := make(domain.ID, sp.ByteLen)
	b := v.Bytes()
	copy(id[sp.ByteLen-len(b):], b)
	return id
}

// Result of one lookup.
type Result struct {
	Owner *domain.Node
	// RPCHops: node-to-node FindSuccessor calls (what lookuptrace.Counter counts).
	RPCHops int
	// Steps: logical routing steps = forwarding decisions, including Koorde's
	// de Bruijn steps to self that cost no RPC. For Chord, Steps == RPCHops.
	Steps int
	OK    bool
	// Fallback (Koorde): BestImaginary could not place the start node inside
	// (self, successor) and used BestImaginarySimple (start at self+1, all
	// Bits digits still to shift in).
	Fallback bool
	// SuccSteps (Koorde): how many of the Steps were successor steps (walking
	// the ring) rather than de Bruijn steps.
	SuccSteps int
}

// Lookup runs chord.NextHop from entry until the owner is found.
func (t *ChordTables) Lookup(entry int, key domain.ID) Result {
	r := t.Ring
	cur := entry
	res := Result{}
	limit := 2*r.N() + 100
	for steps := 0; steps < limit; steps++ {
		self := r.Nodes[cur]
		succ := r.Nodes[r.next(cur, 1)]
		closest := chord.ClosestPreceding(self, t.Fingers[cur], key)
		done, next := chord.NextHop(self, succ, closest, key)
		if done {
			res.Owner, res.OK = next, true
			return res
		}
		res.RPCHops++
		res.Steps++
		cur = r.idx[next]
	}
	return res
}

// ChordState returns, for node i, the number of finger slots plus successor
// slots and the number of distinct other nodes among them.
func (t *ChordTables) State(i, succListSize int) (slots, distinct int) {
	seen := map[*domain.Node]bool{}
	for _, f := range t.Fingers[i] {
		if f != t.Ring.Nodes[i] {
			seen[f] = true
		}
	}
	for j := 1; j <= succListSize; j++ {
		if s := t.Ring.Nodes[t.Ring.next(i, j)]; s != t.Ring.Nodes[i] {
			seen[s] = true
		}
	}
	return len(t.Fingers[i]) + succListSize, len(seen)
}

// ---- Koorde ----

// KoordeTables holds each node's de Bruijn window.
type KoordeTables struct {
	Ring   *Ring
	Window [][]*domain.Node
}

// settledBits recomputes how many low bits BestImaginary wrote into currentI
// (0 when it fell back to BestImaginarySimple, i.e. start at self+1 and use all
// Bits shifts). Used only to tell the two start cases apart in the statistics.
func settledBits(sp *domain.Space, self, succ, target, currentI domain.ID) int {
	maxID := new(big.Int).Lsh(big.NewInt(1), uint(sp.Bits))
	region := new(big.Int).Sub(succ.ToBigInt(), self.ToBigInt())
	if region.Sign() <= 0 {
		region.Add(region, maxID)
	}
	s := region.BitLen() - 2
	if s < 0 {
		s = 0
	}
	if s > sp.Bits {
		s = sp.Bits
	}
	top := new(big.Int).Rsh(target.ToBigInt(), uint(sp.Bits-s))
	maskLow := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), uint(s)), big.NewInt(1))
	maskHigh := new(big.Int).Xor(new(big.Int).Sub(maxID, big.NewInt(1)), maskLow)
	cand := new(big.Int).And(self.ToBigInt(), maskHigh)
	cand.Or(cand, top)
	if cand.Cmp(currentI.ToBigInt()) == 0 {
		return s
	}
	return 0
}

func BuildKoorde(r *Ring, mode WindowMode) (*KoordeTables, error) {
	k := r.Sp.GraphGrade
	t := &KoordeTables{Ring: r, Window: make([][]*domain.Node, r.N())}
	for i, n := range r.Nodes {
		var anchor int
		switch mode {
		case WindowTextbook:
			km, err := r.Sp.MulKMod(n.ID)
			if err != nil {
				return nil, err
			}
			anchor = r.predIdx(km)
		default:
			estN := r.N()
			if mode == WindowRealistic {
				estN = logicnode.EstimateSizeFromGap(&r.Sp, n, r.Nodes[r.next(i, 1)])
			}
			target, err := r.Sp.ComputeFaultTolerantTarget(n.ID, estN)
			if err != nil {
				return nil, err
			}
			// fixDeBruijn: succ = FindSuccessor(target); anchor = predecessor(succ).
			anchor = r.next(r.succIdx(target), -1+r.N())
		}
		w := make([]*domain.Node, k)
		for j := 0; j < k; j++ {
			w[j] = r.Nodes[r.next(anchor, j)]
		}
		t.Window[i] = w
	}
	return t, nil
}

// Lookup runs logicnode.InitStep and DecideStep from entry. At every step the
// first candidate of the plan is taken (all nodes are alive, so the first one
// always answers), as the node code does when no call fails.
func (t *KoordeTables) Lookup(entry int, key domain.ID) (Result, error) {
	r := t.Ring
	sp := &r.Sp
	cur := entry
	res := Result{}
	self := r.Nodes[cur]
	succ := r.Nodes[r.next(cur, 1)]
	done, currentI, kshift, err := logicnode.InitStep(sp, self, succ, key)
	if err != nil {
		return res, err
	}
	if done {
		res.Owner, res.OK = succ, true
		return res, nil
	}
	res.Fallback = settledBits(sp, self.ID, succ.ID, key, currentI) == 0
	limit := 4*r.N() + 1000
	for steps := 0; steps < limit; steps++ {
		self = r.Nodes[cur]
		succ = r.Nodes[r.next(cur, 1)]
		plan, err := logicnode.DecideStep(sp, self, succ, t.Window[cur], key, currentI, kshift)
		if err != nil {
			return res, err
		}
		switch plan.Action {
		case logicnode.StepReturn:
			res.Owner, res.OK = plan.Successor, true
			return res, nil
		case logicnode.StepDeBruijn:
			res.Steps++
			currentI, kshift = plan.NextI, plan.NextKshift
			if len(plan.DeBruijn) > 0 {
				d := plan.DeBruijn[0]
				if d != self { // d == self: local step, no RPC
					res.RPCHops++
					cur = r.idx[d]
				}
				continue
			}
			// empty window: fall back to the successor
			res.SuccSteps++
			res.RPCHops++
			cur = r.next(cur, 1)
		case logicnode.StepSuccessor:
			res.Steps++
			res.SuccSteps++
			res.RPCHops++
			currentI, kshift = plan.NextI, plan.NextKshift
			cur = r.next(cur, 1)
		}
	}
	return res, fmt.Errorf("lookup did not finish within %d steps", limit)
}

// State returns window slots + successor slots and the distinct other nodes among them.
func (t *KoordeTables) State(i, succListSize int) (slots, distinct int) {
	seen := map[*domain.Node]bool{}
	for _, d := range t.Window[i] {
		if d != t.Ring.Nodes[i] {
			seen[d] = true
		}
	}
	for j := 1; j <= succListSize; j++ {
		if s := t.Ring.Nodes[t.Ring.next(i, j)]; s != t.Ring.Nodes[i] {
			seen[s] = true
		}
	}
	return len(t.Window[i]) + succListSize, len(seen)
}
