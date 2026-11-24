// Command hopsim counts lookup hops of Chord and Koorde on simulated stabilised
// rings of up to 100,000 nodes. See docs/hop-count-study.md for the method and
// the results, and sim.go for what is modelled.
//
//	go run ./cmd/hopsim -out results/hopsim
package main

import (
	"KoordeDHT/internal/domain"
	"encoding/csv"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Config holds the parameters that are fixed for a whole run.
type Config struct {
	IDBits       int   // identifier bits (repo config: dht.idBits = 66)
	SuccListSize int   // successor list size (repo config: successorListSize = 8)
	Seed         int64 // seed for node IDs, entries and keys
	Lookups      int   // random (entry, key) lookups per point
}

// Stats summarises a series of integers.
type Stats struct {
	Mean, Median, P99 float64
	Max               int
}

func summarise(v []int) Stats {
	if len(v) == 0 {
		return Stats{}
	}
	s := append([]int(nil), v...)
	sort.Ints(s)
	sum := 0
	for _, x := range s {
		sum += x
	}
	q := func(p float64) float64 { // nearest-rank percentile
		i := int(math.Ceil(p*float64(len(s)))) - 1
		if i < 0 {
			i = 0
		}
		return float64(s[i])
	}
	return Stats{Mean: float64(sum) / float64(len(s)), Median: q(0.5), P99: q(0.99), Max: s[len(s)-1]}
}

// Point is one row of results.csv.
type Point struct {
	Variant    string // chord, koorde-k2, ..., koorde-klog
	Protocol   string
	K          int
	N          int
	Window     WindowMode
	Cfg        Config
	Failures   int // lookups that did not finish (not in the statistics)
	WrongOwner int // lookups that finished at a node other than successor(key)
	RPC, Steps Stats
	// Koorde only: share of lookups whose start fell back to
	// BestImaginarySimple, and the mean RPC hops of the two groups.
	FallbackFrac, RPCMeanFallback, RPCMeanNoFallback float64
	SuccStepsMean                                    float64 // Koorde: mean successor steps per lookup
	StateSlots                                       float64 // mean slots (fingers or de Bruijn window, plus successor list)
	StateDist                                        float64 // mean distinct other nodes among them
	Seconds                                          float64
}

// stateSample is the number of nodes over which state per node is averaged.
const stateSample = 2000

// RunPoint builds a ring of n random nodes and runs cfg.Lookups random
// lookups. The ring and the (entry, key) pairs depend only on (Seed, n), so
// all protocols at one n see the same ring and the same lookups.
func RunPoint(cfg Config, proto string, k, n int, mode WindowMode) (Point, error) {
	begin := time.Now()
	deg, succ := k, cfg.SuccListSize
	if proto == "chord" {
		deg = 2 // unused by Chord
	}
	if succ < deg {
		succ = deg // a degree above the successor list size needs a longer list
	}
	bits := cfg.IDBits
	if deg > 8 {
		// The repo's config check requires degree <= successorListSize and
		// idBits % log2(degree) == 0; 66 bits is not a multiple of 4, so the
		// degree-16 rows use 64 bits (recorded in the id_bits column).
		bits = 64
	}
	sp, err := domain.NewSpace(bits, deg, succ)
	if err != nil {
		return Point{}, err
	}
	ringRng := rand.New(rand.NewSource(cfg.Seed*1000003 + int64(n)))
	ring := NewRing(sp, RandomIDs(sp, n, ringRng))
	qRng := rand.New(rand.NewSource(cfg.Seed*1000033 + int64(n)))

	pt := Point{Protocol: proto, K: k, N: n, Window: mode, Cfg: cfg}
	pt.Cfg.SuccListSize = succ
	pt.Cfg.IDBits = bits
	var run func(entry int, key domain.ID) (Result, error)
	var state func(i int) (int, int)
	switch proto {
	case "chord":
		pt.Variant = "chord"
		t := BuildChord(ring)
		run = func(e int, key domain.ID) (Result, error) { return t.Lookup(e, key), nil }
		state = func(i int) (int, int) { return t.State(i, succ) }
	case "koorde":
		pt.Variant = fmt.Sprintf("koorde-k%d", k)
		t, err := BuildKoorde(ring, mode)
		if err != nil {
			return pt, err
		}
		run = t.Lookup
		state = func(i int) (int, int) { return t.State(i, succ) }
	default:
		return pt, fmt.Errorf("unknown protocol %q", proto)
	}

	rpc := make([]int, 0, cfg.Lookups)
	steps := make([]int, 0, cfg.Lookups)
	var nFb, sumFb, sumNo, sumSucc int
	for q := 0; q < cfg.Lookups; q++ {
		entry := qRng.Intn(n)
		key := randomID(sp, qRng)
		res, err := run(entry, key)
		if err != nil || !res.OK {
			pt.Failures++
			continue
		}
		if res.Owner != ring.Nodes[ring.succIdx(key)] {
			pt.WrongOwner++
		}
		if res.Fallback {
			nFb++
			sumFb += res.RPCHops
		} else {
			sumNo += res.RPCHops
		}
		sumSucc += res.SuccSteps
		rpc = append(rpc, res.RPCHops)
		steps = append(steps, res.Steps)
	}
	pt.RPC, pt.Steps = summarise(rpc), summarise(steps)
	if len(rpc) > 0 {
		pt.FallbackFrac = float64(nFb) / float64(len(rpc))
	}
	if len(rpc) > 0 {
		pt.SuccStepsMean = float64(sumSucc) / float64(len(rpc))
	}
	if nFb > 0 {
		pt.RPCMeanFallback = float64(sumFb) / float64(nFb)
	}
	if len(rpc)-nFb > 0 {
		pt.RPCMeanNoFallback = float64(sumNo) / float64(len(rpc)-nFb)
	}

	m := n
	if m > stateSample {
		m = stateSample
	}
	var sl, di float64
	for i := 0; i < m; i++ {
		a, b := state(i * n / m)
		sl += float64(a)
		di += float64(b)
	}
	pt.StateSlots, pt.StateDist = sl/float64(m), di/float64(m)
	pt.Seconds = time.Since(begin).Seconds()
	return pt, nil
}

// nearestPow2OfLog2 returns the power of two nearest (in log scale) to log2 n.
func nearestPow2OfLog2(n int) int {
	l := math.Log2(float64(n))
	best, bd := 2, math.Inf(1)
	for p := 2; p <= 64; p *= 2 {
		if d := math.Abs(math.Log2(float64(p)) - math.Log2(l)); d < bd {
			best, bd = p, d
		}
	}
	return best
}

// kSet returns the degrees to run at ring size n: 2, 4, 8 and the power of two
// nearest log2 n.
func kSet(n int) []int {
	ks := []int{2, 4, 8}
	if k := nearestPow2OfLog2(n); k > 8 {
		ks = append(ks, k)
	}
	return ks
}

func main() {
	out := flag.String("out", "results/hopsim", "output directory")
	seed := flag.Int64("seed", 1, "seed for node IDs, entries and keys")
	lookups := flag.Int("lookups", 10000, "random lookups per point")
	idBits := flag.Int("idbits", 66, "identifier bits (repo config default: 66)")
	succ := flag.Int("succ", 8, "successor list size (repo config default: 8)")
	sizesFlag := flag.String("sizes", "8,16,32,64,128,256,512,1024,2048,4096,8192,16384,32768,65536,100000", "ring sizes")
	trueNFlag := flag.String("truen-sizes", "1024,16384,65536", "ring sizes for the trueN sensitivity runs")
	workers := flag.Int("workers", runtime.NumCPU(), "parallel points")
	flag.Parse()

	cfg := Config{IDBits: *idBits, SuccListSize: *succ, Seed: *seed, Lookups: *lookups}
	sizes := parseInts(*sizesFlag)
	trueN := parseInts(*trueNFlag)

	type job struct {
		proto string
		k, n  int
		mode  WindowMode
	}
	var jobs []job
	for _, n := range sizes {
		jobs = append(jobs, job{"chord", 0, n, WindowRealistic})
		for _, k := range kSet(n) {
			jobs = append(jobs, job{"koorde", k, n, WindowRealistic})
		}
	}
	for _, n := range trueN {
		for _, k := range kSet(n) {
			jobs = append(jobs, job{"koorde", k, n, WindowTrueN})
			jobs = append(jobs, job{"koorde", k, n, WindowTextbook})
		}
	}
	// biggest rings first, so the workers stay busy to the end
	sort.SliceStable(jobs, func(i, j int) bool { return jobs[i].n > jobs[j].n })

	start := time.Now()
	results := make([]Point, len(jobs))
	var wg sync.WaitGroup
	ch := make(chan int)
	var mu sync.Mutex
	for w := 0; w < *workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range ch {
				j := jobs[i]
				pt, err := RunPoint(cfg, j.proto, j.k, j.n, j.mode)
				if err != nil {
					fmt.Fprintln(os.Stderr, "error:", j, err)
					os.Exit(1)
				}
				results[i] = pt
				mu.Lock()
				fmt.Printf("%-12s N=%-6d %-9v rpc mean %.2f  steps mean %.2f  failures %d  wrong %d  %.1fs\n",
					pt.Variant, pt.N, pt.Window, pt.RPC.Mean, pt.Steps.Mean, pt.Failures, pt.WrongOwner, pt.Seconds)
				mu.Unlock()
			}
		}()
	}
	for i := range jobs {
		ch <- i
	}
	close(ch)
	wg.Wait()
	total := time.Since(start)
	fmt.Printf("total wall time %.1fs with %d workers\n", total.Seconds(), *workers)

	// The "k = nearest power of 2 to log2 N" rows repeat the run of that k.
	for _, p := range results {
		if p.Protocol == "koorde" && p.K == nearestPow2OfLog2(p.N) {
			c := p
			c.Variant = "koorde-klog"
			results = append(results, c)
		}
	}
	sort.SliceStable(results, func(i, j int) bool {
		a, b := results[i], results[j]
		if a.Window != b.Window {
			return a.Window < b.Window
		}
		if a.N != b.N {
			return a.N < b.N
		}
		return a.Variant < b.Variant
	})
	if err := os.MkdirAll(*out, 0o755); err != nil {
		panic(err)
	}
	must(writeCSV(filepath.Join(*out, "results.csv"), results))
	must(os.WriteFile(filepath.Join(*out, "hops.svg"), []byte(hopsSVG(results)), 0o644))
	must(os.WriteFile(filepath.Join(*out, "state.svg"), []byte(stateSVG(results)), 0o644))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func parseInts(s string) []int {
	var out []int
	for _, f := range strings.Split(s, ",") {
		if f = strings.TrimSpace(f); f != "" {
			v, err := strconv.Atoi(f)
			must(err)
			out = append(out, v)
		}
	}
	return out
}

