# DeBruijn List Routing Workflow Simulation

This document simulates how the DeBruijn list is used during routing in KoordeDHT.

## Overview

The DeBruijn list enables **O(logₖ n)** routing by allowing nodes to "jump" forward by a factor of k (degree) each hop, instead of following the ring step-by-step.

## Example Setup

Let's assume:
- **Degree k = 8** (base-8 de Bruijn graph)
- **Current Node**: `Node A` with ID `0x010000000000000000`
- **Target**: `0x050000000000000000` (we want to find the successor of this ID)

### Node A's Routing Table

```
Self:           0x010000000000000000 (Node A)
Successor:      0x020000000000000000 (Node B)
Predecessor:    0x0F0000000000000000 (Node Z)

DeBruijn List:
  [0] 0x023b95f96fa88e4f64 (localhost:4036)  ← Anchor
  [1] 0x026fb2d94d43e618ae (localhost:4033)  ← Anchor's 1st successor
  [2] 0x02771455b977873ee0 (localhost:4038)  ← Anchor's 2nd successor
  [3] 0x027b6fb3a5978ed856 (localhost:4039)  ← Anchor's 3rd successor
  [4] 0x02a03dddee357bfb83 (localhost:4034)  ← Anchor's 4th successor
  [5] 0x02bb4d72ffe13efe5b (localhost:4029)  ← Anchor's 5th successor
  [6] 0x02f656bce70902cd6d (localhost:4013)  ← Anchor's 6th successor
  [7] 0x030d749da34ae2d592 (localhost:4027)  ← Anchor's 7th successor
```

---

## Routing Workflow: Step-by-Step

### **Step 1: Initial Lookup Request**

**Node A** receives: `FindSuccessor(target = 0x050000000000000000)`

```
┌─────────────────────────────────────────────────────────┐
│ FindSuccessorInit(target)                               │
│                                                         │
│ 1. Check: Is target in (self, successor]?               │
│    target = 0x0500...                                   │
│    self = 0x0100...                                     │
│    successor = 0x0200...                                │
│    → NO, target is beyond successor                     │
│                                                         │
│ 2. Compute initial imaginary node (currentI)            │
│    Using BestImaginary(self, succ, target)              │
│    → currentI = 0x0100... (starts at self)              │
│    → kshift = target shifted for base-k routing         │
│                                                         │
│ 3. Call FindSuccessorStep(target, currentI, kshift)     │
└─────────────────────────────────────────────────────────┘
```

---

### **Step 2: First Routing Decision (Node A)**

```
┌─────────────────────────────────────────────────────────┐
│ FindSuccessorStep(target, currentI, kshift)             │
│                                                         │
│ 1. Check: Is target in (self, successor]?               │
│    → NO, continue                                       │
│                                                         │
│ 2. Check: Is currentI in (self, successor]?             │
│    currentI = 0x0100...                                 │
│    self = 0x0100...                                     │
│    successor = 0x0200...                                │
│    → YES! currentI is in range                          │
│                                                         │
│ 3. Extract next digit from kshift:                      │
│    nextDigit = NextDigitBaseK(kshift)                   │
│    → nextDigit = 5 (extracted from target's bits)       │
│                                                         │
│ 4. Compute next imaginary node:                         │
│    nextI = (currentI × k) + nextDigit                   │
│    nextI = (0x0100... × 8) + 5                          │
│    nextI = 0x0800... + 5                                │
│    nextI = 0x0805...                                    │
│                                                         │
│ 5. Get DeBruijn list:                                   │
│    Bruijn = [node[0], node[1], ..., node[7]]            │
│                                                         │
│ 6. Find which DeBruijn node is predecessor of nextI:    │
│    findNextHop(Bruijn, nextI = 0x0805...)               │
│    → Scans list to find node where:                     │
│       node[i].ID < nextI < node[i+1].ID                 │
│    → Returns index = 2 (node[2] = 0x0277...)            │
│                                                         │
│ 7. Try forwarding to DeBruijn[2]:                       │
│    Forward to: localhost:4038 (node[2])                 │
│    With: FindSuccessorStep(target, nextI, nextKshift)   │
└─────────────────────────────────────────────────────────┘
```

**Visual Representation:**
```
Node A (0x0100...)
  │
  │ Extract digit 5, compute nextI = 0x0805...
  │
  │ DeBruijn List:
  │   [0] 0x023b... ─┐
  │   [1] 0x026f...  │
  │   [2] 0x0277... ←┘ (predecessor of 0x0805...)
  │   [3] 0x027b...
  │   ...
  │
  └─→ Forward to Node[2] at localhost:4038
```

---

### **Step 3: Second Hop (Node at localhost:4038)**

```
┌─────────────────────────────────────────────────────────┐
│ Node at localhost:4038 receives FindSuccessorStep       │
│                                                         │
│ Parameters:                                             │
│   target = 0x0500... (unchanged)                        │
│   currentI = 0x0805... (from previous hop)              │
│   kshift = nextKshift (shifted by log₂(k) bits)         │
│                                                         │
│ 1. Check: Is target in (self, successor]?               │
│    → NO, continue                                       │
│                                                         │
│ 2. Check: Is currentI in (self, successor]?             │
│    currentI = 0x0805...                                 │
│    self = 0x0277...                                     │
│    successor = 0x0278... (example)                      │
│    → NO, currentI is beyond successor                   │
│                                                         │
│ 3. Forward to successor (not using DeBruijn):           │
│    Forward to: successor node                           │
│    With: FindSuccessorStep(target, currentI, kshift)    │
│    (currentI and kshift unchanged)                      │
└─────────────────────────────────────────────────────────┘
```

