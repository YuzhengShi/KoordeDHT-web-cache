# Dockerfile Reference

This document describes the **Dockerfiles** used to build and distribute the KoordeDHT project containers.

Prebuilt images are available on **Docker Hub**: [`flaviosimonelli/koorde`](https://hub.docker.com/r/flaviosimonelli)

---

## 1. `node.Dockerfile`

### Purpose
Creates the **Koorde DHT node** image (`koorde-node`) with web cache functionality.

### Build Structure

**Builder stage:**
- Base image: `golang:1.25`
- Compiles the Go binary:
  ```bash
  CGO_ENABLED=0 GOOS=linux go build -o /koorde-node ./cmd/node
  ```

**Runtime stage:**
- Base image: `gcr.io/distroless/base-debian12` (minimal, secure)
- Binary location: `/usr/local/bin/koorde`
- Default ports:
  - `4000` - gRPC (DHT protocol)
  - `8080` - HTTP (web cache API)

### Usage

```bash
# Pull from Docker Hub
docker pull flaviosimonelli/koorde-node:latest

# Or build locally
docker build -f docker/node.Dockerfile -t koorde-node:latest .

# Run
docker run -p 4000:4000 -p 8080:8080 \
  -e DHT_MODE=private \
  -e CACHE_ENABLED=true \
  koorde-node:latest
```

### Configuration

Mount a custom config or use environment variables:

```bash
docker run \
  -v $(pwd)/config/node/config.yaml:/config/config.yaml \
  -e LOGGER_LEVEL=debug \
  -e CACHE_CAPACITY_MB=2048 \
  koorde-node:latest --config /config/config.yaml
```

See `config/node/structure.env` for all available environment variables.

---

## 2. `node.netem.Dockerfile`

### Purpose
Creates a **network-emulation-enabled** node image for testing with latency, jitter, and packet loss.

Used with **Pumba** for chaos engineering.

### Build Structure

**Builder stage:**
- Same as `node.Dockerfile`

**Runtime stage:**
- Base image: `debian:12-slim` (includes networking tools)
- Installs: `iproute2` (for `tc netem`)
- Binary location: `/usr/local/bin/koorde`

### Usage

```bash
# Build
docker build -f docker/node.netem.Dockerfile -t koorde-node-netem:latest .

# Run with Pumba
docker run --name koorde-node-1 koorde-node-netem:latest &

# Add network delay
docker run -it --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gaiaadm/pumba \
  netem --duration 5m \
  --tc-image gaiadocker/iproute2 \
  delay --time 100 \
  koorde-node-1
```

See `deploy/test/` for automated testing with Pumba.

---

## 3. `client.Dockerfile`

### Purpose
Creates the **interactive DHT client** (`koorde-client`) for manual testing.

### Build Structure

**Builder stage:**
- Base image: `golang:1.25`
- Compiles:
  ```bash
  CGO_ENABLED=0 GOOS=linux go build -o /koorde-client ./cmd/client
  ```

**Runtime stage:**
- Base image: `gcr.io/distroless/base-debian12`
- Binary location: `/usr/local/bin/koorde-client`

### Usage

```bash
# Pull from Docker Hub
docker pull flaviosimonelli/koorde-client:latest

# Interactive mode
docker run -it --rm \
  --network koordenet \
  koorde-client:latest --addr bootstrap:4000

# Single command
docker run --rm \
  --network koordenet \
  koorde-client:latest --addr bootstrap:4000 <<EOF
put mykey myvalue
get mykey
exit
EOF
```

### Available Commands

```
put <key> <value>   - Store key-value pair
get <key>           - Retrieve value
delete <key>        - Remove key
lookup <id>         - Find successor of ID
getrt               - Show routing table
getstore            - Show stored resources
use <addr>          - Switch to different node
exit                - Quit client
```

---

## 4. `tester.Dockerfile`

### Purpose
Creates the **automated testing client** (`koorde-tester`) for performance testing and metrics collection.

### Build Structure

**Builder stage:**
- Compiles `koorde-tester` from `./cmd/tester`

**Prep stage:**
- Uses `busybox` to create `/data/results` directory

**Runtime stage:**
- Base image: `gcr.io/distroless/base-debian12`
- Runs as root (needs Docker socket access for discovery)
- Results directory: `/data/results`

### Usage

```bash
# Build
docker build -f docker/tester.Dockerfile -t koorde-tester:latest .

# Run automated tests
docker run -v $(pwd)/results:/data/results \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e SIM_DURATION=60s \
  -e QUERY_RATE=10 \
  -e CSV_ENABLED=true \
  koorde-tester:latest

# View results
cat results/output.csv
```

### Configuration

```bash
# High-throughput testing
docker run \
  -e SIM_DURATION=5m \
  -e QUERY_RATE=100 \
  -e QUERY_PARALLELISM_MIN=10 \
  -e QUERY_PARALLELISM_MAX=50 \
  -e CSV_PATH=/data/results/test.csv \
  koorde-tester:latest
```

---

## Building All Images

```bash
# Node
docker build -f docker/node.Dockerfile -t koorde-node:latest .

# Node with network emulation
docker build -f docker/node.netem.Dockerfile -t koorde-node-netem:latest .

# Client
docker build -f docker/client.Dockerfile -t koorde-client:latest .

# Tester
docker build -f docker/tester.Dockerfile -t koorde-tester:latest .
```

---

## Multi-Architecture Builds

For ARM and x86:

```bash
# Setup buildx
docker buildx create --name multiarch --use

# Build for multiple platforms
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -f docker/node.Dockerfile \
  -t flaviosimonelli/koorde-node:latest \
  --push .
```

---

## Image Sizes

| Image | Size | Purpose |
|-------|------|---------|
| `koorde-node` | ~25MB | Production node (distroless) |
| `koorde-node-netem` | ~150MB | Testing with network tools (Debian) |
| `koorde-client` | ~20MB | Interactive client (distroless) |
| `koorde-tester` | ~25MB | Automated testing (distroless) |

---

## Security

### Distroless Benefits
- **Minimal attack surface** (no shell, package manager)
- **Small size** (faster pulls)
- **Secure by default** (no unnecessary tools)

### Running as Non-Root

For production, create custom images:

```dockerfile
FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=builder /koorde-node /usr/local/bin/koorde
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/koorde"]
```

---

## Docker Compose

See deployment examples:
- [Local with Jaeger](../deploy/tracing/docker-compose.yml)
- [Automated Testing](../deploy/test/docker-compose.template.yml)

---

## Troubleshooting

**Issue: Permission denied**
```bash
# Check file permissions
docker run --rm koorde-node:latest ls -la /usr/local/bin/

# Rebuild if needed
docker build --no-cache -f docker/node.Dockerfile -t koorde-node:latest .
```

**Issue: Binary not found**
```bash
# Verify build stage
docker build -f docker/node.Dockerfile -t koorde-node:latest . --progress=plain

# Check binary exists
docker run --rm --entrypoint /bin/sh koorde-node:latest -c "ls -la /usr/local/bin/"
```

**Issue: Go module errors during build**
```bash
# Clear build cache
docker build --no-cache -f docker/node.Dockerfile .

# Or fix go.mod/go.sum
go mod tidy
```

---

## Development Workflow

```bash
# 1. Make code changes
vim internal/node/cache/cache.go

# 2. Build locally
go build -o bin/koorde-node ./cmd/node

# 3. Test locally
./bin/koorde-node --config config/node/config.yaml

# 4. Build Docker image
docker build -f docker/node.Dockerfile -t koorde-node:dev .

# 5. Test in Docker
docker run -p 4000:4000 -p 8080:8080 koorde-node:dev

# 6. If good, tag and push
docker tag koorde-node:dev flaviosimonelli/koorde-node:v1.2.3
docker push flaviosimonelli/koorde-node:v1.2.3
```

---

## Registry

Public images on Docker Hub:
- https://hub.docker.com/r/flaviosimonelli/koorde-node
- https://hub.docker.com/r/flaviosimonelli/koorde-client
- https://hub.docker.com/r/flaviosimonelli/koorde-tester

Pull with:
```bash
docker pull flaviosimonelli/koorde-node:latest
docker pull flaviosimonelli/koorde-client:latest
docker pull flaviosimonelli/koorde-tester:latest
```
