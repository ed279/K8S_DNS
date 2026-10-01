# Pi-hole DNS v2 Deployment Guide

## What's New in v2?

**Cohesive multi-container architecture:**
- WARP tunnel (init container) + Tailscale exit node (sidecar) + DNS (main container)
- All services in one K8s pod → all fail/restart together
- No orphaned DNS without egress, no exit node without DNS

## Architecture

See `ARCHITECTURE-V2.md` for full details.

**Quick summary:**
```
WARP Tunnel ─┐
             ├─> K8s Pod (hostNetwork=true)
Tailscale ──┤      ├─ WARP init
Exit Node   │      ├─ Tailscale sidecar
            │      └─ Pi-hole + Unbound (main)
                        │
                        └─> Port :53 (LAN + Tailscale)
```

## Prerequisites

1. **K8s cluster** (v1.36+, k3s or full)
2. **kubectl** configured and working
3. **Vault CLI** (to fetch Tailscale auth key)
4. **Tailscale auth key** in Vault: `secret/tailscale/auth-key`
5. **Host paths** for persistent config

## Quick Deploy

### 1. Get Tailscale Auth Key

```bash
# Generate at: https://login.tailscale.com/admin/settings/keys
# (Create "Reusable" key)

# Store in Vault
vault kv put secret/tailscale/auth-key value='tskey-...'

# Verify
vault kv get secret/tailscale/auth-key
```

### 2. Run Deployment Script

```bash
chmod +x deploy-v2.sh
./deploy-v2.sh
```

Script will:
1. Check kubectl + vault CLI
2. Create host directories + unbound.conf
3. Fetch Tailscale auth key from Vault
4. Create K8s namespace + secrets
5. Deploy manifest
6. Wait for pod to be Ready (60-90s)

### 3. Verify Deployment

```bash
# Pod status
kubectl get pod -n dns -o wide

# All containers running?
kubectl get pod -n dns pihole-dns-xxxxx -o jsonpath='{.status.containerStatuses[*].name}'

# Check logs
kubectl logs -n dns -l app=pihole-dns -c pihole --tail=50 -f

# WARP tunnel active?
kubectl exec -n dns pihole-dns-xxxxx -- ip link show | grep warp

# Tailscale connected?
kubectl exec -n dns pihole-dns-xxxxx -- tailscale status

# DNS working?
dig @10.0.9.99 google.com
dig @100.71.53.83 google.com
```

## Startup Timeline

```
Deployment created
    ↓
WARP init container
    ├─ Checks for existing tunnel
    ├─ Starts warp-svc daemon
    ├─ Waits for tunnel (ip link show warp)
    └─ Exits (tunnel persists)
    ↓ (~5-10 seconds)
Tailscale sidecar
    ├─ Joins tailnet (auth key from Secret)
    ├─ Sets hostname (nucubt01-dns-exit)
    ├─ Advertises exit node (--advertise-exit-node)
    └─ Runs continuously (probed for health)
    ↓ (~10-15 seconds)
Pi-hole + Unbound main container
    ├─ Waits for WARP tunnel (30 retries, 2s each = 60s)
    ├─ Waits for Tailscale (30 retries, 2s each = 60s)
    ├─ Starts unbound-anchor (timeout 10s)
    ├─ Launches Pi-hole + dnsmasq
    └─ Listens on :53
    ↓ (~30-45 seconds)
Startup probe passes
    ├─ TCP connection to :53 succeeds
    └─ K8s continues startup
    ↓ (~15-30 seconds)
Readiness probe passes
    ├─ dig @127.0.0.1 google.com succeeds
    └─ Pod marked Ready, traffic accepted
    ↓
✅ TOTAL: 60-90 seconds from deployment to Ready
```

## Monitoring

### Health Checks

```bash
# WARP tunnel status
kubectl exec -n dns pihole-dns-xxxxx -- ip link show warp

# Tailscale status (should show "Hostname")
kubectl exec -n dns pihole-dns-xxxxx -- tailscale status

# DNS resolution (local)
kubectl exec -n dns pihole-dns-xxxxx -- dig @127.0.0.1 google.com +short

# DNS resolution (via Tailscale)
dig @100.71.53.83 google.com +short

# Pod events (errors/restarts)
kubectl describe pod -n dns pihole-dns-xxxxx
```

### Logs

```bash
# All container logs
kubectl logs -n dns pihole-dns-xxxxx --all-containers=true -f

# Just Pi-hole
kubectl logs -n dns pihole-dns-xxxxx -c pihole -f

# Just Tailscale
kubectl logs -n dns pihole-dns-xxxxx -c tailscale -f

# WARP init (only visible if pod restarting)
kubectl logs -n dns pihole-dns-xxxxx -c warp-init --previous
```

