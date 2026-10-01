#!/bin/bash
# Deploy Pi-hole DNS service to K8s
# NUCUBT01 Critical Service

set -e

echo "=== Pi-hole DNS Deployment Script ==="
echo ""

# Check prerequisites
echo "[1/4] Checking prerequisites..."
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: K8s cluster unreachable"
    exit 1
fi

# Create host directories
echo "[2/4] Setting up host directories..."
HOST_PATH="/DATA/AppData/big-bear-pihole-unbound"

for dir in etc dnsmasq.d unbound; do
    if [ ! -d "$HOST_PATH/$dir" ]; then
        echo "Creating $HOST_PATH/$dir..."
        sudo mkdir -p "$HOST_PATH/$dir"
        sudo chmod 755 "$HOST_PATH/$dir"
    fi
done

# Initialize default configs if missing
if [ ! -f "$HOST_PATH/unbound/unbound.conf" ]; then
    echo "Creating default unbound.conf..."
    sudo tee "$HOST_PATH/unbound/unbound.conf" > /dev/null <<'EOF'
server:
    port: 5353
    do-ip4: yes
    do-ip6: no
    prefer-ip6: no
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    root-hints: "/var/lib/unbound/root.hints"

    # Privacy
    hide-identity: yes
    hide-version: yes

    # Performance
    prefetch: yes
    cache-min-ttl: 300
    cache-max-ttl: 86400

    # Security
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
EOF
    sudo chmod 644 "$HOST_PATH/unbound/unbound.conf"
fi

# Deploy to K8s
echo "[3/4] Deploying to K8s..."
kubectl apply -f pihole-deployment.yaml

# Wait for pod readiness
echo "[4/4] Waiting for pod readiness (this may take 60-90 seconds)..."
kubectl wait --for=condition=Ready pod \
    -l app=pihole \
    -n dns \
    --timeout=120s \
    2>/dev/null || {
    echo "WARNING: Pod may still be starting. Check status with:"
    echo "  kubectl get pod -n dns"
    echo "  kubectl logs -n dns -l app=pihole"
}

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Check status:"
echo "  kubectl get pod -n dns"
echo "  kubectl logs -n dns -l app=pihole"
echo ""
echo "Verify DNS:"
echo "  dig @127.0.0.1 google.com"
echo "  dig @10.0.9.99 google.com"
echo "  dig @100.71.53.83 google.com"
echo ""
echo "Pi-hole UI: http://10.0.9.99:8001"
echo ""
