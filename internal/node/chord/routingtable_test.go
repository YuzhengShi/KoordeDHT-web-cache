package chord

import (
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	"testing"
)

func TestNewRoutingTable(t *testing.T) {
	space := domain.Space{
		Bits:         8,
		ByteLen:      1,
		GraphGrade:   2,
		SuccListSize: 3,
	}

	selfNode := &domain.Node{
		ID:   domain.ID{0x80},
		Addr: "127.0.0.1:4000",
	}

	rt := NewRoutingTable(selfNode, space, &logger.NopLogger{})

	if rt == nil {
		t.Fatal("NewRoutingTable returned nil")
	}

	if rt.Self() != selfNode {
		t.Errorf("Self() returned %v, expected %v", rt.Self(), selfNode)
	}

	if rt.Space().Bits != 8 {
		t.Errorf("Space().Bits = %d, expected 8", rt.Space().Bits)
	}
}

func TestSetAndGetSuccessor(t *testing.T) {
	space := domain.Space{
		Bits:         8,
		ByteLen:      1,
		GraphGrade:   2,
		SuccListSize: 3,
	}

	selfNode := &domain.Node{
		ID:   domain.ID{0x80},
		Addr: "127.0.0.1:4000",
	}

	rt := NewRoutingTable(selfNode, space, &logger.NopLogger{})

	// Set successor
	succ := &domain.Node{
		ID:   domain.ID{0x90},
		Addr: "127.0.0.1:4001",
	}

	rt.SetSuccessor(0, succ)

	// Verify FirstSuccessor
	first := rt.FirstSuccessor()
	if first == nil {
		t.Fatal("FirstSuccessor() returned nil")
	}
	if !first.ID.Equal(succ.ID) {
		t.Errorf("FirstSuccessor() ID = %v, expected %v", first.ID, succ.ID)
	}

	// Verify SuccessorList contains it
	list := rt.SuccessorList()
	if len(list) == 0 {
		t.Fatal("SuccessorList() is empty")
	}
	if !list[0].ID.Equal(succ.ID) {
		t.Errorf("SuccessorList()[0] ID = %v, expected %v", list[0].ID, succ.ID)
	}
}

func TestSetAndGetPredecessor(t *testing.T) {
	space := domain.Space{
		Bits:         8,
		ByteLen:      1,
		GraphGrade:   2,
		SuccListSize: 3,
	}

	selfNode := &domain.Node{
		ID:   domain.ID{0x80},
		Addr: "127.0.0.1:4000",
	}

	rt := NewRoutingTable(selfNode, space, &logger.NopLogger{})

	// Initially nil
	if pred := rt.GetPredecessor(); pred != nil {
		t.Errorf("Initial predecessor should be nil, got %v", pred)
	}

	// Set predecessor
	pred := &domain.Node{
		ID:   domain.ID{0x70},
		Addr: "127.0.0.1:3999",
	}

	rt.SetPredecessor(pred)

	// Verify
	result := rt.GetPredecessor()
	if result == nil {
		t.Fatal("GetPredecessor() returned nil after SetPredecessor")
	}
	if !result.ID.Equal(pred.ID) {
		t.Errorf("GetPredecessor() ID = %v, expected %v", result.ID, pred.ID)
	}
}

func TestClosestPrecedingNode(t *testing.T) {
	space := domain.Space{
		Bits:         8,
		ByteLen:      1,
		GraphGrade:   2,
		SuccListSize: 3,
	}

	selfNode := &domain.Node{
		ID:   domain.ID{0x80}, // 128
		Addr: "127.0.0.1:4000",
	}

	rt := NewRoutingTable(selfNode, space, &logger.NopLogger{})

	// Set up finger table with some entries
	// Finger 0: n + 2^0 = 128 + 1 = 129 -> node at 130
	finger0 := &domain.Node{
		ID:   domain.ID{0x82}, // 130
		Addr: "127.0.0.1:4002",
	}
	rt.SetFinger(0, finger0)

	// Finger 2: n + 2^2 = 128 + 4 = 132 -> node at 140
	finger2 := &domain.Node{
		ID:   domain.ID{0x8C}, // 140
		Addr: "127.0.0.1:4004",
	}
	rt.SetFinger(2, finger2)

	// Finger 4: n + 2^4 = 128 + 16 = 144 -> node at 150
	finger4 := &domain.Node{
		ID:   domain.ID{0x96}, // 150
		Addr: "127.0.0.1:4006",
	}
	rt.SetFinger(4, finger4)

	// Test: Find closest preceding node for ID 145
	targetID := domain.ID{0x91} // 145

	result := rt.ClosestPrecedingNode(targetID)

	// Should return finger2 (140) as it's the closest preceding node to 145
	if result == nil {
		t.Fatal("ClosestPrecedingNode returned nil")
	}

	// The closest preceding node should be finger2 (140) since:
	// - self (128) < finger0 (130) < finger2 (140) < target (145) < finger4 (150)
	if !result.ID.Equal(finger2.ID) {
		t.Errorf("ClosestPrecedingNode(145) = %v (%d), expected finger2 %v (%d)",
			result.ID, result.ID[0], finger2.ID, finger2.ID[0])
	}
}

func TestFingerTable(t *testing.T) {
	space := domain.Space{
		Bits:         8,
		ByteLen:      1,
		GraphGrade:   2,
		SuccListSize: 3,
	}

	selfNode := &domain.Node{
		ID:   domain.ID{0x00},
		Addr: "127.0.0.1:4000",
	}

	rt := NewRoutingTable(selfNode, space, &logger.NopLogger{})

	// Set multiple fingers
	for i := 0; i < 8; i++ {
		finger := &domain.Node{
			ID:   domain.ID{byte(1 << i)},
			Addr: "127.0.0.1:4000",
		}
		rt.SetFinger(i, finger)
	}

	// Verify fingers
	for i := 0; i < 8; i++ {
		finger := rt.GetFinger(i)
		if finger == nil {
			t.Errorf("GetFinger(%d) returned nil", i)
			continue
		}
		expected := byte(1 << i)
		if finger.ID[0] != expected {
			t.Errorf("GetFinger(%d) ID = %d, expected %d", i, finger.ID[0], expected)
		}
	}
}
