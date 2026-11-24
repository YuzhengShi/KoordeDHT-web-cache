package lookuptrace

import (
	"context"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

const (
	lookupMetaKey = "x-koorde-lookup"
	hopMetaKey    = "x-koorde-hop"
	// HopsTrailerKey is the gRPC trailer in which a node reports how many
	// FindSuccessor RPC hops happened *downstream of it* while it served a
	// lookup. The caller adds 1 (the call it just made) to get its own total.
	HopsTrailerKey = "x-koorde-hops"
	tracerName     = "koorde/lookuptrace"
	findSuccSuffix = "/FindSuccessor"
)

var tracer = otel.Tracer(tracerName)

// Counter accumulates, for one lookup as seen from one node, the number of
// FindSuccessor RPCs that were made (successfully) on its behalf, and the
// wall time spent inside those RPCs.
//
// A lookup is recursive: the entry node calls the next node, which calls the
// next one, and so on. Every node therefore owns its own Counter. A node's
// Counter holds the sum over its successful outgoing calls of (1 + hops
// reported by the callee), so at the entry node it is the total number of
// node-to-node RPC hops of the whole lookup. Calls that fail are not counted.
// Steps that a node performs on itself without an RPC (Koorde's de Bruijn
// pointer equal to self) are not counted either.
type Counter struct {
	hops     atomic.Int64
	rpcNanos atomic.Int64
}

// Hops returns the number of RPC hops counted so far.
func (c *Counter) Hops() int { return int(c.hops.Load()) }

// RPCTime returns the summed wall time of the outgoing FindSuccessor calls
// made by this node for the lookup. In a recursive lookup that time includes
// the work done by all downstream nodes.
func (c *Counter) RPCTime() time.Duration { return time.Duration(c.rpcNanos.Load()) }

type counterKey struct{}

// Begin marks ctx as the start of a lookup and attaches a fresh Counter. Use
// it at every place where a node starts a lookup on its own behalf (for
// example the HTTP handler); the gRPC server interceptor does the same for
// lookups that arrive over gRPC.
func Begin(ctx context.Context) (context.Context, *Counter) {
	c := &Counter{}
	return context.WithValue(WithLookup(ctx), counterKey{}, c), c
}

// CounterFromContext returns the Counter attached by Begin or by the server
// interceptor, or nil.
func CounterFromContext(ctx context.Context) *Counter {
	c, _ := ctx.Value(counterKey{}).(*Counter)
	return c
}

// WithLookup adds the flag to the output metadata.
func WithLookup(ctx context.Context) context.Context {
	md, _ := metadata.FromOutgoingContext(ctx)
	md = md.Copy()
	md.Set(lookupMetaKey, "true")
	return metadata.NewOutgoingContext(ctx, md)
}

// IsLookup checks whether the incoming context belongs to a lookup.
func IsLookup(ctx context.Context) bool {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return false
	}
	values := md.Get(lookupMetaKey)
	return len(values) > 0 && values[0] == "true"
}

// isLookupOutgoing checks whether the outgoing context belongs to a lookup.
func isLookupOutgoing(ctx context.Context) bool {
	md, ok := metadata.FromOutgoingContext(ctx)
	if !ok {
		return false
	}
	values := md.Get(lookupMetaKey)
	return len(values) > 0 && values[0] == "true"
}

