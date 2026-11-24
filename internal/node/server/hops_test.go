package server

// Deterministic hop-count tests.
//
// Eight nodes sit on an 8-bit ring at IDs 0, 32, 64, ..., 224 and talk to each
// other over real gRPC (the real server.New with its interceptors, the real
// client.Pool with its dial options) through in-memory bufconn listeners, so
// no port is opened. Routing tables are written by hand from the textbook
// definitions (no stabilisation), which makes every lookup path fixed and
// lets the expected hop count be worked out on paper. The comments of each
// case show the derivation.
//
// "Hop" means one FindSuccessor RPC between two nodes. A Koorde step that a
// node performs on itself (its de Bruijn pointer is itself) is not an RPC and
// is not counted; the cases say where that happens.

import (
	clientv1 "KoordeDHT/internal/api/client/v1"
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	"KoordeDHT/internal/node/cache"
	"KoordeDHT/internal/node/chord"
	"KoordeDHT/internal/node/client"
	"KoordeDHT/internal/node/dht"
	"KoordeDHT/internal/node/logicnode"
	"KoordeDHT/internal/node/routingtable"
	"KoordeDHT/internal/node/storage"
	"KoordeDHT/internal/node/telemetry/lookuptrace"
	"context"
	"encoding/csv"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/test/bufconn"
)

var ringIDs = []int{0, 32, 64, 96, 128, 160, 192, 224}

// ring is an in-process test network.
type ring struct {
	t       *testing.T
	space   domain.Space
	nodes   map[int]*domain.Node
	dht     map[int]dht.DHTNode
	lis     map[string]*bufconn.Listener // endpoint ("n32") -> listener
	servers []*Server

	mu     sync.Mutex
	depths []int // x-koorde-hop seen by FindSuccessor handlers, in arrival order
}

func (r *ring) addr(id int) string { return fmt.Sprintf("passthrough:///n%d", id) }

// succ returns the first ring ID >= x (circular): the textbook successor(x).
func succ(x int) int {
	x = ((x % 256) + 256) % 256
	for _, id := range ringIDs {
		if id >= x {
			return id
		}
	}
	return ringIDs[0]
}

// pred returns the last ring ID <= x (circular): predecessor(x) including x.
func pred(x int) int {
	x = ((x % 256) + 256) % 256
	for i := len(ringIDs) - 1; i >= 0; i-- {
		if ringIDs[i] <= x {
			return ringIDs[i]
		}
	}
	return ringIDs[len(ringIDs)-1]
}

// nextOnRing returns the ring ID that follows id.
func nextOnRing(id int) int { return succ(id + 1) }

func newRing(t *testing.T, protocol string, k int) *ring {
	t.Helper()
	sp, err := domain.NewSpace(8, k, 3)
	if err != nil {
		t.Fatal(err)
	}
	r := &ring{t: t, space: sp,
		nodes: map[int]*domain.Node{}, dht: map[int]dht.DHTNode{}, lis: map[string]*bufconn.Listener{}}
	for _, id := range ringIDs {
		r.nodes[id] = &domain.Node{ID: sp.FromUint64(uint64(id)), Addr: r.addr(id)}
		r.lis[fmt.Sprintf("n%d", id)] = bufconn.Listen(1 << 20)
	}
	dialer := grpc.WithContextDialer(func(ctx context.Context, endpoint string) (net.Conn, error) {
		return r.lis[endpoint].DialContext(ctx)
	})
	nop := &logger.NopLogger{}

	for _, id := range ringIDs {
		self := r.nodes[id]
		cp := client.New(self.ID, self.Addr, 5*time.Second, client.WithDialOptions(dialer))
		store := storage.NewMemoryStorage(nop)
		var n dht.DHTNode
		var peers []int // nodes this node holds pointers to
		switch protocol {
		case "chord":
			rt := chord.NewRoutingTable(self, sp, nop)
			rt.SetSuccessor(0, r.nodes[nextOnRing(id)])
			rt.SetPredecessor(r.nodes[pred(id-1)])
			peers = append(peers, nextOnRing(id))
			for i := 0; i < sp.Bits; i++ {
				f := succ(id + (1 << i)) // finger[i] = successor(id + 2^i)
				rt.SetFinger(i, r.nodes[f])
				peers = append(peers, f)
			}
			n = chord.New(sp, cp, store, chord.WithRoutingTable(rt))
		case "koorde":
			rt := routingtable.New(self, sp)
			rt.SetSuccessor(0, r.nodes[nextOnRing(id)])
			rt.SetPredecessor(r.nodes[pred(id-1)])
			peers = append(peers, nextOnRing(id))
			// de Bruijn window: predecessor(k*id) followed by its k-1 successors.
			d := pred(k * id)
			window := make([]*domain.Node, 0, k)
			for j := 0; j < k; j++ {
				window = append(window, r.nodes[d])
				peers = append(peers, d)
				d = nextOnRing(d)
			}
			rt.SetDeBruijnList(window)
			n = logicnode.New(rt, cp, store)
		default:
			t.Fatalf("unknown protocol %q", protocol)
		}
		for _, p := range peers {
			if p != id {
				// One pool connection per distinct peer; AddRef just counts references.
				if err := cp.AddRef(r.addr(p)); err != nil {
					t.Fatal(err)
				}
			}
		}
		r.dht[id] = n

		spy := func(ctx context.Context, req any, info *grpc.UnaryServerInfo, h grpc.UnaryHandler) (any, error) {
			if md, ok := metadata.FromIncomingContext(ctx); ok && info.FullMethod == "/dht.v1.DHT/FindSuccessor" {
				if v := md.Get("x-koorde-hop"); len(v) == 1 {
					d, _ := strconv.Atoi(v[0])
					r.mu.Lock()
					r.depths = append(r.depths, d)
					r.mu.Unlock()
				}
			}
			return h(ctx, req)
		}
		lis := r.lis[fmt.Sprintf("n%d", id)]
		srv, err := New(lis, n, []grpc.ServerOption{grpc.ChainUnaryInterceptor(spy)})
		if err != nil {
			t.Fatal(err)
		}
		r.servers = append(r.servers, srv)
		go srv.Start()
	}
	t.Cleanup(func() {
		for _, s := range r.servers {
			s.Stop()
		}
	})
	return r
}

