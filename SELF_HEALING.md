# Pi-hole DNS - Self-Healing & Resilience

Critical service recovery strategies for NUCUBT01 DNS service.

## Overview

**Criticality Level:** 🔴 CRITICAL — Nothing else on the network works without DNS.

Pod recovery mechanisms:
1. **Startup Probe** — Tolerates slow startup (unbound-anchor timeout)
2. **Readiness Probe** — Validates DNS is actually responding
3. **Liveness Probe** — Detects hangs; aggressive restart
4. **Pod Disruption Budget** — Prevents eviction during cluster operations
5. **Resource Limits** — Prevents memory/CPU exhaustion
6. **Restart Policy** — Always restart failed pods

---

## Probes Explained

### Startup Probe (Initialization Safety)

```yaml
startupProbe:
  tcpSocket:
    port: dns-tcp
  initialDelaySeconds: 5       # First check at 5s
  periodSeconds: 5             # Check every 5s during startup
  failureThreshold: 15         # Fail after 75s of checks
  timeoutSeconds: 2            # Allow 2s for TCP connection
```

**What it does:**
- Allows up to 75 seconds (15 × 5s) for full startup
- Accounts for unbound-anchor timeout (10s) + initial service startup
- If startup probe fails for 75s straight, pod is restarted

**When it helps:**
- Node reboot: Pod takes 45-60s to start (unbound + Pi-hole initialization)
- Image pull: First deployment takes longer
- Degraded node: Slow disk I/O delays startup

**Recovery:** Pod automatically restarts if startup probe never succeeds.

---

### Readiness Probe (Traffic Validation)

```yaml
readinessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - "dig @127.0.0.1 +short google.com >/dev/null 2>&1"
  initialDelaySeconds: 30      # Wait 30s before checking
  periodSeconds: 10            # Check every 10s
  failureThreshold: 3          # Mark unready after 3 failures (30s)
  timeoutSeconds: 5            # Allow 5s for dig to complete
  successThreshold: 1          # Need 1 success to be ready
```

**What it does:**
- Actually queries DNS (not just checking port binding)
- If Unbound/dnsmasq hang internally, readiness fails
- Traffic stops routing to pod while it's unready
- Pod is NOT restarted, just traffic diverted (if using Service)

**When it helps:**
- Unbound deadlock: Process runs but hangs on queries
- dnsmasq crash: Port still bound but service dead
- Misconfiguration: DNS starts but doesn't actually serve

**Recovery:** Pod automatically reconnected once readiness probe succeeds.

---

### Liveness Probe (Hang Detection)

```yaml
livenessProbe:
  tcpSocket:
    port: dns-tcp
  initialDelaySeconds: 60      # Wait 60s (full startup + extra buffer)
  periodSeconds: 10            # Check every 10s
  failureThreshold: 3          # Kill after 3 failures (30s total)
  timeoutSeconds: 2            # Allow 2s for TCP connection
```

**What it does:**
- Checks if port 53 is still bound and listening
- If TCP connection fails 3 times in a row, pod is killed
- Kubelet immediately restarts pod (restartPolicy: Always)

**When it helps:**
- Port binding lost: systemd-resolved crashed, reclaimed port
- Kernel network issue: TCP stack unresponsive
- Process hang: Unbound/dnsmasq zombie process
- OOMKilled: Memory exhaustion (caught by liveness timeout)

**Recovery:** Pod automatically restarted by kubelet within seconds.

**Timeline:**
```
probe fails @ 60s
probe fails @ 70s
probe fails @ 80s
pod killed @ 80s
new pod starting @ 80-85s
```

Total downtime: ~20-25 seconds from failure to recovery.

---

