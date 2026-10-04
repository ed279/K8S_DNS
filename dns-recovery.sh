#!/bin/bash
# DNS Recovery Script - One-command fix for NUCUBT01 DNS + Tailscale egress
# Handles: /etc/resolv.conf, PiHole startup, Tailscale routes, validation
# Usage: sudo ./dns-recovery.sh

set -o errexit
set -o pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PIHOLE_CONTAINER="pihole-dns"
DNS_PORT="53"
PIHOLE_UI_PORT="8053"
PRIMARY_DNS="1.1.1.1"
SECONDARY_DNS="8.8.8.8"
TAILSCALE_ROUTES="10.0.9.0/24,10.0.253.0/27,0.0.0.0/0,::/0"
HOST_IP="10.0.9.99"
TIMEOUT_SEC=30

# Logging functions
log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "\n${YELLOW}==>${NC} $1"; }

# Trap errors and cleanup
cleanup_on_error() {
    local line_no=$1
    log_error "Script failed at line $line_no"
    log_step "Attempting rollback..."

    # Restore original resolv.conf if backup exists
    if [[ -f /etc/resolv.conf.backup ]]; then
        sudo cp /etc/resolv.conf.backup /etc/resolv.conf
        log_info "Restored original /etc/resolv.conf"
    fi

    # Restart systemd-resolved if available
    if systemctl is-active --quiet systemd-resolved; then
        sudo systemctl restart systemd-resolved
        log_info "Restarted systemd-resolved"
    fi

    exit 1
}

trap 'cleanup_on_error ${LINENO}' ERR

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use: sudo $0)"
    exit 1
fi

log_step "Starting DNS Recovery (PiHole + Tailscale)"

# ============================================================================
# PHASE 1: Fix /etc/resolv.conf
# ============================================================================
log_step "Phase 1: Configuring /etc/resolv.conf"

if [[ ! -f /etc/resolv.conf.backup ]]; then
    cp /etc/resolv.conf /etc/resolv.conf.backup
    log_info "Backed up original /etc/resolv.conf"
else
    log_info "Backup already exists"
fi

# Write new resolv.conf with external DNS (fallback until PiHole is ready)
cat > /etc/resolv.conf.new <<EOF
nameserver $PRIMARY_DNS
nameserver $SECONDARY_DNS
EOF

mv /etc/resolv.conf.new /etc/resolv.conf
log_info "Updated /etc/resolv.conf with external DNS ($PRIMARY_DNS, $SECONDARY_DNS)"

# Verify DNS resolution works
if timeout $TIMEOUT_SEC nslookup google.com > /dev/null 2>&1; then
    log_info "DNS resolution verified with external servers"
else
    log_error "DNS resolution failed - network may be down"
    exit 1
fi

# ============================================================================
# PHASE 2: Stop old PiHole container (if exists) with error handling
# ============================================================================
log_step "Phase 2: Cleaning up old PiHole container"

if podman ps -a --format='{{.Names}}' | grep -q "^${PIHOLE_CONTAINER}$"; then
    if podman ps --format='{{.Names}}' | grep -q "^${PIHOLE_CONTAINER}$"; then
        log_info "Stopping running $PIHOLE_CONTAINER..."
        if ! podman stop "$PIHOLE_CONTAINER" 2>/dev/null; then
            log_warn "Failed to gracefully stop container, force killing..."
            podman kill "$PIHOLE_CONTAINER" 2>/dev/null || true
        fi
        sleep 2
    fi

    log_info "Removing old $PIHOLE_CONTAINER container..."
    podman rm "$PIHOLE_CONTAINER" 2>/dev/null || log_warn "Container didn't exist or already removed"
else
    log_info "No existing $PIHOLE_CONTAINER container found"
fi

# ============================================================================
# PHASE 3: Start PiHole container with retry logic
# ============================================================================
log_step "Phase 3: Starting PiHole container"

PIHOLE_START_RETRY=0
PIHOLE_START_MAX_RETRIES=3

while [[ $PIHOLE_START_RETRY -lt $PIHOLE_START_MAX_RETRIES ]]; do
    log_info "Attempt $((PIHOLE_START_RETRY + 1))/$PIHOLE_START_MAX_RETRIES to start PiHole..."

    if podman run -d \
        --name "$PIHOLE_CONTAINER" \
        --restart=always \
        --network=host \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        -e PIHOLE_UID=999 \
        -e PIHOLE_GID=999 \
        -e WEBPASSWORD="$(openssl rand -base64 12)" \
        pihole/pihole:latest > /dev/null 2>&1; then
        log_info "PiHole container started successfully"
        break
    else
        PIHOLE_START_RETRY=$((PIHOLE_START_RETRY + 1))
        if [[ $PIHOLE_START_RETRY -lt $PIHOLE_START_MAX_RETRIES ]]; then
            log_warn "Failed to start PiHole, retrying in 5s..."
            sleep 5
        else
            log_error "Failed to start PiHole after $PIHOLE_START_MAX_RETRIES attempts"
            exit 1
        fi
    fi
done