// lookup runs LookUp on the entry node the way the HTTP path does and returns
// the owner ID and the hop count.
func (r *ring) lookup(entry, key int) (owner, hops int) {
	r.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ctx, c := lookuptrace.Begin(ctx)
	got, err := r.dht[entry].LookUp(ctx, r.space.FromUint64(uint64(key)))
	if err != nil {
		r.t.Fatalf("lookup(entry=%d key=%d): %v", entry, key, err)
	}
	return int(got.ID[0]), c.Hops()
}

// viaGRPC calls the client API Lookup on the entry node over bufconn, like an
// external client, and returns the hops reported in the response trailer.
func (r *ring) viaGRPC(entry, key int) (owner int, trailerHops string) {
	r.t.Helper()
	endpoint := fmt.Sprintf("n%d", entry)
	conn, err := grpc.NewClient("passthrough:///"+endpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return r.lis[endpoint].DialContext(ctx)
		}))
	if err != nil {
		r.t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var tr metadata.MD
	resp, err := clientv1.NewClientAPIClient(conn).Lookup(ctx,
		&clientv1.LookupRequest{Id: r.space.FromUint64(uint64(key)).ToHexString(false)}, grpc.Trailer(&tr))
	if err != nil {
		r.t.Fatal(err)
	}
	id, err := r.space.FromHexString(resp.Successor.Id)
	if err != nil {
		r.t.Fatal(err)
	}
	if v := tr.Get(lookuptrace.HopsTrailerKey); len(v) == 1 {
		trailerHops = v[0]
	}
	return int(id[0]), trailerHops
}

type hopCase struct {
	entry, key int
	owner      int
	hops       int
	why        string
}

func (r *ring) run(cases []hopCase) {
	r.t.Helper()
	for _, c := range cases {
		c := c
		r.mu.Lock()
		r.depths = nil
		r.mu.Unlock()
		owner, hops := r.lookup(c.entry, c.key)
		if owner != c.owner || hops != c.hops {
			r.t.Errorf("entry=%d key=%d: owner=%d hops=%d, want owner=%d hops=%d (%s)",
				c.entry, c.key, owner, hops, c.owner, c.hops, c.why)
		}
		// x-koorde-hop seen on the wire must be 1,2,...,hops: the depth keeps
		// growing along the chain instead of restarting at 1 on every node.
		r.mu.Lock()
		got := append([]int(nil), r.depths...)
		r.mu.Unlock()
		sort.Ints(got)
		want := make([]int, c.hops)
		for i := range want {
			want[i] = i + 1
		}
		if !reflect.DeepEqual(got, want) && !(len(got) == 0 && len(want) == 0) {
			r.t.Errorf("entry=%d key=%d: hop depths on the wire %v, want %v", c.entry, c.key, got, want)
		}
		// The same lookup entered over the client API reports the same total
		// in the response trailer.
		o2, tr := r.viaGRPC(c.entry, c.key)
		if o2 != c.owner || tr != strconv.Itoa(c.hops) {
			r.t.Errorf("entry=%d key=%d via gRPC: owner=%d trailer=%q, want owner=%d trailer=%d",
				c.entry, c.key, o2, tr, c.owner, c.hops)
		}
	}
}