func writeCSV(path string, pts []Point) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	w := csv.NewWriter(f)
	w.Write([]string{"variant", "protocol", "k", "n", "log2_n", "window", "id_bits", "succ_list_size", "seed", "lookups",
		"failures", "wrong_owner",
		"rpc_hops_mean", "rpc_hops_median", "rpc_hops_p99", "rpc_hops_max",
		"steps_mean", "steps_median", "steps_p99", "steps_max",
		"steps_successor_mean", "start_fallback_frac", "rpc_mean_fallback_start", "rpc_mean_normal_start", "state_slots_mean", "state_distinct_mean", "seconds"})
	f2 := func(v float64) string { return strconv.FormatFloat(v, 'f', 3, 64) }
	for _, p := range pts {
		k := ""
		if p.Protocol == "koorde" {
			k = strconv.Itoa(p.K)
		}
		w.Write([]string{p.Variant, p.Protocol, k, strconv.Itoa(p.N), f2(math.Log2(float64(p.N))), p.Window.String(),
			strconv.Itoa(p.Cfg.IDBits), strconv.Itoa(p.Cfg.SuccListSize), strconv.FormatInt(p.Cfg.Seed, 10), strconv.Itoa(p.Cfg.Lookups),
			strconv.Itoa(p.Failures), strconv.Itoa(p.WrongOwner),
			f2(p.RPC.Mean), f2(p.RPC.Median), f2(p.RPC.P99), strconv.Itoa(p.RPC.Max),
			f2(p.Steps.Mean), f2(p.Steps.Median), f2(p.Steps.P99), strconv.Itoa(p.Steps.Max),
			f2(p.SuccStepsMean), f2(p.FallbackFrac), f2(p.RPCMeanFallback), f2(p.RPCMeanNoFallback), f2(p.StateSlots), f2(p.StateDist), f2(p.Seconds)})
	}
	w.Flush()
	return w.Error()
}
