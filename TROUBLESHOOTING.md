# Pi-hole DNS Service - Troubleshooting Guide

## Quick Status Check

```bash
# Everything in one command
kubectl get pod -n dns && \
kubectl logs -n dns -l app=pihole --tail=20 && \
dig @127.0.0.1 +short google.com && \
echo "✓ All checks passed"
```

## Issue: Pod Stuck in Pending

**Symptoms:**
```
NAME    READY STATUS  RESTARTS AGE
pihole  0/1   Pending 0        5m
```

**Diagnosis:**
```bash
kubectl describe pod -n dns <pod-name>
# Look for Events section
```

**Common Causes & Fixes:**

1. **Port 53 already in use**
   ```bash
   sudo ss -tlnp | grep :53
   sudo systemctl stop systemd-resolved  # or conflicting service
   kubectl delete pod -n dns <pod-name>  # Let it reschedule
   ```

2. **Host path doesn't exist**
   ```bash
   sudo mkdir -p /DATA/AppData/big-bear-pihole-unbound/{etc,dnsmasq.d,unbound}
   sudo chmod 755 /DATA/AppData/big-bear-pihole-unbound
   ```

3. **Insufficient resources**
   ```bash
   kubectl describe nodes  # Check available capacity
   # Add resource requests to deployment if needed
   ```

---

## Issue: Pod Running but DNS Not Responding

**Symptoms:**
```
pihole  1/1   Running 0  2m

$ dig @127.0.0.1 google.com
;; communications error to 127.0.0.1#53: connection refused
```

**Diagnosis:**
```bash
# Check if dnsmasq/unbound started
kubectl logs -n dns -l app=pihole

# Check port binding
sudo ss -tlnp | grep :53
# Should show: unbound and dnsmasq listening

# Connect to pod shell
kubectl exec -it -n dns <pod-name> -- /bin/bash
# Inside pod:
  ps aux | grep -E 'unbound|dnsmasq'
  netstat -tlnp | grep 53
```

**Common Causes & Fixes:**

1. **Unbound failed to start (check logs for details)**
   ```bash
   kubectl logs -n dns -l app=pihole | grep -i unbound
   ```
   
   If `unbound-anchor` timeout:
   - Logs show "timeout" or "connection refused"
   - This is expected if no network egress
   - Unbound still works without DNSSEC validation
   - Verify with: `dig @127.0.0.1 +dnssec google.com`

2. **dnsmasq port conflict**
   ```
   Failed to create listening socket for port 53: Address in use
   ```
   - Kill conflicting process: `sudo lsof -i :53`
   - Or use different port in dnsmasq config

3. **Permission denied on host path**
   ```bash
   ls -la /DATA/AppData/big-bear-pihole-unbound/etc
   # Should be writable by UID 1000 (pihole user)
   sudo chmod 755 /DATA/AppData/big-bear-pihole-unbound
   sudo chmod 755 /DATA/AppData/big-bear-pihole-unbound/etc
   ```

---

## Issue: Pod Repeatedly Crashes (CrashLoopBackOff)

**Symptoms:**
```
pihole  0/1   CrashLoopBackOff 15 (5s ago) 3m
```

**Diagnosis:**
```bash
kubectl logs -n dns -l app=pihole --tail=50
# Look for error messages in last 50 lines

# Check restart policy
kubectl get deploy -n dns pihole -o yaml | grep -A 3 restartPolicy
```

**Common Causes & Fixes:**

1. **Missing startup script**
   ```
   /bin/sh: exec: line X: /start.sh: not found
   ```
   - Correct path: `/start-unbound.sh` (not `/start.sh`)
   - Verify in deployment command

2. **Volume mount permission issue**
   ```
   permission denied
   ```
   ```bash
   sudo chmod 755 /DATA/AppData/big-bear-pihole-unbound
   sudo chown -R 1000:1000 /DATA/AppData/big-bear-pihole-unbound/etc
   ```

3. **Liveness probe failing immediately**
   - Increase `initialDelaySeconds` to 120 (pod needs time to start)
   - Logs show: `Readiness probe failed: connection refused`
   - Normal during startup; will pass after services start

---

## Issue: DNS Queries Slow or Timing Out

**Symptoms:**
```bash
$ dig @10.0.9.99 google.com
# Takes 10+ seconds or times out
```

**Diagnosis:**
```bash
# Check pod CPU/memory
kubectl top pod -n dns <pod-name>

# Check query logs
kubectl logs -n dns -l app=pihole | grep -i "query\|slow"

# Inside pod, check unbound performance
kubectl exec -n dns <pod-name> -- unbound-control stats | grep "queries"
```

**Common Causes & Fixes:**

1. **High query volume overwhelming pod**
   - Add resource limits: `limits.cpu: 500m, memory: 512Mi`
   - Scale to 2 replicas (requires load balancer setup)

