package client

import (
	"KoordeDHT/internal/logger"

	"google.golang.org/grpc"
)

type Option func(pool *Pool)

// WithLogger sets a custom logger for the Pool.
func WithLogger(l logger.Logger) Option {
	return func(p *Pool) {
		p.lgr = l
	}
}

// WithDialOptions appends extra gRPC dial options to every connection the
// Pool creates (for example a context dialer, so tests can connect over an
// in-memory listener). The default options stay in place.
func WithDialOptions(opts ...grpc.DialOption) Option {
	return func(p *Pool) {
		p.dialOpts = append(p.dialOpts, opts...)
	}
}