// ServerInterceptor creates spans only for marked Lookup and FindSuccessor
// and propagates the OTEL context with hop count and lookup flag.
//
// For those calls it also (1) copies the incoming hop count into the outgoing
// metadata, so the RPCs this handler makes continue the chain instead of
// restarting at 1, (2) attaches a Counter to the handler context, and (3)
// returns the Counter's value in the HopsTrailerKey trailer.
func ServerInterceptor() grpc.UnaryServerInterceptor {
	propagator := otel.GetTextMapPropagator()

	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (interface{}, error) {

		method := info.FullMethod

		// Only trace Lookup and FindSuccessor calls
		// (FindSuccessor only if it's part of a lookup)
		if strings.Contains(method, "Lookup") || (strings.Contains(method, "FindSuccessor") && IsLookup(ctx)) {
			// Hop depth of this call, as sent by the caller (0 for a lookup
			// that starts here).
			var hopCount int
			if md, ok := metadata.FromIncomingContext(ctx); ok {
				if vals := md.Get(hopMetaKey); len(vals) > 0 {
					hopCount, _ = strconv.Atoi(vals[0])
				}

				// Extract OTEL context from metadata
				ctx = propagator.Extract(ctx, metadataCarrier(md))
			}

			// Outgoing metadata for the RPCs made by the handler: lookup
			// flag plus the hop depth reached so far. The client
			// interceptor adds 1 for each call.
			out, _ := metadata.FromOutgoingContext(ctx)
			out = out.Copy()
			out.Set(hopMetaKey, strconv.Itoa(hopCount))
			ctx = metadata.NewOutgoingContext(ctx, out)

			ctx, counter := Begin(ctx)

			ctx, span := tracer.Start(ctx, method, trace.WithSpanKind(trace.SpanKindServer))
			defer span.End()

			// Publish attributes to the span
			span.SetAttributes(
				attribute.String("rpc.method", method),
				attribute.Int("koorde.hop", hopCount),
			)

			// Execute the real handler, then report the downstream hops.
			resp, err := handler(ctx, req)
			_ = grpc.SetTrailer(ctx, metadata.Pairs(HopsTrailerKey, strconv.Itoa(counter.Hops())))
			span.SetAttributes(attribute.Int("koorde.hops.downstream", counter.Hops()))
			return resp, err
		}

		// Not a lookup-related call, proceed without tracing
		return handler(ctx, req)
	}
}

// ClientInterceptor creates spans only for FindSuccessor calls made inside a
// lookup. It sends the hop depth in metadata (incremented by 1), and after a
// successful call adds 1 + the callee's reported downstream hops to the
// lookup's Counter.
func ClientInterceptor() grpc.UnaryClientInterceptor {
	propagator := otel.GetTextMapPropagator()

	return func(
		ctx context.Context,
		method string,
		req, reply interface{},
		cc *grpc.ClientConn,
		invoker grpc.UnaryInvoker,
		opts ...grpc.CallOption,
	) error {
		// Only FindSuccessor calls that belong to a lookup are hops. Other
		// RPCs made with a lookup context (Retrieve, Store...) are not.
		if !strings.HasSuffix(method, findSuccSuffix) || !isLookupOutgoing(ctx) {
			return invoker(ctx, method, req, reply, cc, opts...)
		}

		// Increment hop count from metadata
		var hopCount int
		md, _ := metadata.FromOutgoingContext(ctx)
		md = md.Copy()
		if vals := md.Get(hopMetaKey); len(vals) > 0 {
			hopCount, _ = strconv.Atoi(vals[0])
		}
		hopCount++
		md.Set(hopMetaKey, strconv.Itoa(hopCount))

		counter := CounterFromContext(ctx)

		ctx = metadata.NewOutgoingContext(ctx, md)
		ctx, span := tracer.Start(ctx, method, trace.WithSpanKind(trace.SpanKindClient))
		defer span.End()

		// Publish attributes to the span
		span.SetAttributes(attribute.Int("koorde.hop", hopCount))

		// Inject the span context into the metadata
		propagator.Inject(ctx, metadataCarrier(md))
		ctx = metadata.NewOutgoingContext(ctx, md)

		var trailer metadata.MD
		begin := time.Now()
		err := invoker(ctx, method, req, reply, cc, append(opts, grpc.Trailer(&trailer))...)
		if err != nil {
			return err
		}
		if counter != nil {
			below := 0
			if vals := trailer.Get(HopsTrailerKey); len(vals) > 0 {
				below, _ = strconv.Atoi(vals[0])
			}
			counter.hops.Add(int64(1 + below))
			counter.rpcNanos.Add(int64(time.Since(begin)))
		}
		return nil
	}
}

type metadataCarrier metadata.MD

func (mc metadataCarrier) Get(key string) string {
	vals := metadata.MD(mc).Get(key)
	if len(vals) == 0 {
		return ""
	}
	return vals[0]
}

func (mc metadataCarrier) Set(key, value string) {
	metadata.MD(mc).Set(key, value)
}

func (mc metadataCarrier) Keys() []string {
	out := make([]string, 0, len(mc))
	for k := range mc {
		out = append(out, k)
	}
	return out
}
