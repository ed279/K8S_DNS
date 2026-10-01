# Pi-hole + Unbound DNS Service (K8s Deployment)

Critical DNS service for NUCUBT01 Kubernetes cluster. Provides recursive DNS with Pi-hole blocking to all networks.

## Overview

**Status:** ✅ Production (2026-10-01)  
**Service:** `pihole` namespace, `dns` deployment  
**Networks Served:**
- LAN: `10.0.9.0/24`
- Wireless: `10.0.253.0/27`
- Tailscale: `100.71.x.x` (exit node DNS)
- K8s pods: via `dnsPolicy: None`

## Architecture

```
┌─────────────────────────────────────────┐
│  K8s Pihole Pod (hostNetwork=true)      │
├─────────────────────────────────────────┤
│ unbound (recursive resolver, :5353)     │
│ dnsmasq (caching + Pi-hole, :53)        │
│ pihole-FTL (analytics + UI, :8001)      │
└─────────────────────────────────────────┘
     ↓
  Port 53 (TCP/UDP) - host network
     ↓
┌─────────────────────────────────────────┐
│ All clients (LAN, Tailscale, K8s)       │
└─────────────────────────────────────────┘
```

## Dependencies

### Runtime
- **Image:** `bigbeartechworld/big-bear-pihole-unbound:2026.04.0`
  - Includes: Pi-hole FTL, Unbound, dnsmasq
  - Note: Does NOT include WARP CLI (see WARP below)

### Host Volumes (Persistent)
- `/DATA/AppData/big-bear-pihole-unbound/etc/` → `/etc/pihole`
  - Pi-hole configuration, gravity database, adlists
  - **Owner:** Keep accessible; pod runs as UID 1000 (pihole user)

- `/DATA/AppData/big-bear-pihole-unbound/dnsmasq.d/` → `/etc/dnsmasq.d`
  - dnsmasq config snippets

- `/DATA/AppData/big-bear-pihole-unbound/unbound/` → `/etc/unbound`
  - Unbound recursive resolver config

### Network Mode
- **hostNetwork: true** - Pod uses host's network namespace
  - Allows binding port 53 directly
  - Container inherits host's WARP egress (if running)

### DNS Resolver Strategy
- **dnsPolicy: None** - Use explicit nameservers
- **dnsConfig.nameservers: [127.0.0.1]** - Pod resolves via localhost (Unbound)

### Kubernetes DNS
- **coredns:** Disabled (conflicts with port 53)
- **Alternative:** Pihole serves K8s pods when they query 10.0.9.99:53

## Known Issues & Workarounds

### Issue: `unbound-anchor` hangs on startup

**Root Cause:**  
`unbound-anchor` (DNSSEC tool) attempts to download root trust anchor from internet. Without WARP egress or network access, it hangs indefinitely.

**Workaround (Implemented):**  
Wrapped in `timeout 10` with fallback:
```bash
timeout 10 unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || touch /var/lib/unbound/root.key
```
- Attempts fetch for 10s
- If timeout/failure, creates empty file to continue startup
- Unbound still works without DNSSEC validation (acceptable for internal DNS)

**Future Fix:**  
- Install warp-cli in image
- Start WARP tunnel before unbound-anchor
- Add WARP config to container startup

## Deployment

### Prerequisites
```bash
# Namespace must exist
kubectl create namespace dns

# Host paths must exist and be readable
sudo mkdir -p /DATA/AppData/big-bear-pihole-unbound/{etc,dnsmasq.d,unbound}
sudo chmod 755 /DATA/AppData/big-bear-pihole-unbound
```

### Deploy
```bash
kubectl apply -f pihole-deployment.yaml
kubectl get pod -n dns  # Should be 1/1 Running
```

### Verify
```bash
# Test from localhost
dig @127.0.0.1 +short google.com

# Test from LAN
dig @10.0.9.99 +short google.com

# Test from Tailscale
dig @100.71.53.83 +short google.com
```

## Configuration

### Tailscale DNS Settings
In Tailscale admin console (`https://login.tailscale.com/admin/dns`):
- **Global nameservers:** 
  - `10.0.9.99`
  - `100.71.53.83` (via Pihole pod on exit node)
- **Route split DNS:** Not configured (all queries use global)

### LAN DNS (DHCP)
Router/DHCP server should advertise:
- Primary: `10.0.9.99`
- Secondary: Fallback (1.1.1.1)

### Pi-hole Web UI
- URL: `http://10.0.9.99:8001`
- Password: Check `/DATA/AppData/big-bear-pihole-unbound/etc/pihole-FTL.conf`

## Maintenance

### Restart Pod
```bash
kubectl rollout restart deploy/pihole -n dns
```

### View Logs
```bash
kubectl logs -n dns -l app=pihole --tail=100 -f
```

### Backup Configuration
```bash
sudo tar czf /backups/pihole-config-$(date +%Y%m%d).tar.gz \
  /DATA/AppData/big-bear-pihole-unbound/
```

### Restore Configuration
```bash
sudo tar xzf /backups/pihole-config-YYYYMMDD.tar.gz -C /
kubectl rollout restart deploy/pihole -n dns
```

## Troubleshooting

### DNS not resolving
1. Check pod status: `kubectl get pod -n dns`
2. Check logs: `kubectl logs -n dns deploy/pihole`
3. Verify port 53: `sudo ss -tlnp | grep 53`
4. Test from pod: `kubectl exec -n dns <pod-name> -- dig @127.0.0.1 google.com`

### High CPU/Memory
1. Check unbound stats: `unbound-control stats` (if available)
2. Review Pi-hole gravity database size
3. Consider pruning query history in Pi-hole UI

### No internet access after deployment
1. Verify WARP is running on host (if needed)
2. Check Tailscale exit node status
3. Test direct internet: `curl -v https://1.1.1.1`

## Future Improvements

- [ ] Add WARP CLI to container image for proper egress
- [ ] Implement ConfigMap for Unbound/dnsmasq tuning
- [ ] Add Pi-hole adlist automation
- [ ] Set up cross-node Pi-hole replica for HA
- [ ] Metrics/monitoring: Prometheus exporter
- [ ] Vaultwarden DNS integration (Tailscale cert)

## Related Documentation

- [NUCUBT01 Homelab Setup](../docs/NUCUBT01.md)
- [Tailscale Configuration](../docs/tailscale.md)
- [K8s Continuity Initiative](../docs/k8s-migration.md)
