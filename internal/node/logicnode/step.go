package logicnode

import (
	"KoordeDHT/internal/domain"
	"errors"
)

// This file holds Koorde's routing decision as pure functions (no RPC, no
// logging, no node state), so that the node code and the hop-count simulator
// (cmd/hopsim) run exactly the same logic.

// StepAction says what a node does with a lookup step.
type StepAction int

const (
	// StepReturn: the target is in (self, successor]; the answer is Plan.Successor.
	StepReturn StepAction = iota
	// StepDeBruijn: currentI is in (self, successor]; advance the imaginary node
	// and forward to one of Plan.DeBruijn (tried in order), falling back to the
	// successor if none works.
	StepDeBruijn
	// StepSuccessor: this node is not the predecessor of currentI; forward to
	// the successor with the unchanged state.
	StepSuccessor
)

// StepPlan is the outcome of DecideStep.
type StepPlan struct {
	Action    StepAction
	Successor *domain.Node // the node's first successor (the answer for StepReturn)

	// NextI and NextKshift are the lookup state to send to the next node, for
	// StepDeBruijn and for the successor fallback after it. For StepSuccessor
	// they equal the incoming state.
	NextI, NextKshift domain.ID

	// DeBruijn lists the non-nil candidates for the de Bruijn hop in the order
	// in which they are tried: from the window entry chosen by findNextHop
	// down to index 0 (or from the last entry down if findNextHop found none).
	DeBruijn []*domain.Node
}

// StepError carries the message that the RPC layer returns to the caller
// (Public) and the underlying cause (Err).
type StepError struct {
	Public string
	Err    error
}

func (e *StepError) Error() string { return e.Public + ": " + e.Err.Error() }
func (e *StepError) Unwrap() error { return e.Err }

// ErrNextIEqualsCurrentI is returned when the imaginary node does not advance.
var ErrNextIEqualsCurrentI = errors.New("nextI equals currentI, potential infinite loop")

// InitStep is the pure part of FindSuccessorInit: if target is in (self,
// succ] it returns succ as the answer (done = true); otherwise it returns the
// initial imaginary node and shifted target for the first Step.
func InitStep(sp *domain.Space, self, succ *domain.Node, target domain.ID) (done bool, currentI, kshift domain.ID, err error) {
	if target.Between(self.ID, succ.ID) {
		return true, nil, nil, nil
	}
	currentI, kshift, err = sp.BestImaginary(self.ID, succ.ID, target)
	if err != nil {
		return false, nil, nil, &StepError{Public: "failed to compute initial currentI and kshift", Err: err}
	}
	return false, currentI, kshift, nil
}

// DecideStep is the pure part of FindSuccessorStep for a node `self` with
// first successor `succ` and de Bruijn window `window` (non-nil entries, in
// window order), given the lookup state (target, currentI, kshift).
func DecideStep(sp *domain.Space, self, succ *domain.Node, window []*domain.Node, target, currentI, kshift domain.ID) (StepPlan, error) {
	plan := StepPlan{Successor: succ}

	// Target in (self, successor]: the lookup ends here.
	if target.Between(self.ID, succ.ID) {
		plan.Action = StepReturn
		return plan, nil
	}

	// Not the predecessor of currentI: walk along the ring.
	if !currentI.Between(self.ID, succ.ID) {
		plan.Action = StepSuccessor
		plan.NextI, plan.NextKshift = currentI, kshift
		return plan, nil
	}

	// currentI is in (self, successor]: de Bruijn step.
	plan.Action = StepDeBruijn
	nextDigit, nextKshift, err := sp.NextDigitBaseK(kshift)
	if err != nil {
		return plan, &StepError{Public: "failed to compute next digit and kshift", Err: err}
	}
	nextI, err := sp.MulKMod(currentI)
	if err != nil {
		return plan, &StepError{Public: "failed to compute nextI", Err: err}
	}
	nextI, err = sp.AddMod(nextI, sp.FromUint64(nextDigit))
	if err != nil {
		return plan, &StepError{Public: "failed to compute nextI", Err: err}
	}
	plan.NextI, plan.NextKshift = nextI, nextKshift

	if len(window) > 0 {
		if nextI.Equal(currentI) {
			return plan, &StepError{Public: ErrNextIEqualsCurrentI.Error(), Err: ErrNextIEqualsCurrentI}
		}
		startIdx := findNextHop(window, nextI)
		if startIdx < 0 {
			// findNextHop found no interval: try all entries as fallback.
			startIdx = len(window) - 1
		}
		for i := startIdx; i >= 0; i-- {
			if window[i] != nil {
				plan.DeBruijn = append(plan.DeBruijn, window[i])
			}
		}
	}
	return plan, nil
}
