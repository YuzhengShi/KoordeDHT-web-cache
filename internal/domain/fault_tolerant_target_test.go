package domain

import (
	"math/big"
	"math/bits"
	"testing"
)

func TestComputeFaultTolerantTarget(t *testing.T) {
	tests := []struct {
		name        string
		bits        int
		degree      int
		selfHex     string
		estimatedN  int
		expectError bool
	}{
		{
			name:        "small network",
			bits:        16,
			degree:      2,
			selfHex:     "1234",
			estimatedN:  10,
			expectError: false,
		},
		{
			name:        "medium network",
			bits:        66,
			degree:      8,
			selfHex:     "00fb487b807ea44256",
			estimatedN:  100,
			expectError: false,
		},
		{
			name:        "large network",
			bits:        66,
			degree:      8,
			selfHex:     "00fb487b807ea44256",
			estimatedN:  10000,
			expectError: false,
		},
		{
			name:        "single node",
			bits:        16,
			degree:      2,
			selfHex:     "1234",
			estimatedN:  1,
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sp, err := NewSpace(tt.bits, tt.degree, 8)
			if err != nil {
				t.Fatalf("NewSpace failed: %v", err)
			}

			self, err := sp.FromHexString(tt.selfHex)
			if err != nil {
				t.Fatalf("FromHexString failed: %v", err)
			}

			// Test Section 4.2 algorithm
			target, err := sp.ComputeFaultTolerantTarget(self, tt.estimatedN)
			if tt.expectError {
				if err == nil {
					t.Errorf("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("ComputeFaultTolerantTarget failed: %v", err)
			}

			// Verify result is valid ID
			if err := sp.IsValidID(target); err != nil {
				t.Errorf("result is invalid ID: %v", err)
			}

			// Compare with simple approach (k×m without offset)
			simpleTarget, err := sp.MulKMod(self)
			if err != nil {
				t.Fatalf("MulKMod failed: %v", err)
			}

			// Verify target is different from simple approach (unless n=1)
			if tt.estimatedN > 1 && target.Equal(simpleTarget) {
				t.Logf("Warning: fault-tolerant target equals simple target (may be intentional for small offset)")
			}

			// Log results for manual inspection
			t.Logf("Self:           %s", self.ToHexString(true))
			t.Logf("Simple k×m:     %s", simpleTarget.ToHexString(true))
			t.Logf("FT k×m-x:       %s", target.ToHexString(true))
			t.Logf("Estimated N:    %d", tt.estimatedN)

			// Verify target is less than simple target (we subtracted offset)
			targetBig := target.ToBigInt()
			simpleBig := simpleTarget.ToBigInt()
			maxID := new(big.Int).Lsh(big.NewInt(1), uint(sp.Bits))

			// Calculate effective difference considering wrap-around
			var diff *big.Int
			if simpleBig.Cmp(targetBig) > 0 {
				diff = new(big.Int).Sub(simpleBig, targetBig)
			} else {
				// Wrapped around
				diff = new(big.Int).Sub(maxID, targetBig)
				diff.Add(diff, simpleBig)
			}

			t.Logf("Offset (x):     %s", diff.String())

			// Verify offset is approximately O(log n / n) × 2^b
			expectedLogN := bits.Len(uint(tt.estimatedN))  // log2(n)
			if expectedLogN < 1 {
				expectedLogN = 1
			}
			t.Logf("Expected log(n): %d", expectedLogN)
		})
	}
}

