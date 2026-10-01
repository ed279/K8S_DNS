# Pi-hole DNS v2 Architecture - Cohesive Multi-Container Pod

**Design Philosophy:** Single failure domain. WARP egress + Tailscale exit node + DNS service all live-die together.

## v1 vs v2 Comparison

| Aspect | v1 (Current K8s) | v2 (Proposed Multi-Container) |
|--------|------------------|------------------------------|
| WARP | Host systemd (separate) | Pod init container (cohesive) |
| Tailscale | Host systemd (separate) | Pod sidecar (cohesive) |
| Pi-hole + Unbound | Main pod container | Main pod container |
| Failure mode | Pod crash ≠ WARP/TS crash | Pod crash = all services restart |
| Egress availability | Decoupled (risky) | Guaranteed with DNS pod |
| Exit node availability | Decoupled (risky) | Guaranteed with DNS pod |
| Startup complexity | Simple | Moderate (init dependencies) |
| Self-healing scope | DNS pod only | Entire service stack |

---

## v2 Architecture: Multi-Container Pod

```
┌─────────────────────────────────────────────────────────┐
│           K8s Pod (hostNetwork=true)                    │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  [Init Container: WARP]                                │
│  - Establishes Cloudflare tunnel                        │
│  - Sets up warp interface (net.ipv4.conf.all.src_valid) │
│  - Exits when tunnel ready                              │
│  └─> Creates persistent tunnel (survives pod runtime)  │
│                                                          │
│  [Sidecar: Tailscale]                                  │
│  - Joins tailnet (auth key from Vault)                 │
│  - Advertises exit node (--advertise-exit-node)        │
│  - Runs continuously, probed for health                 │
│  └─> Listens on 100.71.53.83 (via hostNetwork)        │
│                                                          │
│  [Main: Pi-hole + Unbound]                             │
│  - Waits for WARP tunnel (checks ip link/route)        │
│  - Waits for Tailscale (checks tailscale status)       │
│  - Starts unbound-anchor (timeout 10s, graceful fail)  │
│  - Launches Pi-hole + dnsmasq on :53                   │
│  └─> Queries via both egress paths                     │
│                                                          │
│  [Shared Network Namespace]                            │
│  - All containers inherit hostNetwork=true             │
│  - WARP tunnel visible to all containers               │
│  - Port 53 bound by Pi-hole (visible to host + K8s)   │
│  - Tailscale routes DNS via exit node                  │
│                                                          │
└─────────────────────────────────────────────────────────┘
     ↓ (single pod failure = all services restart)
     ↓
┌──────────────────────────────────────────┐
│ K8s Self-Healing (unified)               │
│ • Startup probe: 90s grace               │
│ • Readiness probe: dig @127.0.0.1       │
│ • Liveness probe: TCP :53 every 10s     │
│ • PDB: Block voluntary eviction         │
│ • Resources: 256Mi-512Mi, 100m-500m CPU │
└──────────────────────────────────────────┘
```

---

## Startup Sequence

### Phase 1: Init Containers (Sequential)

**WARP Init Container:**
```
1. Check if warp interface already exists (idempotent)
2. If not: start warp-svc daemon in background
3. Wait for interface to appear (ip link show warp)
4. Mark init complete, exit (tunnel persists)
```

**Result:** Tunnel active, visible to other containers via shared hostNetwork.

### Phase 2: Main Container Startup

**Pi-hole + Unbound:**
```
1. Wait for WARP tunnel
   - Check: ip route show | grep warp OR ip link show | grep warp
   - Timeout: 60s (30 iterations × 2s)
   - If timeout: pod fails startup probe, K8s restarts

2. Wait for Tailscale
   - Check: tailscale status | grep "Hostname"
   - Timeout: 60s (30 iterations × 2s)
   - If timeout: pod fails startup probe, K8s restarts

3. Start DNS services
   - unbound-anchor: timeout 10s, graceful fallback to empty root.key
   - Pi-hole + dnsmasq: bind :53 via hostNetwork
   - Queries route via WARP (egress) + Tailscale (exit node)
```

**Timeline:**
```
0s   - Pod created, WARP init starts
5s   - WARP tunnel up, Pi-hole container starts
10s  - Startup probe begins (TCP :53)
30s  - Tailscale ready, DNS queries flowing
40s  - Readiness probe passes (dig @127.0.0.1)
45s  - Pod marked Ready, traffic accepted
```

---

## Failure Scenarios & Recovery

### Scenario 1: WARP Tunnel Drops

