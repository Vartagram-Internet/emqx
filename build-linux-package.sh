#!/bin/bash
# Build Linux x86_64 package for EMQX with delivery.timeout feature

set -e

echo "Building EMQX Linux x86_64 package..."
echo "This will compile in Docker builder environment"
echo ""

# Create Dockerfile for Linux compilation
cat > /tmp/Dockerfile.linux-build << 'EOF'
# Stage 1: Build EMQX for Linux x86_64
FROM ghcr.io/emqx/emqx-builder/6.0-9:1.19.1-28.2-2-debian13 AS builder

WORKDIR /emqx
COPY . /emqx

# Build EMQX with delivery.timeout feature
RUN make emqx-enterprise-tgz

# Stage 2: Create runtime image
FROM debian:13-slim

LABEL maintainer="EMQX with delivery.timeout"
LABEL description="EMQX Message Broker with delivery.timeout event feature"

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libncurses6 \
    libssl3 \
    libatomic1 \
    procps \
    net-tools \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /emqx

# Copy compiled release from builder
COPY --from=builder /emqx/_packages/emqx/*.tar.gz /tmp/emqx.tar.gz
RUN tar zxf /tmp/emqx.tar.gz -C /emqx && \
    rm /tmp/emqx.tar.gz && \
    chmod +x /emqx/bin/emqx /emqx/bin/emqx_ctl

# Expose all necessary ports
EXPOSE 1883 8883 18084 18083 8083 8084

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD /emqx/bin/emqx eval "ok" || exit 1

# Default command
CMD ["/emqx/bin/emqx", "foreground"]
EOF

# Build Docker image for Linux x86_64
echo "Step 1: Building Docker image (Linux x86_64)..."
docker build -f /tmp/Dockerfile.linux-build \
  --platform linux/amd64 \
  -t emqx:delivery-timeout-linux-x86_64 \
  .

echo "✅ Docker image built successfully"
echo ""

# Create docker-compose for quick reference
cat > docker-compose.prod.yml << 'EOF'
version: '3.8'
services:
  emqx:
    image: emqx:delivery-timeout-linux-x86_64
    container_name: emqx-delivery-timeout
    environment:
      EMQX_NODE__COOKIE: emqx_secret_cookie
      EMQX_DASHBOARD__DEFAULT_USERNAME: admin
      EMQX_DASHBOARD__DEFAULT_PASSWORD: admin123
    ports:
      - "1883:1883"      # MQTT
      - "8883:8883"      # MQTTS
      - "8083:8083"      # WebSocket
      - "8084:8084"      # Secure WebSocket
      - "18083:18083"    # Dashboard
      - "18084:18084"    # HTTP API
    volumes:
      - emqx_data:/emqx/data
      - emqx_etc:/emqx/etc
      - emqx_log:/emqx/log
    networks:
      - emqx
    healthcheck:
      test: ["CMD", "/emqx/bin/emqx", "eval", "ok"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

volumes:
  emqx_data:
  emqx_etc:
  emqx_log:

networks:
  emqx:
    driver: bridge
EOF

echo "Step 2: Exporting image as tar package..."
docker save emqx:delivery-timeout-linux-x86_64 -o emqx-delivery-timeout-linux-x86_64.tar.gz

echo "✅ Package created: emqx-delivery-timeout-linux-x86_64.tar.gz"
echo ""

# Generate deployment instructions
cat > LINUX-DEPLOYMENT.md << 'EOF'
# EMQX with delivery.timeout - Linux x86_64 Deployment

## Package Contents
```
emqx-delivery-timeout-linux-x86_64.tar.gz  (Docker image export)
docker-compose.prod.yml                     (Quick start config)
```

## Deployment on Linux VM

### Step 1: Transfer Package to Linux VM
```bash
# From macOS:
scp emqx-delivery-timeout-linux-x86_64.tar.gz user@linux-vm:/tmp/

# On Linux VM:
cd /tmp
```

### Step 2: Load Docker Image
```bash
docker load -i emqx-delivery-timeout-linux-x86_64.tar.gz
```

### Step 3: Verify Image Loaded
```bash
docker images | grep emqx
# Should show: emqx  delivery-timeout-linux-x86_64
```

### Step 4: Run with Docker Compose
```bash
# Copy docker-compose.prod.yml to Linux VM
scp docker-compose.prod.yml user@linux-vm:~/

# On Linux VM:
cd ~
docker-compose -f docker-compose.prod.yml up -d
```

### Step 5: Verify EMQX is Running
```bash
docker ps
# Should show: emqx-delivery-timeout container running

# Check logs
docker logs -f emqx-delivery-timeout
```

### Step 6: Access Dashboard
```
URL: http://<linux-vm-ip>:18083
Username: admin
Password: admin123
```

### Step 7: Verify delivery.timeout Feature
```bash
# Execute command in container
docker exec emqx-delivery-timeout \
  /emqx/bin/emqx eval "emqx_delivery_timeout:get_stats()."

# Should output:
# #{enabled => false, timeout_ms => 30000, tracked_count => 0, ...}
```

## Command Reference

### Start
```bash
docker-compose -f docker-compose.prod.yml up -d
```

### Stop
```bash
docker-compose -f docker-compose.prod.yml down
```

### View Logs
```bash
docker logs -f emqx-delivery-timeout
```

### Access EMQX CLI
```bash
docker exec -it emqx-delivery-timeout /emqx/bin/emqx_ctl
```

### Get Event Info
```bash
docker exec emqx-delivery-timeout \
  /emqx/bin/emqx eval "emqx_rule_events:event_names()."
```

### Get Event Topic
```bash
docker exec emqx-delivery-timeout \
  /emqx/bin/emqx eval "emqx_rule_events:event_topic('delivery.timeout')."
```

## Package Size
The tar.gz file is typically 150-200MB (compressed Docker image)

## System Requirements
- Docker Engine 20.10+
- Docker Compose 2.0+
- 2GB RAM minimum
- 5GB disk space

## Troubleshooting

### Image won't load
```bash
# Check file integrity
tar -tzf emqx-delivery-timeout-linux-x86_64.tar.gz | head

# Re-download if corrupted
```

### Container won't start
```bash
# Check logs
docker logs emqx-delivery-timeout

# Check system resources
docker stats
```

### Port conflicts
If ports 1883, 18083 etc. are in use:
1. Edit docker-compose.prod.yml
2. Change port mappings (e.g., "1883:1883" → "1884:1883")
3. Restart: `docker-compose -f docker-compose.prod.yml down && up -d`

## Feature Usage

### In Dashboard
1. Login to http://<vm-ip>:18083
2. Go to "Rule Engine" → "Events"
3. Create rule with trigger "$events/delivery/timeout"
4. Set action: Webhook, Email, Kafka, etc.

### Event Details
- **Event Name**: delivery.timeout
- **Event Topic**: $events/delivery/timeout
- **Default Timeout**: 30 seconds
- **Overhead**: ~5ns when disabled, 16 bytes per tracked message when enabled

## Support
For issues with delivery.timeout feature:
1. Check module: `docker exec emqx-delivery-timeout /emqx/bin/emqx eval "code:which(emqx_delivery_timeout)."`
2. Check stats: `docker exec emqx-delivery-timeout /emqx/bin/emqx eval "emqx_delivery_timeout:get_stats()."`
3. Review logs: `docker logs emqx-delivery-timeout`
EOF

echo "✅ Created: docker-compose.prod.yml"
echo "✅ Created: LINUX-DEPLOYMENT.md"
echo ""
echo "=========================================="
echo "Package Ready for Linux VM!"
echo "=========================================="
echo ""
echo "Files to transfer:"
echo "  1. emqx-delivery-timeout-linux-x86_64.tar.gz  (Docker image)"
echo "  2. docker-compose.prod.yml                     (Config)"
echo "  3. LINUX-DEPLOYMENT.md                         (Instructions)"
echo ""
echo "Transfer command:"
echo "  scp emqx-delivery-timeout-linux-x86_64.tar.gz docker-compose.prod.yml LINUX-DEPLOYMENT.md user@linux-vm:~/"
echo ""
