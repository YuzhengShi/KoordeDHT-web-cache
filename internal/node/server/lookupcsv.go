package server

import (
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/node/telemetry/lookuptrace"
	"encoding/csv"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
)

// lookupCSVEnv names the environment variable that switches the per-lookup
// CSV log on. Its value is the file to append to. Unset or empty: no log, and
// nothing else about the HTTP path changes.
const lookupCSVEnv = "KOORDE_LOOKUP_CSV"

// lookupCSV appends one row per DHT lookup run by the HTTP cache path.
//
// Columns:
//
//	ts_unix_ms  wall-clock time the lookup finished
//	protocol    "koorde" or "chord"
//	key         lookup key, hex
//	ok          true if the lookup returned a node
//	hops        node-to-node FindSuccessor RPCs of the whole lookup
//	total_ms    wall time of the LookUp call on this node
//	rpc_ms      time this node spent waiting for its outgoing FindSuccessor
//	            call (recursive lookup: this includes all downstream work)
//	local_ms    total_ms - rpc_ms: work done on this node itself
type lookupCSV struct {
	mu sync.Mutex
	f  *os.File
	w  *csv.Writer
}

func newLookupCSVFromEnv() (*lookupCSV, error) {
	path := os.Getenv(lookupCSVEnv)
	if path == "" {
		return nil, nil
	}
	return newLookupCSV(path)
}

func newLookupCSV(path string) (*lookupCSV, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	l := &lookupCSV{f: f, w: csv.NewWriter(f)}
	if st, err := f.Stat(); err == nil && st.Size() == 0 {
		_ = l.w.Write([]string{"ts_unix_ms", "protocol", "key", "ok", "hops", "total_ms", "rpc_ms", "local_ms"})
		l.w.Flush()
	}
	return l, nil
}

func (l *lookupCSV) write(protocol string, key domain.ID, c *lookuptrace.Counter, total time.Duration, ok bool) {
	rpc := c.RPCTime()
	local := total - rpc
	if local < 0 {
		local = 0
	}
	ms := func(d time.Duration) string { return fmt.Sprintf("%.3f", d.Seconds()*1000) }
	l.mu.Lock()
	defer l.mu.Unlock()
	_ = l.w.Write([]string{
		strconv.FormatInt(time.Now().UnixMilli(), 10),
		protocol,
		key.ToHexString(false),
		strconv.FormatBool(ok),
		strconv.Itoa(c.Hops()),
		ms(total), ms(rpc), ms(local),
	})
	l.w.Flush()
}

// Close flushes and closes the log file.
func (l *lookupCSV) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.w.Flush()
	return l.f.Close()
}