**Detection:**
- Pi-hole still runs, port 53 still bound
- Readiness probe succeeds (local query works)
- But egress queries fail (DNSSEC, external DNS)

**Recovery:**
```
1. Readiness probe passes (local DNS works)
2. Liveness probe fails? (not immediately, just slow)
3. K8s doesn't kill pod yet (TCP :53 still responds)
4. WARP daemon auto-restarts (restart: unless-stopped)
5. Tunnel re-establishes, egress queries resume
```

**Improvement:** Add WARP health probe to force restart:
```bash
# Check if tunnel is active
if ! (ip link show | grep -q warp); then
  # Tunnel down, trigger restart
  exit 1
fi
```

### Scenario 2: Tailscale Exit Node Offline

**Detection:**
- Pod running, DNS queries succeed via LAN (10.0.9.99)
- Tailscale clients can't reach 100.71.53.83

**Recovery:**
```
1. Tailscale sidecar liveness probe fails (no Hostname in status)
2. K8s restarts Tailscale sidecar (only)
3. If entire pod needed: liveness probe at Pi-hole level fails
4. Full pod restart, all services recover together
```

### Scenario 3: Pi-hole Process Hangs

**Detection:**
- Port 53 still bound (liveness probe passes TCP)
- Queries timeout (readiness probe fails: dig hangs)

**Recovery:**
```
1. Readiness probe fails 3 times in 30s
2. Traffic diverted (if using Service)
3. After 30s: liveness probe also fails
4. Pod killed + restarted by K8s
5. Full startup sequence re-runs (includes WARP wait, Tailscale wait)
```

### Scenario 4: Entire Pod Crashes

**Detection:** Kubelet detects pod not running

**Recovery:**
```
1. K8s immediately creates new pod
2. Init container: WARP init runs (tunnel setup)
3. Sidecar: Tailscale starts (joins tailnet)
4. Main: Pi-hole starts (waits for both, then DNS)
5. All services back online within 60-90 seconds
```

---

## Dependencies & Configurations

### Vault Secrets

```bash
# Tailscale auth key (required)
vault kv get secret/tailscale/auth-key
# Expected: {"auth_key": "tskey-..."}

# WARP credentials (optional, for egress validation)
vault kv get secret/warp/account-id
vault kv get secret/warp/device-id
```

### Host Paths

```
/DATA/AppData/big-bear-pihole-unbound/
  ├── etc/              → /etc/pihole (Pi-hole config + gravity DB)
  ├── dnsmasq.d/       → /etc/dnsmasq.d (DNS rules)
  ├── unbound/         → /etc/unbound (Unbound config)
  └── (new) warp-cli/  → /var/lib/cloudflare-warp (WARP state)

/var/lib/tailscale/   → emptyDir (Tailscale state, ephemeral)
```

### Ports (hostNetwork=true)

| Port | Service | Scope |
|------|---------|-------|
| 53/TCP | Pi-hole DNS | LAN + Tailscale + K8s |
| 53/UDP | Pi-hole DNS | LAN + Tailscale + K8s |
| 8001/TCP | Pi-hole Web UI | Internal only |

### Network Modes

- **hostNetwork: true** - All containers share host network stack
- **dnsPolicy: None** - Explicit resolver (127.0.0.1 = Unbound)
- **dnsConfig.nameservers: [127.0.0.1]** - Pod queries Unbound locally

---

## Self-Healing Probes

All probes apply to the entire pod unit:

### Startup Probe (90s grace)
```yaml
tcpSocket:
  port: 53
initialDelaySeconds: 10
periodSeconds: 5
failureThreshold: 18  # 90s total
```
**Purpose:** Allow WARP init + Tailscale join + Pi-hole startup without killing pod.

### Readiness Probe (every 10s)
```yaml
exec:
  command: [dig @127.0.0.1 +short google.com]
initialDelaySeconds: 30
periodSeconds: 10
failureThreshold: 3  # 30s to fail
```
**Purpose:** Verify DNS actually queries (not just port binding).

### Liveness Probe (every 10s, aggressive)
```yaml
tcpSocket:
  port: 53
initialDelaySeconds: 60
periodSeconds: 10
failureThreshold: 3  # 30s to kill
```
**Purpose:** Detect hangs, force restart.

---

## Deployment Steps

### 1. Pre-flight