// Chord, 8 nodes at 0,32,...,224, finger[i] = successor(id + 2^i).
//
// Fingers of node 0:   i=0..5 -> 32 (1,2,4,8,16,32 all have successor 32), i=6 -> 64, i=7 -> 128.
// Fingers of node 128: i=0..4 -> 160, i=5 -> 160 (128+32), i=6 -> 192, i=7 -> 0 (128+128=256=0).
// Fingers of node 192: i=0..5 -> 224, i=6 -> 0 (192+64=256), i=7 -> 64 (192+128=320-256).
// Chord forwards to the furthest finger that lies strictly inside (self, key)
// and stops at the node whose successor interval (self, succ] contains the key.
func TestHopCountChord(t *testing.T) {
	r := newRing(t, "chord", 2)
	r.run([]hopCase{
		// 20 is in (0,32]: node 0 answers from its own successor, no RPC.
		{0, 20, 32, 0, "key in (self, succ]"},
		// 33: 0 -> 32 (finger 32 is the furthest inside (0,33)); 33 in (32,64], 32 answers 64. 1 hop.
		{0, 33, 64, 1, "0 -> 32"},
		// 130: 0 -> 128 (furthest finger inside (0,130)); 130 in (128,160], 128 answers 160. 1 hop.
		{0, 130, 160, 1, "0 -> 128"},
		// 200: 0 -> 128; at 128 the fingers inside (128,200) are 160,192, furthest is 192 -> 192;
		// 200 in (192,224], 192 answers 224. 2 hops.
		{0, 200, 224, 2, "0 -> 128 -> 192"},
		// 255: 0 -> 128 -> 192; at 192 the fingers inside (192,255) are 224 (i=0..5), 0 and 64 are not;
		// -> 224; 255 in (224,0], 224 answers 0. 3 hops = log2(8).
		{0, 255, 0, 3, "0 -> 128 -> 192 -> 224"},
		// Different entry: from 96, key 20 (owner 32). Fingers of 96: 128 (i=0..4), 128 (i=5: 128),
		// 160 (i=6: 160), 224 (i=7: 224). Fingers strictly inside (96,20) wrapping: 224 (furthest, 224 > 96).
		// 96 -> 224; fingers of 224: i=0..4 -> 0, i=5 -> 0 (224+32=256), i=6 -> 32 (224+64=288-256),
		// i=7 -> 96 (224+128). Inside (224,20): 0 only (32 and 96 are not) -> 0; 20 in (0,32] -> 0 answers 32. 2 hops.
		{96, 20, 32, 2, "96 -> 224 -> 0"},
	})
}

// Koorde, k=2, same ring.
// de Bruijn window of node m = [predecessor(2m), next node on the ring]:
//
//	0:[0,32] 32:[64,96] 64:[128,160] 96:[192,224] 128:[0,32] 160:[64,96] 192:[128,160] 224:[192,224]
//
// A step at node s with imaginary node i in (s, succ(s)] moves to i' = 2i + digit(kshift)
// (digit = top bit of kshift, then kshift <<= 1) and forwards to the window entry whose interval
// holds i'. The start (BestImaginary) for entry 0 and key K: region (0,32] has size 32, 6 bits,
// minus a margin of 2 = 4 settable bits, so i0 = K >> 4 (K=200: 12).
func TestHopCountKoordeK2(t *testing.T) {
	r := newRing(t, "koorde", 2)
	r.run([]hopCase{
		// 20 in (0,32]: answered by node 0 itself, no RPC.
		{0, 20, 32, 0, "key in (self, succ]"},
		// K=200 (11001000b), i0=12.
		//  node 0:  digit 1, i=25 -> window [0,32], 25 in (0,32] -> entry 0 = itself: local step, no RPC.
		//  node 0:  digit 1 (kshift 10010000b), i=51 -> 51 in (32,0] -> entry 32: HOP 1.
		//  node 32: digit 0 (00100000b), i=102 -> window [64,96], 102 in (96,64] -> entry 96: HOP 2.
		//  node 96: digit 0 (01000000b), i=204 -> window [192,224], 204 in (192,224] -> entry 192: HOP 3.
		//  node 192: 200 in (192,224] -> answers 224.
		{0, 200, 224, 3, "0 =local= 0 -> 32 -> 96 -> 192"},
		// K=33 (00100001b), i0=2. Node 0 doubles i four times (2->4->8->17->34) and the window entry
		// is itself for 4, 8, 17 (all in (0,32]): 3 local steps. The 4th: i=34 not in (0,32] -> entry 32: HOP 1.
		// Node 32: 33 in (32,64] -> answers 64.
		{0, 33, 64, 1, "three local steps, then 0 -> 32"},
	})
}