**Note:** When `currentI` is NOT in (self, successor], the node forwards to its successor without using DeBruijn routing. This continues until we reach a node where `currentI` IS in range.

---

### **Step 4: Third Hop (Successor Chain)**

```
Node A → Node[2] → Successor Chain → Node C
                                    │
                                    │ Eventually reaches node where
                                    │ currentI (0x0805...) is in range
                                    │
                                    └─→ Node C: currentI ∈ (self, succ]
```

---

### **Step 5: DeBruijn Routing Resumes (Node C)**

```
┌─────────────────────────────────────────────────────────┐
│ Node C receives FindSuccessorStep                       │
│                                                         │
│ 1. Check: Is target in (self, successor]?               │
│    → NO, continue                                       │
│                                                         │
│ 2. Check: Is currentI in (self, successor]?             │
│    currentI = 0x0805...                                 │
│    self = 0x0800...                                     │
│    successor = 0x0810...                                │
│    → YES! currentI is in range                          │
│                                                         │
│ 3. Extract next digit:                                  │
│    nextDigit = NextDigitBaseK(kshift)                   │
│    → nextDigit = 0 (next bits from target)              │
│                                                         │
│ 4. Compute next imaginary node:                         │
│    nextI = (0x0805... × 8) + 0                          │
│    nextI = 0x4028...                                    │
│                                                         │
│ 5. Find DeBruijn node:                                  │
│    findNextHop(Bruijn, nextI = 0x4028...)               │
│    → Returns index = 4 (node[4])                        │
│                                                         │
│ 6. Forward to DeBruijn[4]:                              │
│    Forward to: node[4] at localhost:4034                │
└─────────────────────────────────────────────────────────┘
```

---

### **Step 6: Final Hop - Target Found**

```
┌─────────────────────────────────────────────────────────┐
│ Node D receives FindSuccessorStep                       │
│                                                         │
│ 1. Check: Is target in (self, successor]?               │
│    target = 0x0500...                                   │
│    self = 0x04FF...                                     │
│    successor = 0x0501...                                │
│    → YES! target ∈ (self, successor]                    │
│                                                         │
│ 2. RETURN successor (lookup complete!)                  │
│    → Return: Node with ID 0x0501...                     │
└─────────────────────────────────────────────────────────┘
```

---

## Key Concepts Illustrated

### 1. **Imaginary Node (currentI)**
- Represents a "virtual" position in the identifier space
- Updated each hop: `nextI = (currentI × k) + digit`
- Allows routing to "jump" forward by factor of k

### 2. **Digit Extraction**
- Each hop extracts `log₂(k)` bits from the target ID
- For k=8, extracts 3 bits (values 0-7)
- These digits guide which DeBruijn entry to use

### 3. **DeBruijn Selection (findNextHop)**
- Finds the DeBruijn node whose ID immediately precedes `nextI`
- Uses circular search: finds interval where `node[i] < nextI < node[i+1]`
- Provides fault tolerance: tries nodes in reverse order if one fails

### 4. **Fault Tolerance**
```go
// From the code (lines 260-292):
for i := index; i >= 0; i-- {
    d := Bruijn[i]
    if d == nil {
        continue
    }
    // Try forwarding to d
    // If fails, try previous candidate (i-1)
    // If all fail, fallback to successor
}
```

### 5. **Fallback Mechanism**
- If DeBruijn list is empty → use successor
- If all DeBruijn nodes fail → use successor
- If `currentI` not in range → forward to successor

---

## Complete Routing Path Example

```
Target: 0x050000000000000000

Hop 1: Node A (0x0100...)
  ├─ Extract digit: 5
  ├─ Compute nextI: 0x0805...
  ├─ Select DeBruijn[2]: 0x0277...
  └─→ Forward to Node[2]

Hop 2: Node[2] (0x0277...)
  ├─ currentI (0x0805...) NOT in range
  └─→ Forward to successor

Hop 3: Successor chain...
  └─→ Eventually reach Node C where currentI is in range

Hop 4: Node C (0x0800...)
  ├─ Extract digit: 0
  ├─ Compute nextI: 0x4028...
  ├─ Select DeBruijn[4]: 0x02a0...
  └─→ Forward to Node[4]

Hop 5: Node D (0x04FF...)
  ├─ Target (0x0500...) IS in (self, successor]
  └─→ RETURN successor (0x0501...)
```

**Total Hops:** ~O(log₈ n) instead of O(n) with simple successor following!

---

## Why This Works

1. **Base-k De Bruijn Graph**: Each node connects to k nodes, enabling k-way branching
2. **Digit-by-Digit Routing**: Target ID is processed digit-by-digit, matching the graph structure
3. **Imaginary Node Tracking**: `currentI` tracks progress through the virtual graph
4. **Fault Tolerance**: Multiple DeBruijn entries provide backup routes

This achieves **O(logₖ n)** routing complexity instead of **O(n)** with simple ring traversal!