```bash
# Ensure host paths exist
sudo mkdir -p /DATA/AppData/big-bear-pihole-unbound/{etc,dnsmasq.d,unbound}
sudo mkdir -p /DATA/AppData/warp-cli
sudo chmod 755 /DATA/AppData/big-bear-pihole-unbound

# Get Tailscale auth key from Vault
TSKEY=$(vault kv get -field=value secret/tailscale/auth-key)

# Create K8s secret
kubectl create secret generic tailscale-auth \
  -n dns \
  --from-literal=TS_AUTHKEY="$TSKEY" \
  --dry-run=client \
  -o yaml | kubectl apply -f -
```

### 2. Deploy Manifest

```bash
# Using v2 multi-container manifest
kubectl apply -f pihole-deployment-v2-multicont.yaml

# Wait for pod to stabilize
kubectl get pod -n dns -w
# Expected: pihole-dns-xxxxx 1/1 Running after 60-90s
```

### 3. Verify All Services

```bash
# Check pod containers
kubectl get pod -n dns -o wide

# Verify WARP tunnel
kubectl exec -n dns pihole-dns-xxxxx -- ip link show | grep warp

# Verify Tailscale
kubectl exec -n dns pihole-dns-xxxxx -- tailscale status

# Verify DNS (LAN)
dig @10.0.9.99 google.com

# Verify DNS (Tailscale)
dig @100.71.53.83 google.com

# Check Pi-hole web UI
curl http://10.0.9.99:8001
```

---

## Monitoring & Alerts

### Container Health Checks

```bash
# WARP tunnel status
kubectl exec -n dns pihole-dns-xxxxx -- ip link show warp

# Tailscale status
kubectl exec -n dns pihole-dns-xxxxx -- tailscale status

# DNS resolution
kubectl exec -n dns pihole-dns-xxxxx -- dig @127.0.0.1 google.com

# Pi-hole logs
kubectl logs -n dns -l app=pihole-dns -c pihole --tail=100 -f
```

### Recommended Alerts

1. **Pod not Ready for >2 minutes** → startup probe failing
2. **Pod restarted >3 times in 10 minutes** → cascading failures
3. **Readiness probe failing** → DNS queries hanging
4. **Tailscale container not running** → exit node offline
5. **WARP interface missing** → egress tunnel down

---

## Migration Path: v1 → v2

### 1. Deploy v2 Alongside v1

```bash
# Keep v1 running (old pihole-deployment.yaml)
# Deploy v2 to same namespace
kubectl apply -f pihole-deployment-v2-multicont.yaml

# v1 pod name: pihole-xxxxx
# v2 pod name: pihole-dns-xxxxx
```

### 2. Validate v2

- Check logs: `kubectl logs -n dns pihole-dns-xxxxx -c pihole`
- Test DNS: `dig @10.0.9.99 google.com`
- Verify all containers running: `kubectl get pod -n dns pihole-dns-xxxxx`

### 3. Cut Over Traffic

```bash
# Update Service selector to point to v2
kubectl patch svc pihole-dns -n dns -p '{"spec":{"selector":{"app":"pihole-dns"}}}'

# Or use Service with multiple selectors (gradual migration)
```

### 4. Decommission v1

```bash
# Delete v1 deployment
kubectl delete deploy pihole -n dns

# Keep volumes (config persists across versions)
```

---

## Known Limitations & Future Work

### Current Constraints
1. **Single pod** → no multi-region failover
2. **Single node** → no HA replica
3. **Tailscale state ephemeral** → state resets on pod restart (re-auth needed)
4. **WARP credentials not secured** → rely on host filesystem

### Future Improvements
1. **Persistent Tailscale state** → store in K8s Secret via external-secrets
2. **WARP credentials from Vault** → inject at runtime (Vault Agent sidecar)
3. **Multi-pod replica** → requires Tailscale subnet router + PodAntiAffinity
4. **Metrics exporter** → Prometheus for DNS latency, cache hit rate, tunnel uptime
5. **Automated failover DNS** → secondary DNS via external Tailscale peer

---

## Summary

✅ **Cohesive architecture:** WARP + Tailscale + DNS all in one pod  
✅ **Unified restart:** Pod failure = all services restart together  
✅ **Self-healing:** Comprehensive probes + PDB + resource limits  
✅ **Startup safety:** 90s grace for init sequence  
✅ **Graceful degradation:** unbound-anchor timeout allows startup without WARP  

**Recovery SLA:**
- **Best case:** 15-30s (isolated service crash)
- **Typical case:** 30-60s (pod restart after probe failure)
- **Worst case:** 90-120s (full startup from init + service dependencies)

**Bottom line:** DNS service stays up, egress tunnel stays up, exit node stays up — or all die and restart together. No orphaned services. No split-brain failures.