## Failure Scenarios

### WARP Tunnel Lost
```
Detection: Pi-hole still running, local DNS works
Recovery:  WARP daemon auto-restarts
Timeline:  5-15 seconds
```

### Tailscale Offline
```
Detection: Pod readiness probe detects tailscale status fails
Recovery:  Tailscale sidecar restarted by K8s
Timeline:  10-30 seconds
```

### Pi-hole Process Hangs
```
Detection: Readiness probe (dig @127.0.0.1) fails
Recovery:  Liveness probe kills pod, K8s restarts
Timeline:  30-60 seconds
```

### Entire Pod Crashes
```
Detection: K8s detects pod not running
Recovery:  Full startup sequence re-runs
Timeline:  60-90 seconds
```

## Migration from v1

### Keep Both Running

```bash
# v1 (old single-container)
kubectl get deploy -n dns pihole
# Result: pihole-xxxxx deployment

# v2 (new multi-container)
kubectl get deploy -n dns pihole-dns
# Result: pihole-dns-xxxxx deployment

# Both can run simultaneously
```

### Switch DNS Service

```bash
# Current Service points to v1
kubectl get svc -n dns pihole-dns -o jsonpath='{.spec.selector}'
# Result: {"app":"pihole"}

# Update to point to v2
kubectl patch svc pihole-dns -n dns -p '{"spec":{"selector":{"app":"pihole-dns"}}}'

# Verify
kubectl get endpoints -n dns pihole-dns
# Result: should show pihole-dns pod IPs
```

### Cleanup v1

```bash
# Delete v1 when confident v2 is stable
kubectl delete deploy pihole -n dns

# Config persists (hostPath volumes)
# Both versions use same /DATA paths
```

## Troubleshooting

### Pod stuck in "Pending"

```bash
# Check events
kubectl describe pod -n dns pihole-dns-xxxxx | grep Events -A 20

# Common causes:
# - Image pull error (network issue)
# - No nodes available
# - Resource quota exceeded
```

### Containers not starting

```bash
# Check init container logs
kubectl logs -n dns pihole-dns-xxxxx -c warp-init --previous

# Check sidecar logs
kubectl logs -n dns pihole-dns-xxxxx -c tailscale

# Check main container logs
kubectl logs -n dns pihole-dns-xxxxx -c pihole
```

### DNS not resolving

```bash
# Test locally in pod
kubectl exec -n dns pihole-dns-xxxxx -- dig @127.0.0.1 google.com

# Check if unbound running
kubectl exec -n dns pihole-dns-xxxxx -- ps aux | grep unbound

# Check Pi-hole status
kubectl exec -n dns pihole-dns-xxxxx -- ps aux | grep pihole
```

### Tailscale not joining network

```bash
# Check auth key is valid
vault kv get secret/tailscale/auth-key

# Recreate secret
kubectl delete secret tailscale-auth -n dns
kubectl create secret generic tailscale-auth -n dns \
  --from-literal=TS_AUTHKEY="$(vault kv get -field=value secret/tailscale/auth-key)"

# Restart pod
kubectl rollout restart deploy/pihole-dns -n dns
```

## Performance Tuning

### Resource Limits

Current defaults:
- WARP: Not limited (init container, short-lived)
- Tailscale: 200m CPU, 256Mi memory
- Pi-hole: 500m CPU, 512Mi memory

Adjust if needed:
```bash
# Edit deployment
kubectl edit deploy -n dns pihole-dns

# Find `.spec.template.spec.containers[].resources`
# Adjust requests/limits
```

### DNS Cache Settings

Pi-hole config: `/DATA/AppData/big-bear-pihole-unbound/unbound/unbound.conf`

Key tuning parameters:
```
cache-min-ttl: 300      (minimum cache lifetime)
cache-max-ttl: 86400    (maximum cache lifetime)
prefetch: yes           (aggressive prefetching)
```

## Security

### Tailscale Auth Key

- Stored in K8s Secret `tailscale-auth`
- Sourced from Vault at deployment time
- Secret never logged or printed
- Auth key rotates per pod restart (ephemeral state)

### WARP Credentials

- Not currently implemented
- WARP uses device identity (stored in `/DATA/AppData/warp-cli`)
- Future: Vault integration for credential rotation

### DNS Privacy

- No query logging (unbound.conf: log-queries: no)
- No reply logging (unbound.conf: log-replies: no)
- DNSSEC validation (when root.key available)

## Related Documentation

- `ARCHITECTURE-V2.md` — Full architecture details
- `SELF_HEALING.md` — Self-healing probe strategies
- `DEPENDENCIES.md` — All dependencies and configs
- `README.md` — Original v1 documentation
