package chord

import "KoordeDHT/internal/logger"

type Option func(*Node)

func WithLogger(l logger.Logger) Option {
	return func(n *Node) {
		n.lgr = l
	}
}

func WithRoutingTable(rt *RoutingTable) Option {
	return func(n *Node) {
		n.rt = rt
	}
}