### Pod Disruption Budget (Cluster Safety)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pihole-pdb
  namespace: dns
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: pihole
```

**What it does:**
- Prevents K8s from voluntarily evicting the pod
- Blocks node drains, cluster scale-downs, node maintenance
- On single-node setup, mostly documentation (can't drain the only node)
- On multi-node setup (future HA), prevents DNS loss during updates

**When it helps:**
- Node maintenance: Upgrade kernel, install patches (blocked unless you force it)
- Manual pod deletion: Protected by PDB warning
- Cluster autoscaler: Won't scale down nodes that would lose DNS

**Recovery:** Manual force-delete bypasses PDB.
```bash
kubectl delete pod -n dns <pod-name> --grace-period=0 --force
```

---

## Resource Limits (Stability)

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

**Requests:** Minimum guaranteed resources
- K8s reserves these on the node for this pod
- Used for scheduling decisions

**Limits:** Maximum allowed resources
- Pod is throttled (CPU) or killed (memory) if exceeded
- Unbound + Pi-hole typically use 150-250MB
- 512Mi limit provides 2× headroom

**When it helps:**
- Runaway query: Large DNS response floods cache (memory limit stops it)
- Infinite loop: Unbound gets stuck (CPU limit throttles it, liveness kills pod)
- Node stability: Prevents one pod from starving others

**Recovery:**
- CPU limited: Pod slows down, liveness may trigger restart
- Memory limit exceeded: Pod is OOMKilled immediately, restarts

---

## Restart Policy

```yaml
restartPolicy: Always
terminationGracePeriodSeconds: 30
```

**What it does:**
- Whenever pod dies (any reason), kubelet automatically restarts it
- Waits up to 30s for graceful shutdown before force-killing

**When it helps:**
- Liveness probe kills pod: Automatic restart within 5-10s
- OOMKilled: Automatic restart
- Image pull failure: Automatic retry with exponential backoff

**Recovery:** Pod restarts automatically; no manual intervention needed.

---

## Failure Scenarios & Recovery Times

| Scenario | Detection | Restart | Total | Automatic? |
|----------|-----------|---------|-------|-----------|
| Port binding lost | 10-20s | 5-10s | 15-30s | ✅ Yes |
| Query timeout/hang | 30s (3 probes × 10s) | 5-10s | 35-40s | ✅ Yes |
| Memory exhaustion | Immediate | 5-10s | 5-10s | ✅ Yes |
| Startup timeout | 75s | 5-10s | 80-85s | ✅ Yes |
| Node reboot | Full | 45-60s | 45-60s | ✅ Yes (auto) |
| Process hang (no port loss) | 30s (readiness) | 0 (traffic diverted) | 30s | ✅ Yes (traffic rerouted) |

**Best case:** 15-30s (port binding issue)  
**Worst case:** 80-85s (startup completely fails, retry from scratch)  
**Typical case:** 20-40s (transient hang or partial failure)

---

## Monitoring & Alerts

### Check pod status
```bash
kubectl get pod -n dns -o wide
kubectl describe pod -n dns -l app=pihole
```

### Watch logs
```bash
kubectl logs -n dns -l app=pihole -f
```

### Probe failures
```bash
# Check if pod is failing startup probe
kubectl describe pod -n dns <pod-name> | grep -A 5 startupProbe

# Check readiness status
kubectl get pod -n dns -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'

# Watch for OOMKilled (memory limit exceeded)
kubectl describe pod -n dns <pod-name> | grep -i "oom"
```

### Recommended alerts
- Pod not Ready for >2 minutes
- Pod restarted >3 times in 10 minutes
- Memory usage >400Mi (80% of limit)
- CPU throttled for >30s continuously

---

## Testing Self-Healing

### Test 1: Liveness probe recovery
```bash
# Kill the unbound process inside the pod
kubectl exec -n dns <pod-name> -- pkill -9 unbound

# Pod should die and restart within 30s
kubectl get pod -n dns -w  # Watch status change

# Verify DNS works again
dig @10.0.9.99 google.com
```

### Test 2: Readiness probe
```bash
# Block DNS responses (simulate hang)
kubectl exec -n dns <pod-name> -- sh -c "iptables -A OUTPUT -p udp --dport 5353 -j DROP"

# Readiness probe fails, traffic stops (if using Service)
kubectl get pod -n dns -o wide  # Check Ready column

# Undo the block
kubectl exec -n dns <pod-name> -- sh -c "iptables -D OUTPUT -p udp --dport 5353 -j DROP"

# Ready column should return to true
```

### Test 3: Memory limit
```bash
# Fill memory with test data
kubectl exec -n dns <pod-name> -- dd if=/dev/zero of=/tmp/test.bin bs=1M count=500

# Pod should be OOMKilled and restart
kubectl describe pod -n dns <pod-name> | grep -i "oom"

# Verify DNS works again
dig @10.0.9.99 google.com
```

---

## Emergency Recovery (Manual)

If automatic recovery fails:

### Force restart
```bash
kubectl rollout restart deploy/pihole -n dns
# Waits 30s for graceful shutdown, then restarts
```

### Force immediate restart (no grace period)
```bash
kubectl delete pod -n dns <pod-name> --grace-period=0 --force
# Pod killed immediately, new one starts
```

### Check for persistent issues
```bash
# If pod keeps crashing, check:
1. Host path permissions: sudo ls -la /DATA/AppData/big-bear-pihole-unbound/
2. Port 53 availability: sudo ss -tlnp | grep :53
3. Disk space: df -h /DATA
4. K8s events: kubectl get events -n dns
```

---

## Future Improvements

1. **Multiple replicas** (requires multi-node K8s + PodAntiAffinity)
   - Survive single pod failure
   - Load balance queries
   - Zero-downtime deployments

2. **Prometheus exporter** + alerting
   - Detect performance degradation early
   - Alert on query timeouts, cache misses
   - Track recovery time metrics

3. **Backup DNS server** (external)
   - Secondary DNS: 1.1.1.1 (Cloudflare)
   - Fallback if K8s pod down >60s
   - Requires DHCP/Tailscale config update

4. **Persistent event logging**
   - Track all pod restarts, probe failures
   - Correlate with network/host issues
   - Feed into incident response

---

## Summary

✅ **Automatic recovery:** Pod detects failure & restarts in 15-85 seconds  
✅ **Graceful startup:** Tolerates slow boot (unbound-anchor timeout)  
✅ **Traffic validation:** Readiness ensures DNS actually works  
✅ **Resource safety:** Limits prevent memory/CPU exhaustion  
✅ **Cluster protection:** PDB blocks accidental eviction  

**Bottom line:** DNS pod dies → automatic restart → DNS back online within 30-60 seconds, no manual intervention needed.
