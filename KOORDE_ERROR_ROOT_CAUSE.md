# Koorde Error Root Cause Analysis

## Problem Summary

**Koorde has a 65.2% error rate (652/1000 requests fail)** compared to Chord's 12.5% error rate (124/998 requests fail).

## Error Pattern Analysis

From `benchmark/results/koorde-results.csv`:

| URL ID | Total Requests | Errors | Success | Error Rate |
|--------|---------------|--------|---------|------------|
| 0      | 307           | 307    | 0       | **100.0%** |
| 1      | 182           | 0      | 182     | 0.0%       |
| 2      | 130           | 130    | 0       | **100.0%** |
| 3      | 91            | 0      | 91      | 0.0%       |
| 4      | 58            | 58     | 0       | **100.0%** |
| 5      | 75            | 0      | 75      | 0.0%       |
| 6      | 46            | 46     | 0       | **100.0%** |
| 7      | 41            | 41     | 0       | **100.0%** |
| 8      | 37            | 37     | 0       | **100.0%** |
| 9      | 33            | 33     | 0       | **100.0%** |

**Key Findings:**
- **Only URL IDs 1, 3, 5 work** (0% error rate)
- **All other URL IDs fail** (100% error rate)
- **Pattern**: Not simply even/odd - it's specific IDs that work

## Root Cause Hypothesis

The issue is **NOT** with the URL IDs themselves (which are just Zipf distribution indices), but with the **actual URL hash values** computed from the URLs.

### What Happens

1. **URL Hash Computation** (`internal/node/server/http.go:112`):
   ```go
   urlHash := s.node.Space().NewIdFromString(url)
   ```
   - Each URL is hashed using SHA-1 to generate a DHT key
   - The hash determines which node is responsible

2. **DHT Lookup** (`internal/node/server/http.go:133`):
   ```go
   responsible, err = s.node.LookUp(ctx, urlHash)
   ```
   - Calls `FindSuccessorInit` which uses Koorde's routing
   - If lookup fails or returns nil, the HTTP server returns 502 Bad Gateway

3. **Koorde Routing Failure**:
   - `FindSuccessorInit` → `BestImaginary` → `FindSuccessorStep`
   - For certain hash values, the routing fails:
     - `BestImaginary` may fail to construct a valid imaginary node
     - `FindSuccessorStep` may fail to find a valid next hop
     - `findNextHop` may return -1, causing routing to fail

### Why Specific URLs Fail

The URLs used in the benchmark are:
- URL 0: `https://httpbin.org/json`
- URL 1: `https://httpbin.org/html`
- URL 2: `https://httpbin.org/xml`
- URL 3: `https://httpbin.org/robots.txt`
- URL 4: `https://httpbin.org/deny`
- URL 5: `https://httpbin.org/status/200`
- URL 6: `https://httpbin.org/status/201`
- URL 7: `https://httpbin.org/status/202`
- URL 8: `https://httpbin.org/status/204`
- URL 9: `https://httpbin.org/bytes/1024`

**The hash values for URLs 0, 2, 4, 6, 7, 8, 9 likely fall into hash ranges where:**
1. `BestImaginary` cannot construct a valid imaginary node in the `[self, succ)` interval
2. The fallback to `BestImaginarySimple` still results in routing failure
3. `FindSuccessorStep` cannot find a valid de Bruijn neighbor for the computed `nextI`
4. All de Bruijn neighbors fail, and the successor fallback also fails

### Why Only URLs 1, 3, 5 Work

These URLs' hash values likely:
1. Fall into hash ranges where `BestImaginary` successfully constructs a valid imaginary node
2. Or the routing converges successfully even with `BestImaginarySimple`
3. The de Bruijn list has valid neighbors for these hash ranges

## Technical Details

### BestImaginary Logic (`internal/domain/identifier.go:490`)

The function:
1. Computes region size: `distance(self, succ)`
2. Estimates settable bits: `regionBits - safetyMargin`
3. Extracts top bits from target hash
4. Constructs `currentI` by combining self's high bits with target's top bits
5. **Validates** that `currentI ∈ [self, succ)`
6. If validation fails, falls back to `BestImaginarySimple`

**Potential Issue**: For certain hash values, the computed `currentI` may:
- Fall outside the `[self, succ)` interval
- Cause `FindSuccessorStep` to fail in finding a valid next hop
- Result in routing loops or dead ends

### FindSuccessorStep Logic (`internal/node/logicnode/operation.go:282`)

The function:
1. Checks if `target ∈ (self, succ]` → return successor
2. Checks if `currentI ∈ (self, succ]`:
   - If yes: Use de Bruijn routing
   - If no: Forward to successor
3. De Bruijn routing:
   - Computes `nextI` and `nextKshift`
   - Calls `findNextHop` to find de Bruijn neighbor
   - Tries all de Bruijn neighbors in reverse order
   - If all fail, falls back to successor

**Potential Issue**: For certain `nextI` values:
- `findNextHop` may return -1 (no valid interval found)
- All de Bruijn neighbors may fail (connection errors, timeouts)
- Successor fallback may also fail

## Why Chord Works Better

Chord's routing is simpler and more robust:
1. **Finger Table Routing**: Always has O(log n) fingers pointing to different parts of the ring
2. **Successor List**: Multiple backup successors for fault tolerance
3. **No Imaginary Nodes**: No complex arithmetic that can fail for specific hash values
4. **Proven Algorithm**: More mature and tested

Koorde's complexity (imaginary nodes, de Bruijn routing) makes it more susceptible to edge cases where:
- Hash values don't align well with the de Bruijn graph structure
- Imaginary node computation fails for certain intervals
- De Bruijn neighbors aren't properly maintained

## Fixes Applied

1. **Fixed `findNextHop` -1 bug**: Now iterates through all de Bruijn nodes if `findNextHop` returns -1
2. **Fixed infinite loop prevention**: Added `maxIterations` guard and `nonNilCount` check
3. **Protocol-specific fallbacks**: Koorde only uses Koorde routing (no Chord fallbacks)

## Remaining Issues

The fixes address the symptoms but may not fix the root cause:
- **Why does `BestImaginary` fail for certain hash values?**
- **Why does `FindSuccessorStep` fail even with the fixes?**
- **Are the de Bruijn neighbors properly maintained for all hash ranges?**

## Next Steps

1. **Add detailed logging** to `BestImaginary` and `FindSuccessorStep` to see exactly where routing fails
2. **Test with specific failing URLs** to understand the hash values
3. **Verify de Bruijn list maintenance** - are neighbors properly set for all hash ranges?
4. **Check if `BestImaginarySimple` fallback is working correctly**
5. **Re-run benchmark** after fixes to see if error rate improves

## Conclusion

The 65.2% error rate is caused by **systematic routing failures for specific URL hash values**. The fixes address some bugs in the routing logic, but the fundamental issue may be that Koorde's routing algorithm is failing for certain hash ranges due to:
- Invalid imaginary node computation
- Missing or invalid de Bruijn neighbors
- Edge cases in the routing logic

**Recommendation**: Re-run the benchmark with the fixes to verify if the error rate improves. If it doesn't, add detailed logging to identify exactly where routing fails for the problematic hash values.

