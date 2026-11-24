package main

// Validation gate: the simulator must reproduce, exactly, the hop counts that
// the in-process gRPC tests (internal/node/server/hops_test.go) measure on the
// 8-node, 8-bit ring at IDs 0,32,...,224 with textbook routing tables. Those
// numbers were worked out by hand there; this test checks the simulator
// (which calls the same pure routing functions as the nodes) against them.
// Only after this passes may large rings be simulated.

import (
	"KoordeDHT/internal/domain"
	"testing"
)

func ring8(t *testing.T, k int) *Ring {
	t.Helper()
	sp, err := domain.NewSpace(8, k, 3)
	if err != nil {
		t.Fatal(err)
	}
	var ids []domain.ID
	for id := 0; id < 256; id += 32 {
		ids = append(ids, sp.FromUint64(uint64(id)))
	}
	return NewRing(sp, ids)
}

func idx(r *Ring, id int) int { return r.succIdx(r.Sp.FromUint64(uint64(id))) }

type vcase struct{ entry, key, owner, rpc, steps int }

func TestValidateAgainstPhase1Chord(t *testing.T) {
	r := ring8(t, 2)
	tb := BuildChord(r)
	// entry, key, owner, RPC hops (phase 1: 0,1,1,2,3,2); for Chord steps == RPC hops.
	for _, c := range []vcase{
		{0, 20, 32, 0, 0}, {0, 33, 64, 1, 1}, {0, 130, 160, 1, 1},
		{0, 200, 224, 2, 2}, {0, 255, 0, 3, 3}, {96, 20, 32, 2, 2},
	} {
		got := tb.Lookup(idx(r, c.entry), r.Sp.FromUint64(uint64(c.key)))
		if !got.OK || int(got.Owner.ID[0]) != c.owner || got.RPCHops != c.rpc || got.Steps != c.steps {
			t.Errorf("chord entry=%d key=%d: owner=%d rpc=%d steps=%d ok=%v, want owner=%d rpc=%d steps=%d",
				c.entry, c.key, got.Owner.ID[0], got.RPCHops, got.Steps, got.OK, c.owner, c.rpc, c.steps)
		}
	}
}

func TestValidateAgainstPhase1Koorde(t *testing.T) {
	// k=2: phase 1 RPC hops 0,3,1. Logical steps additionally count the local
	// de Bruijn steps to self: key 200 has 1 (steps 4), key 33 has 3 (steps 4).
	// k=4: phase 1 RPC hops 0,2; no local steps.
	for k, cases := range map[int][]vcase{
		2: {{0, 20, 32, 0, 0}, {0, 200, 224, 3, 4}, {0, 33, 64, 1, 4}},
		4: {{0, 20, 32, 0, 0}, {0, 200, 224, 2, 2}},
	} {
		r := ring8(t, k)
		tb, err := BuildKoorde(r, WindowTextbook)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range cases {
			got, err := tb.Lookup(idx(r, c.entry), r.Sp.FromUint64(uint64(c.key)))
			if err != nil || !got.OK || int(got.Owner.ID[0]) != c.owner || got.RPCHops != c.rpc || got.Steps != c.steps {
				t.Errorf("koorde k=%d entry=%d key=%d: owner=%v rpc=%d steps=%d err=%v, want owner=%d rpc=%d steps=%d",
					k, c.entry, c.key, got.Owner, got.RPCHops, got.Steps, err, c.owner, c.rpc, c.steps)
			}
		}
	}
}

// The realistic window follows fixDeBruijn. On the same ring, node 0, k=2:
// the successor gap is 32, so the estimate is 2^8/32 = 8; log = bits.Len(8) = 4;
// x = 256*4/8 = 128; target = 2*0 - 128 mod 256 = 128; successor(128) = 128;
// anchor = its predecessor = 96; window = [96, 128] (anchor, then anchor's successor).
func TestRealisticWindowHandDerived(t *testing.T) {
	r := ring8(t, 2)
	tb, err := BuildKoorde(r, WindowRealistic)
	if err != nil {
		t.Fatal(err)
	}
	w := tb.Window[idx(r, 0)]
	if len(w) != 2 || w[0].ID[0] != 96 || w[1].ID[0] != 128 {
		t.Errorf("window of node 0 = %v, want [96 128]", []byte{w[0].ID[0], w[1].ID[0]})
	}
}

// Every lookup in a randomly built ring ends at the true owner, for all window modes.
func TestRandomRingsFindTheOwner(t *testing.T) {
	cfg := Config{IDBits: 66, SuccListSize: 8, Seed: 7, Lookups: 300}
	for _, k := range []int{2, 4, 8} {
		for _, mode := range []WindowMode{WindowRealistic, WindowTrueN, WindowTextbook} {
			pt, err := RunPoint(cfg, "koorde", k, 500, mode)
			if err != nil {
				t.Fatal(err)
			}
			if pt.Failures != 0 || pt.WrongOwner != 0 {
				t.Errorf("koorde k=%d %v: failures=%d wrong=%d", k, mode, pt.Failures, pt.WrongOwner)
			}
		}
	}
	pt, err := RunPoint(cfg, "chord", 0, 500, WindowRealistic)
	if err != nil || pt.Failures != 0 || pt.WrongOwner != 0 {
		t.Errorf("chord: %+v %v", pt, err)
	}
}

// Degree 16 runs with 64 bits (the repo's config check needs idBits to be a
// multiple of log2(degree)) and must also find the owner.
func TestDegree16FindsTheOwner(t *testing.T) {
	cfg := Config{IDBits: 66, SuccListSize: 8, Seed: 3, Lookups: 300}
	for _, k := range []int{2, 4, 8, 16} {
		pt, err := RunPoint(cfg, "koorde", k, 1000, WindowTrueN)
		if err != nil || pt.Failures != 0 || pt.WrongOwner != 0 {
			t.Errorf("k=%d: failures=%d wrong=%d err=%v", k, pt.Failures, pt.WrongOwner, err)
		}
	}
}