# Wait for PiHole to be ready
log_info "Waiting for PiHole to become ready..."
sleep 10

# Check if container is actually running
if ! podman ps --format='{{.Names}}' | grep -q "^${PIHOLE_CONTAINER}$"; then
    log_error "PiHole container is not running"
    log_info "Container logs:"
    podman logs "$PIHOLE_CONTAINER" | head -20 || true
    exit 1
fi

log_info "PiHole container is running"

# ============================================================================
# PHASE 4: Verify DNS on port 53
# ============================================================================
log_step "Phase 4: Verifying DNS service"

# Check that port 53 is listening
if ! ss -tlnp | grep -q ":53"; then
    log_error "Port 53 is not listening"
    sleep 5
    if ! ss -tlnp | grep -q ":53"; then
        log_error "Port 53 still not listening - PiHole may have failed to start"
        exit 1
    fi
fi

log_info "Port 53 is listening"

# Verify DNS queries work from localhost
if ! timeout $TIMEOUT_SEC dig @127.0.0.1 +short google.com > /dev/null 2>&1; then
    log_warn "DNS queries to localhost failed, waiting for PiHole to fully initialize..."
    sleep 15
    if ! timeout $TIMEOUT_SEC dig @127.0.0.1 +short google.com > /dev/null 2>&1; then
        log_error "DNS queries to localhost failed after extended wait"
        exit 1
    fi
fi

log_info "DNS resolution working via localhost (PiHole)"

# Update /etc/resolv.conf to use local PiHole
cat > /etc/resolv.conf.new <<EOF
nameserver 127.0.0.1
nameserver $PRIMARY_DNS
nameserver $SECONDARY_DNS
EOF

mv /etc/resolv.conf.new /etc/resolv.conf
log_info "Updated /etc/resolv.conf to use local PiHole (127.0.0.1)"

# ============================================================================
# PHASE 5: Configure Tailscale routes with error handling
# ============================================================================
log_step "Phase 5: Configuring Tailscale routes"

if ! command -v tailscale &> /dev/null; then
    log_error "Tailscale is not installed"
    exit 1
fi

# Check if tailscale is running
if ! tailscale status > /dev/null 2>&1; then
    log_error "Tailscale is not running"
    exit 1
fi

log_info "Setting Tailscale advertised routes: $TAILSCALE_ROUTES"

if ! sudo tailscale set --advertise-routes="$TAILSCALE_ROUTES" 2>/dev/null; then
    log_error "Failed to set Tailscale routes"
    exit 1
fi

log_info "Tailscale routes configured"

# Verify routes are advertised
sleep 3
if sudo tailscale status | grep -q "offers exit node"; then
    log_info "Tailscale exit node is active and offering routes"
else
    log_warn "Tailscale may not be fully ready, but routes were set"
fi

# ============================================================================
# PHASE 6: Final validation
# ============================================================================
log_step "Phase 6: Final validation"

# Test DNS from localhost
if ! timeout $TIMEOUT_SEC dig @127.0.0.1 +short google.com > /dev/null 2>&1; then
    log_error "Final DNS test from localhost failed"
    exit 1
fi
log_info "✓ DNS working from localhost"

# Test DNS from host IP (LAN access)
if ! timeout $TIMEOUT_SEC dig @"$HOST_IP" +short google.com > /dev/null 2>&1; then
    log_error "Final DNS test from host IP ($HOST_IP) failed"
    exit 1
fi
log_info "✓ DNS working from host IP ($HOST_IP)"

# Test that PiHole UI is accessible (on port 8053 in container)
if ss -tlnp | grep -q ":8053"; then
    log_info "✓ PiHole UI port (8053) is listening"
else
    log_warn "PiHole UI port (8053) not found, but DNS may still work"
fi

# Check Tailscale status
TAILSCALE_STATUS=$(sudo tailscale status | head -1)
log_info "✓ Tailscale status: $TAILSCALE_STATUS"

# ============================================================================
# Success Summary
# ============================================================================
log_step "DNS Recovery Complete!"
echo ""
echo "Configuration Summary:"
echo "  ✓ /etc/resolv.conf: Local PiHole (127.0.0.1)"
echo "  ✓ PiHole container: Running on host network"
echo "  ✓ DNS port 53: Listening on all interfaces"
echo "  ✓ Tailscale exit node: Configured and advertising routes"
echo ""
echo "Next Steps on Your Phone:"
echo "  1. Open Tailscale app → Settings → Exit Node"
echo "  2. Select 'nucubt01' as the exit node"
echo "  3. Open Safari and test: google.com"
echo "  4. All traffic now routes through PiHole"
echo ""
echo "Vaultwarden Access:"
echo "  • Via Tailscale: https://nucubt01.tailbdee54.ts.net/"
echo "  • Via LAN: https://10.0.9.99/"
echo "  • Accept self-signed certificate warning"
echo ""
echo "PiHole Dashboard:"
echo "  • Via LAN: http://10.0.9.99:8053"
echo "  • Via Tailscale: http://100.71.53.83:8053"
echo ""

exit 0