2. **Recursive resolution taking too long**
   - Check unbound config: `cat /etc/unbound/unbound.conf`
   - Verify upstream is working: `dig @1.1.1.1 google.com`
   - Add `prefetch: yes` to unbound config

3. **Database corruption**
   - Clear Pi-hole query history via UI
   - Or: `kubectl exec -n dns <pod-name> -- sqlite3 /etc/pihole/pihole-FTL.db "DELETE FROM queries;"`

---

## Issue: Cannot Access Pi-hole Web UI

**Symptoms:**
```
Cannot connect to http://10.0.9.99:8001
```

**Diagnosis:**
```bash
# Check if port 8001 is listening
sudo ss -tlnp | grep 8001

# Check pod logs for web server errors
kubectl logs -n dns -l app=pihole | grep -i "web\|http\|8001"

# Test connectivity from host
curl -s http://127.0.0.1:8001 | head -20
```

**Fixes:**
1. Check host firewall: `sudo ufw status`
2. Verify port mapping: `docker port <container> 8001` (if using Docker)
3. Check Pi-hole web server config: `/DATA/AppData/big-bear-pihole-unbound/etc/pihole-FTL.conf`

---

## Issue: DNS Works from Host, Not from Tailscale

**Symptoms:**
```bash
# Host:
$ dig @10.0.9.99 google.com  # Works

# Tailscale client:
$ dig @100.71.53.83 google.com  # Fails or times out
```

**Diagnosis:**
```bash
# Check Tailscale configuration
tailscale dns  # Should show 10.0.9.99 and 100.71.53.83

# Test connectivity to Tailscale IP
ping 100.71.53.83

# Check pod routing on NUCUBT01
ip route | grep -E 'default|100.71'
```

**Fixes:**
1. Re-apply Tailscale nameservers:
   ```bash
   tailscale dns --set-nameservers 10.0.9.99 100.71.53.83
   ```

2. Restart Tailscale daemon:
   ```bash
   sudo systemctl restart tailscaled
   ```

3. Verify pod is listening on all interfaces:
   ```bash
   kubectl exec -n dns <pod-name> -- netstat -tlnp | grep 53
   # Should show 0.0.0.0:53 (all interfaces) due to hostNetwork=true
   ```

---

## Issue: Unbound-anchor Timeout on Startup

**Symptoms:**
```
2026-10-01T... timeout 10 unbound-anchor -a /var/lib/unbound/root.key
# Takes 10+ seconds, eventually times out or fails
```

**Expected Behavior:**
- This is OK! The pod continues despite timeout
- Unbound still works without DNSSEC validation
- DNS queries work normally

**If You Need DNSSEC Validation:**
1. Install WARP CLI on host or in container:
   ```bash
   curl https://pkg.cloudflareclient.com/pubkey.gpg | sudo apt-key add -
   sudo apt-get install cloudflare-warp
   ```

2. Start WARP daemon:
   ```bash
   sudo warp-cli connect
   ```

3. Restart pod:
   ```bash
   kubectl rollout restart deploy/pihole -n dns
   ```

---

## Emergency: Pod Completely Down

**Immediate Recovery:**
```bash
# 1. Check if K8s is responding
kubectl cluster-info

# 2. Force restart pod
kubectl delete pod -n dns -l app=pihole

# 3. Watch it come back online
kubectl get pod -n dns --watch

# 4. Verify DNS working
dig @10.0.9.99 google.com

# If still failing after 2 minutes:
kubectl logs -n dns -l app=pihole --tail=100 | head -50
```

**If Restart Loop Persists:**
1. Check host:
   ```bash
   docker ps  # Or podman ps
   systemctl status kubelet
   dmesg | tail -50  # Kernel messages
   ```

2. Isolate pod (remove from load):
   ```bash
   kubectl scale deploy pihole -n dns --replicas=0
   ```

3. Investigate manually:
   ```bash
   # Try starting container directly
   podman run -it --rm bigbeartechworld/big-bear-pihole-unbound:2026.04.0 /bin/bash
   ```

---

## Getting Help

1. **Collect diagnostic data:**
   ```bash
   kubectl describe pod -n dns <pod-name>
   kubectl logs -n dns -l app=pihole --tail=200
   dig +trace @10.0.9.99 google.com
   dig @10.0.9.99 +dnssec google.com
   ```

2. **Check related systems:**
   - K8s cluster: `kubectl cluster-info`
   - Docker/Podman: `docker version` or `podman version`
   - Network: `ip route`, `ip addr`, `ss -tlnp | grep 53`
   - Tailscale: `tailscale status`, `tailscale dns`

3. **Search logs for errors:**
   ```bash
   kubectl logs -n dns -l app=pihole | grep -i "error\|fail\|critical"
   ```
