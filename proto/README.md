# Protocol Buffers Compilation

This project uses **Protocol Buffers** (`.proto`) to define gRPC services and message structures for the Koorde DHT.

## Prerequisites

Install the required tools:

1. **protoc compiler**
   ```bash
   # macOS
   brew install protobuf
   
   # Ubuntu/Debian
   sudo apt install protobuf-compiler
   
   # Windows
   # Download from: https://github.com/protocolbuffers/protobuf/releases
   ```

2. **Go plugins for Protocol Buffers**
   ```bash
   go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
   go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
   ```

3. **Add Go bin to PATH**
   ```bash
   export PATH="$PATH:$(go env GOPATH)/bin"
   ```

---

## Compile .proto Files

From the project root:

### DHT Service

```bash
protoc \
  -I=proto \
  -I=/usr/include \
  --go_out=. --go_opt=module=KoordeDHT \
  --go-grpc_out=. --go-grpc_opt=module=KoordeDHT \
  proto/dht/v1/node.proto
```

Generates:
- `internal/api/dht/v1/node.pb.go` - Message types
- `internal/api/dht/v1/node_grpc.pb.go` - gRPC service

### Client API

```bash
protoc \
  -I=proto \
  -I=/usr/include \
  --go_out=. --go_opt=module=KoordeDHT \
  --go-grpc_out=. --go-grpc_opt=module=KoordeDHT \
  proto/client/v1/client.proto
```

Generates:
- `internal/api/client/v1/client.pb.go` - Message types
- `internal/api/client/v1/client_grpc.pb.go` - gRPC service

---

## Protocol Definitions

### DHT Service (`proto/dht/v1/node.proto`)

Core Koorde DHT operations:

```protobuf
service DHT {
  // Find successor of a given ID
  rpc FindSuccessor(FindSuccessorRequest) returns (FindSuccessorResponse);
  
  // Get node's predecessor
  rpc GetPredecessor(Empty) returns (Node);
  
  // Notify node of a potential predecessor
  rpc Notify(Node) returns (Empty);
  
  // Get successor list
  rpc GetSuccessorList(Empty) returns (SuccessorListResponse);
  
  // Retrieve value from storage
  rpc RetrieveValue(RetrieveValueRequest) returns (RetrieveValueResponse);
  
  // Store key-value pairs
  rpc Store(stream StoreRequest) returns (Empty);
  
  // Health check
  rpc Ping(Empty) returns (Empty);
}
```

### Client API (`proto/client/v1/client.proto`)

User-facing operations:

```protobuf
service ClientAPI {
  // Put key-value pair
  rpc Put(PutRequest) returns (Empty);
  
  // Get value by key
  rpc Get(GetRequest) returns (GetResponse);
  
  // Delete key
  rpc Delete(DeleteRequest) returns (Empty);
  
  // Lookup successor of ID
  rpc Lookup(LookupRequest) returns (NodeInfo);
  
  // Get routing table
  rpc GetRoutingTable(Empty) returns (RoutingTableResponse);
  
  // Get stored resources
  rpc GetStore(Empty) returns (GetStoreResponse);
}
```

---

## When to Recompile

You need to recompile when:
- ✅ You modify any `.proto` file
- ✅ You add new RPC methods
- ✅ You change message structures
- ❌ You only modify Go implementation code

---

## Verification

After compilation, verify the generated files exist:

```bash
ls -la internal/api/dht/v1/
# Should see:
# - node.pb.go
# - node_grpc.pb.go

ls -la internal/api/client/v1/
# Should see:
# - client.pb.go
# - client_grpc.pb.go
```

---

## Integration with Project

### Generated Code Usage

**DHT Service (node-to-node communication)**:
```go
import dhtv1 "KoordeDHT/internal/api/dht/v1"

// Server side
type dhtService struct {
    dhtv1.UnimplementedDHTServer
    node *logicnode.Node
}

// Client side
conn, _ := grpc.Dial(addr)
client := dhtv1.NewDHTClient(conn)
response, _ := client.FindSuccessor(ctx, &dhtv1.FindSuccessorRequest{...})
```

**Client API (user-facing)**:
```go
import clientv1 "KoordeDHT/internal/api/client/v1"

// Server side
type clientService struct {
    clientv1.UnimplementedClientAPIServer
    node *logicnode.Node
}

// Client side
conn, _ := grpc.Dial(addr)
client := clientv1.NewClientAPIClient(conn)
response, _ := client.Put(ctx, &clientv1.PutRequest{...})
```

---

## Module Path Note

The `--go_opt=module=KoordeDHT` flag must match your `go.mod` module name:

```go
// go.mod
module KoordeDHT

go 1.25
```

If you rename the module, update all `protoc` commands accordingly.

---

## Troubleshooting

**Error: `protoc-gen-go: program not found`**
```bash
# Ensure Go bin is in PATH
export PATH="$PATH:$(go env GOPATH)/bin"

# Verify installation
which protoc-gen-go
which protoc-gen-go-grpc
```

**Error: `cannot find package`**
```bash
# Run go mod tidy after generating
go mod tidy

# Verify imports
go list -m all | grep grpc
```

**Error: `import "google/protobuf/empty.proto": file not found`**
```bash
# On Ubuntu/Debian
sudo apt install protobuf-compiler

# On macOS
brew install protobuf

# Verify protoc can find standard protos
protoc --version
```

---

## Learn More

- [Protocol Buffers Documentation](https://protobuf.dev/)
- [gRPC Go Quick Start](https://grpc.io/docs/languages/go/quickstart/)
- [Protocol Buffers Language Guide](https://protobuf.dev/programming-guides/proto3/)