// Koorde, k=4, same ring. Window of node m = [predecessor(4m) and its 3 successors].
//
//	node 0: [0,32,64,96]   node 32: [128,160,192,224]
//
// K=200 (11 00 10 00b), i0=12. Node 0: digit 3, i=4*12+3=51 -> in (32,64] -> entry 32: HOP 1
// (kshift now 00100000b). Node 32: digit 0, i=4*51+0=204 -> in (192,224] -> entry 192: HOP 2.
// Node 192: 200 in (192,224] -> answers 224. Two hops, one fewer than k=2 (3): larger k, shorter path.
func TestHopCountKoordeK4(t *testing.T) {
	r := newRing(t, "koorde", 4)
	r.run([]hopCase{
		{0, 20, 32, 0, "key in (self, succ]"},
		{0, 200, 224, 2, "0 -> 32 -> 192"},
	})
}

// The interceptors alone: a lookup context that is flagged but has no
// Counter must not break anything, and RPCs other than FindSuccessor made
// with a lookup context are not counted.
func TestCounterOnlyCountsFindSuccessor(t *testing.T) {
	r := newRing(t, "chord", 2)
	ctx, c := lookuptrace.Begin(context.Background())
	cli := r.dht[0].(*chord.Node)
	if _, err := cli.Get(ctx, r.space.FromUint64(33)); err == nil {
		t.Log("retrieve unexpectedly found a resource")
	}
	// Get = LookUp (1 FindSuccessor hop: 0 -> 32) + a Retrieve RPC that must not add a hop.
	if c.Hops() != 1 {
		t.Errorf("hops after Get(33) = %d, want 1", c.Hops())
	}
}

// HTTP: the response carries X-Lookup-Hops, and the optional CSV log gets a
// row with the same number. Node 0 owns keys in (224,0]; a Chord lookup from
// 0 for such a key is 0 -> 128 -> 192 -> 224 = 3 hops (see TestHopCountChord,
// key 255; every key in (224,255] takes the same path).
func TestHTTPLookupHopsHeaderAndCSV(t *testing.T) {
	r := newRing(t, "chord", 2)
	node := r.dht[0]

	// First URL whose hash falls in (224,255]. SHA-1 is deterministic, so this is stable.
	var url string
	for i := 0; ; i++ {
		u := "http://example.invalid/page-" + strconv.Itoa(i)
		if h := int(r.space.NewIdFromString(u)[0]); h > 224 {
			url = u
			break
		}
	}

	webCache := cache.NewWebCache(1)
	if err := webCache.Put(url, []byte("body"), "text/plain", time.Hour, 200); err != nil {
		t.Fatal(err)
	}
	h := NewHTTPCacheServer(node, webCache, cache.NewHotspotDetector(1e9, 0.5), 8080, &logger.NopLogger{})

	csvPath := filepath.Join(t.TempDir(), "lookups.csv")
	var err error
	h.lookupLog, err = newLookupCSV(csvPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.lookupLog.Close() })

	rec := httptest.NewRecorder()
	h.handleCacheRequest(rec, httptest.NewRequest(http.MethodGet, "/cache?url="+url, nil))
	if rec.Code != 200 || rec.Header().Get("X-Cache") != "HIT-LOCAL" {
		t.Fatalf("status=%d X-Cache=%q", rec.Code, rec.Header().Get("X-Cache"))
	}
	if got := rec.Header().Get("X-Lookup-Hops"); got != "3" {
		t.Errorf("X-Lookup-Hops = %q, want 3", got)
	}
	if rec.Header().Get("X-Latency-Ms") == "" {
		t.Error("X-Latency-Ms missing")
	}

	// A forwarded request (X-Is-Responsible) runs no lookup here: no header.
	req := httptest.NewRequest(http.MethodGet, "/cache?url="+url, nil)
	req.Header.Set("X-Is-Responsible", "true")
	rec = httptest.NewRecorder()
	h.handleCacheRequest(rec, req)
	if v := rec.Header().Get("X-Lookup-Hops"); v != "" {
		t.Errorf("forwarded request has X-Lookup-Hops = %q, want none", v)
	}

	f, err := os.Open(csvPath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows, err := csv.NewReader(f).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("csv has %d rows, want header + 1: %v", len(rows), rows)
	}
	want := []string{"ts_unix_ms", "protocol", "key", "ok", "hops", "total_ms", "rpc_ms", "local_ms"}
	if !reflect.DeepEqual(rows[0], want) {
		t.Errorf("csv header %v, want %v", rows[0], want)
	}
	if rows[1][1] != "chord" || rows[1][3] != "true" || rows[1][4] != "3" {
		t.Errorf("csv row %v, want protocol=chord ok=true hops=3", rows[1])
	}
}
