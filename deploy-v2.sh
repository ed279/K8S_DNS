#!/bin/bash
# Deploy Pi-hole DNS v2 (Multi-container: WARP + Tailscale + DNS)
# NUCUBT01 Critical Service - Cohesive Architecture

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  K8s Pi-hole DNS v2 - Multi-Container Deployment           ║"
echo "║  WARP + Tailscale + Pi-hole + Unbound (Cohesive Pod)      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check prerequisites
echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"
if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}ERROR: kubectl not found${NC}"
    exit 1
fi

if ! command -v vault &>/dev/null; then
    echo -e "${RED}ERROR: vault CLI not found (needed for Tailscale auth key)${NC}"
    exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}ERROR: K8s cluster unreachable${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

# Setup host directories
echo -e "${YELLOW}[2/6] Setting up host directories...${NC}"
HOST_PATH="/DATA/AppData/big-bear-pihole-unbound"

for dir in etc dnsmasq.d unbound; do
    if [ ! -d "$HOST_PATH/$dir" ]; then
        echo "Creating $HOST_PATH/$dir..."
        sudo mkdir -p "$HOST_PATH/$dir"
        sudo chmod 755 "$HOST_PATH/$dir"
    fi
done

# Create WARP config directory
if [ ! -d "$HOST_PATH/../warp-cli" ]; then
    echo "Creating $HOST_PATH/../warp-cli..."
    sudo mkdir -p "$HOST_PATH/../warp-cli"
    sudo chmod 755 "$HOST_PATH/../warp-cli"
fi

# Initialize default unbound.conf if missing
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

echo -e "${GREEN}✓ Host directories ready${NC}"
echo ""

# Get Tailscale auth key from Vault
echo -e "${YELLOW}[3/6] Fetching Tailscale auth key from Vault...${NC}"
TSKEY=$(vault kv get -field=value secret/tailscale/auth-key 2>/dev/null)

if [ -z "$TSKEY" ]; then
    echo -e "${RED}ERROR: Tailscale auth key not found in Vault (secret/tailscale/auth-key)${NC}"
    echo "Generate one at: https://login.tailscale.com/admin/settings/keys"
    echo "Store it with: vault kv put secret/tailscale/auth-key value='tskey-...'"
    exit 1
fi

echo -e "${GREEN}✓ Tailscale auth key retrieved${NC}"
echo ""

# Create namespace and secrets
echo -e "${YELLOW}[4/6] Setting up K8s namespace and secrets...${NC}"
kubectl create namespace dns 2>/dev/null || true

# Delete old secret if exists (to avoid conflicts)
kubectl delete secret tailscale-auth -n dns 2>/dev/null || true

# Create Tailscale auth secret
kubectl create secret generic tailscale-auth \
    -n dns \
    --from-literal=TS_AUTHKEY="$TSKEY"

echo -e "${GREEN}✓ Secrets configured${NC}"
echo ""

# Deploy manifest
echo -e "${YELLOW}[5/6] Deploying v2 multi-container manifest...${NC}"
kubectl apply -f pihole-deployment-v2-multicont.yaml

echo -e "${GREEN}✓ Manifest applied${NC}"
echo ""

# Wait for pod readiness
echo -e "${YELLOW}[6/6] Waiting for pod to stabilize (this may take 60-90 seconds)...${NC}"
echo "Timeline:"
echo "  0-10s  : WARP init container setup"
echo "  10-30s : Tailscale init + Pi-hole startup"
echo "  30-60s : Startup probe validation"
echo "  60-90s : Readiness probe (dig query)"
echo ""

POD_NAME=$(kubectl get pod -n dns -l app=pihole-dns -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_NAME" ]; then
    echo -e "${YELLOW}⏳ Waiting for pod to be created...${NC}"
    sleep 10
    POD_NAME=$(kubectl get pod -n dns -l app=pihole-dns -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

if [ -n "$POD_NAME" ]; then
    kubectl wait --for=condition=Ready pod "$POD_NAME" \
        -n dns \
        --timeout=120s \
        2>/dev/null || {
        echo -e "${YELLOW}⚠ Pod may still be starting. Checking status...${NC}"
        kubectl describe pod "$POD_NAME" -n dns | grep -A 5 "State:\|Conditions:"
    }
else
    echo -e "${YELLOW}⚠ Could not find pod name. Checking manually...${NC}"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""

# Print status
echo "Pod Status:"
kubectl get pod -n dns -o wide

echo ""
echo "Container Status:"
kubectl get pod -n dns -l app=pihole-dns -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' | while read container; do
    status=$(kubectl get pod -n dns -l app=pihole-dns -o jsonpath="{.items[0].status.containerStatuses[?(@.name==\"$container\")].ready}" 2>/dev/null)
    if [ "$status" = "true" ]; then
        echo -e "  ${GREEN}✓${NC} $container"
    else
        echo -e "  ${YELLOW}⏳${NC} $container (starting)"
    fi
done

echo ""
echo "Next Steps:"
echo ""
echo "1. Check pod logs:"
echo "   kubectl logs -n dns -l app=pihole-dns -c pihole --tail=100 -f"
echo ""
echo "2. Verify WARP tunnel:"
echo "   kubectl exec -n dns <pod-name> -- ip link show | grep warp"
echo ""
echo "3. Verify Tailscale:"
echo "   kubectl exec -n dns <pod-name> -- tailscale status"
echo ""
echo "4. Test DNS (LAN):"
echo "   dig @10.0.9.99 google.com"
echo ""
echo "5. Test DNS (Tailscale exit node):"
echo "   dig @100.71.53.83 google.com"
echo ""
echo "6. Access Pi-hole Web UI:"
echo "   http://10.0.9.99:8001"
echo ""
echo "⚠ Troubleshooting:"
echo "   kubectl describe pod -n dns -l app=pihole-dns"
echo "   kubectl logs -n dns -l app=pihole-dns --all-containers=true -f"
echo ""
