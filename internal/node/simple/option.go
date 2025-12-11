package simple

import "KoordeDHT/internal/logger"

// Option is a functional option for configuring a simple hash Node.
type Option func(*Node)

// WithLogger sets the logger for the node.
func WithLogger(lgr logger.Logger) Option {
	return func(n *Node) {
		n.lgr = lgr
	}
}
