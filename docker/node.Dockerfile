FROM golang:1.25 AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /koorde-node ./cmd/node

FROM debian:bookworm-slim

# Install CA certificates for HTTPS
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /koorde-node /usr/local/bin/koorde
COPY config/node/config.yaml /etc/koorde/config.yaml
COPY deploy/eks/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh", "/usr/local/bin/koorde", "-config", "/etc/koorde/config.yaml"]
