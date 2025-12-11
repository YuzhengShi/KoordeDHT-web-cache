package main

import (
	"KoordeDHT/internal/bootstrap"
	"KoordeDHT/internal/domain"
	"KoordeDHT/internal/logger"
	zapfactory "KoordeDHT/internal/logger/zap"
	"KoordeDHT/internal/node/cache"
	"KoordeDHT/internal/node/chord"
	client2 "KoordeDHT/internal/node/client"
	"KoordeDHT/internal/node/config"
	"KoordeDHT/internal/node/dht"
	logicnode2 "KoordeDHT/internal/node/logicnode"
	routingtable2 "KoordeDHT/internal/node/routingtable"
	server2 "KoordeDHT/internal/node/server"
	"KoordeDHT/internal/node/simple"
	"KoordeDHT/internal/node/storage"
	"KoordeDHT/internal/node/telemetry"
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel"
	"google.golang.org/grpc"
)

var defaultConfigPath = "config/node/config.yaml"

func main() {
	// Parse command-line flags
	configPath := flag.String("config", defaultConfigPath, "path to configuration file")
	flag.Parse()

	// Load configuration
	cfg, err := config.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("failed to load configuration from %q: %v", *configPath, err)
	}

	// Validate configuration
	if err := cfg.ValidateConfig(); err != nil {
		log.Fatalf("invalid configuration: %v", err)
	}

	// Initialize logger
	var lgr logger.Logger
	if cfg.Logger.Active {
		zapLog, err := zapfactory.New(cfg.Logger)
		if err != nil {
			log.Fatalf("failed to initialize logger: %v", err)
		}
		defer func() { _ = zapLog.Sync() }()
		lgr = zapfactory.NewZapAdapter(zapLog)
	} else {
		lgr = &logger.NopLogger{}
	}

	cfg.LogConfig(lgr)

	// Initialize listener
	lis, advertised, err := server2.Listen(cfg.DHT.Mode, cfg.Node.Bind, cfg.Node.Host, cfg.Node.Port)
	if err != nil {
		lgr.Error("Fatal: failed to initialize listener", logger.F("err", err))
		os.Exit(1)
	}
	defer func() { _ = lis.Close() }()
	addr := lis.Addr().String()
	lgr.Debug("create listener", logger.F("BindAddr", addr), logger.F("AdvertisedAddr", advertised))

	// Initialize identifier space
	space, err := domain.NewSpace(cfg.DHT.IDBits, cfg.DHT.DeBruijn.Degree, cfg.DHT.FaultTolerance.SuccessorListSize)
	if err != nil {
		lgr.Error("failed to initialize identifier space", logger.F("err", err))
		os.Exit(1)
	}
	lgr.Debug("identifier space initialized",
		logger.F("id_bits", space.Bits),
		logger.F("degree", space.GraphGrade),
		logger.F("sizeByte", space.ByteLen),
		logger.F("SuccessorListSize", space.SuccListSize))

	// Initialize local node
	var id domain.ID
	if cfg.Node.Id == "" {
		id = space.NewIdFromString(advertised)
	} else {
		id, err = space.FromHexString(cfg.Node.Id)
		if err != nil {
			lgr.Error("invalid node ID in configuration", logger.F("err", err))
			os.Exit(1)
		}
	}
	domainNode := domain.Node{
		ID:   id,
		Addr: advertised,
	}
	lgr.Debug("generated node ID", logger.F("id", id.ToHexString(true)))
	lgr = lgr.Named("node").WithNode(domainNode)
	lgr.Info("New Node initializing")

	// Initialize Telemetry
	shutdown := telemetry.InitTracer(cfg.Telemetry, "KoordeDHT-Node", id)
	defer shutdown(context.Background())

	// Initialize client pool
	cpOpts := []client2.Option{client2.WithLogger(lgr.Named("clientpool"))}
	cp := client2.New(
		id,
		addr,
		cfg.DHT.FaultTolerance.FailureTimeout,
		cpOpts...,
	)
	lgr.Debug("initialized client pool")

	// Initialize storage
	store := storage.NewMemoryStorage(lgr.Named("storage"))
	lgr.Debug("initialized in-memory storage")

	// Initialize web cache layer
	webCache := cache.NewWebCache(cfg.Cache.CapacityMB)
	lgr.Info("initialized web cache",
		logger.F("capacity_mb", cfg.Cache.CapacityMB))

	hotspotDetector := cache.NewHotspotDetector(
		cfg.Cache.HotspotThreshold,
		cfg.Cache.HotspotDecayRate,
	)
	lgr.Info("initialized hotspot detector",
		logger.F("threshold", cfg.Cache.HotspotThreshold),
		logger.F("decay_rate", cfg.Cache.HotspotDecayRate))

	// Start periodic cache cleanup
	go func() {
		ticker := time.NewTicker(1 * time.Hour)
		defer ticker.Stop()
		for {
			<-ticker.C
			cleaned := webCache.CleanExpired()
			lgr.Info("cleaned expired cache entries", logger.F("count", cleaned))

			stale := hotspotDetector.CleanStale(24 * time.Hour)
			lgr.Info("cleaned stale hotspot entries", logger.F("count", stale))
		}
	}()

	// Initialize node based on protocol
	var n dht.DHTNode

	switch cfg.DHT.Protocol {
	case "simple":
		// Simple modulo hash - requires static cluster membership
		simpleNode := simple.New(
			&domainNode,
			space,
			cp,
			store,
			simple.WithLogger(lgr),
		)

		// Set up cluster nodes if configured
		if len(cfg.DHT.ClusterNodes) > 0 {
			clusterNodes := make([]*domain.Node, 0, len(cfg.DHT.ClusterNodes))
			for _, addr := range cfg.DHT.ClusterNodes {
				nodeID := space.NewIdFromString(addr)
				clusterNodes = append(clusterNodes, &domain.Node{
					ID:   nodeID,
					Addr: addr,
				})
			}
			simpleNode.SetClusterNodes(clusterNodes)
		}

		n = simpleNode
		lgr.Info("Initialized Simple hash node",
			logger.F("cluster_size", len(cfg.DHT.ClusterNodes)))

	case "chord":
		chordRT := chord.NewRoutingTable(
			&domainNode,
			space,
			lgr.Named("chord-rt"),
		)
		n = chord.New(
			space,
			cp,
			store,
			chord.WithRoutingTable(chordRT),
			chord.WithLogger(lgr),
		)
		lgr.Info("Initialized Chord node")

	case "koorde":
		fallthrough
	default:
		// Initialize Koorde routing table
		rt := routingtable2.New(
			&domainNode,
			space,
			routingtable2.WithLogger(lgr.Named("routingtable")),
		)
		lgr.Debug("initialized routing table")

		n = logicnode2.New(
			rt,
			cp,
			store,
			logicnode2.WithLogger(lgr),
		)
		lgr.Info("Initialized Koorde node")
	}

	// Initialize gRPC server
	var grpcOpts []grpc.ServerOption
	if cfg.Telemetry.Tracing.Enabled {
		grpcOpts = append(grpcOpts,
			grpc.StatsHandler(otelgrpc.NewServerHandler(
				otelgrpc.WithTracerProvider(otel.GetTracerProvider()),
				otelgrpc.WithPropagators(otel.GetTextMapPropagator()),
			)),
		)
	}

	s, err := server2.New(
		lis,
		n,
		grpcOpts,
		server2.WithLogger(lgr.Named("grpc-server")),
	)
	if err != nil {
		lgr.Error("failed to initialize gRPC server", logger.F("err", err))
		os.Exit(1)
	}
	lgr.Debug("initialized gRPC server")

	// Initialize HTTP cache server
	httpServer := server2.NewHTTPCacheServer(
		n,
		webCache,
		hotspotDetector,
		cfg.Cache.HTTPPort,
		lgr.Named("http-server"),
	)
	lgr.Debug("initialized HTTP cache server", logger.F("port", cfg.Cache.HTTPPort))

	// Run gRPC server in background
	serveErr := make(chan error, 1)
	go func() { serveErr <- s.Start() }()
	lgr.Debug("gRPC server started")

	// Run HTTP server in background
	httpErr := make(chan error, 1)
	go func() { httpErr <- httpServer.Start() }()
	lgr.Debug("HTTP cache server started")

	// Bootstrap (join DHT or create new)
	var register bootstrap.Bootstrap
	if cfg.DHT.Bootstrap.Mode == "route53" {
		register, err = bootstrap.NewRoute53Bootstrap(cfg.DHT.Bootstrap.Route53)
		if err != nil {
			lgr.Error("failed to initialize Route53 bootstrap", logger.F("err", err))
			s.Stop()
			n.Stop()
			os.Exit(1)
		}
	} else if cfg.DHT.Bootstrap.Mode == "static" {
		register = bootstrap.NewStaticBootstrap(cfg.DHT.Bootstrap.Peers)
	} else {
		lgr.Error("unsupported bootstrap mode", logger.F("mode", cfg.DHT.Bootstrap.Mode))
		s.Stop()
		n.Stop()
		os.Exit(1)
	}

	// Join or create DHT
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	peers, err := register.Discover(ctx)
	cancel()
	if err != nil {
		lgr.Error("failed to resolve bootstrap peers", logger.F("err", err))
		s.Stop()
		n.Stop()
		os.Exit(1)
	}

	lgr.Info("resolved bootstrap peers", logger.F("peers", peers))

	if len(peers) != 0 {
		if err := n.Join(peers); err != nil {
			lgr.Error("failed to join DHT", logger.F("err", err))
			s.Stop()
			n.Stop()
			os.Exit(1)
		}
		lgr.Debug("joined DHT")
	} else {
		n.CreateNewDHT()
		lgr.Debug("new DHT created")
	}

	// Register node
	ctx, cancel = context.WithTimeout(context.Background(), 10*time.Second)
	err = register.Register(ctx, &domainNode)
	cancel()
	if err != nil {
		lgr.Error("failed to register DHT", logger.F("err", err))
	} else {
		lgr.Info("node registered successfully")
		defer func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			err := register.Deregister(ctx, &domainNode)
			cancel()
			if err != nil {
				lgr.Warn("failed to deregister node", logger.F("err", err))
			}
		}()
	}

	// Setup signal handler
	ctx, stabilizerStop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)

	// Start stabilization workers
	n.StartStabilizers(ctx, cfg.DHT.FaultTolerance.StabilizationInterval, cfg.DHT.DeBruijn.FixInterval, cfg.DHT.Storage.FixInterval)
	lgr.Debug("Stabilization workers started")

	// Wait for termination
	select {
	case <-ctx.Done():
		lgr.Info("shutdown signal received, stopping servers gracefully...")

		stabilizerStop()

		// Stop HTTP server
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := httpServer.Stop(shutdownCtx); err != nil {
			lgr.Warn("HTTP server shutdown error", logger.F("err", err))
		}
		cancel()

		// Stop gRPC server
		shutdownCtx, cancel = context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		done := make(chan struct{})
		go func() {
			s.GracefulStop()
			close(done)
		}()

		select {
		case <-done:
			lgr.Info("gRPC server stopped gracefully")
		case <-shutdownCtx.Done():
			lgr.Warn("graceful stop timed out, forcing shutdown")
		}

		n.Stop()

	case err := <-serveErr:
		lgr.Error("gRPC server terminated unexpectedly", logger.F("err", err))
		stabilizerStop()
		httpServer.Stop(context.Background())
		n.Stop()
		os.Exit(1)

	case err := <-httpErr:
		lgr.Error("HTTP server terminated unexpectedly", logger.F("err", err))
		stabilizerStop()
		s.Stop()
		n.Stop()
		os.Exit(1)
	}
}
