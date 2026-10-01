# Pi-hole DNS Service - Dependencies & Configuration

## Host Requirements

### Hardware
- **CPU:** Minimum 2 cores (1 core allocated to pod)
- **Memory:** Minimum 512MB (Pod requests: none specified, can add limits)
- **Disk:** 
  - `/DATA/AppData/big-bear-pihole-unbound/`: Minimum 1GB
  - Query history database grows over time (can be pruned via Pi-hole UI)

### Network
- **Port 53:** Must be available on host network (TCP/UDP)
  - Check: `sudo ss -tlnp | grep :53`
  - Conflicts: systemd-resolved, other DNS daemons
- **Port 8001:** Pi-hole web UI (optional, internal only)
- **egress:** Network access for:
  - `unbound-anchor`: DNSSEC root key fetch (optional, gracefully skipped if unavailable)
  - Container image pull (one-time: `bigbeartechworld/big-bear-pihole-unbound:2026.04.0`)

### Operating System
- **Linux:** Debian/Ubuntu based (Ubuntu 26.04 tested)
- **Kubernetes:** v1.36+ (k3s or full cluster)
- **Container runtime:** containerd or Docker (via K8s)

---

## Kubernetes Requirements

### Cluster Configuration
- **API Server:** Accessible from deployment node
- **Kubelet:** Running on NUCUBT01 (single-node deployment)
- **Network mode:** Direct host network access required (`hostNetwork: true`)

### Namespace & RBAC
```bash
# Namespace automatically created by manifest
kubectl create namespace dns  # or apply manifest first

# No special RBAC needed (default service account sufficient)
```

### Networking Policy
- No NetworkPolicies should block port 53 to/from pod
- Check: `kubectl get networkpolicy -n dns`

---

## Host Configuration Files

### Path: `/DATA/AppData/big-bear-pihole-unbound/`

#### `etc/` Directory
- **pihole-FTL.conf** - Main Pi-hole configuration
  - Contains: Admin password, API token, FTL settings
  - Owner: UID 1000 (pihole user in container)
  - Permissions: 644 (readable by pod)
  
- **pihole-FTL.db** - SQLite query/whitelist/blacklist database
  - Contains: Query history, adlist entries, regex filters
  - Size: Grows over time (can reach 100MB+ in production)
  - Backup before major upgrades

- **gravity.db** - Pi-hole gravity database (newer versions)
  - Replaces pihole-FTL.db in newer versions
  - Same ownership/permission requirements

- **tls.pem** - TLS certificate for web UI (HTTPS)
  - Auto-generated if missing
  - Optional: Can be replaced with Tailscale cert

#### `dnsmasq.d/` Directory
- **05-pihole-custom-cname.conf** - Custom CNAME records
- **06-rfc6761.conf** - RFC 6761 special domains (e.g., .local)
- **Custom config files** - User-added configurations

#### `unbound/` Directory
- **unbound.conf** - Unbound recursive resolver configuration
  - Port: 5353 (internal, only accessible from dnsmasq)
  - Access control: localhost only (via 127.0.0.1)
  - Example provided in `deploy.sh`

---

## Container Image Dependencies

### Image: `bigbeartechworld/big-bear-pihole-unbound:2026.04.0`

#### Included Components
| Component | Version | Purpose |
|-----------|---------|---------|
| Pi-hole FTL | Latest | DNS blocking, analytics, UI |
| Unbound | Latest | Recursive DNS resolver |
| dnsmasq | Latest | DNS caching, forwarding |
| ca-certificates | Latest | TLS root CA bundle |

#### NOT Included
| Component | Required? | Workaround |
|-----------|-----------|-----------|
| WARP CLI | Optional | Host WARP (if needed for egress) |
| systemd | Not needed | Container-based startup |
| dbus | Not needed | WARP daemon communication |

---

## Network Configuration

### Tailscale DNS Settings
**Location:** `https://login.tailscale.com/admin/dns`

```
Global nameservers:
  - 10.0.9.99        (LAN IP, direct)
  - 100.71.53.83     (Tailscale IP, via exit node)

Split DNS: (Not configured - all queries use global nameservers)
```

**Required Action:** Configure manually or via tailscale CLI:
```bash
tailscale dns --set-nameservers 10.0.9.99 100.71.53.83
```

### LAN DNS (DHCP/Static)
- **Router DNS settings:** Point to 10.0.9.99
- **Static clients:** Use 10.0.9.99 as primary, 1.1.1.1 as fallback

### K8s Pod DNS
- **dnsPolicy: None** - Override cluster DNS
- **nameservers: [127.0.0.1]** - Query Unbound on localhost
- Pods without `dnsPolicy: None` will still use coredns (disabled)

---

## Vault & Secrets Configuration

### Current Status
- **Vault Integration:** NOT currently used
- **Secrets Stored:** None (configuration files are plaintext)

### Future Considerations
If secrets management is needed:

**Vault Paths (proposed):**
```
secret/services/pihole/
  - admin-password   # Pi-hole web UI password
  - api-token        # API token for automation
  - tls-cert         # TLS certificate (if not auto-generated)
```

**Implementation:**
1. Create Vault secret:
   ```bash
   vault kv put secret/services/pihole/admin-password value="<password>"
   ```

2. Modify deployment to use Vault Agent or external-secrets:
   ```yaml
   - ExternalSecret (recommended) pulls from Vault
   - Creates K8s Secret
   - Pod mounts Secret as volume
   ```

3. Update Pod to use secrets:
   ```bash
   PIHOLE_WEBPASSWORD=/secrets/admin-password /start-unbound.sh
   ```

---

## Environment Variables

No environment variables are currently required by the container.

**Optional (for future use):**
```bash
# If implementing WARP inside container:
WARP_API_TOKEN=<token>
WARP_ACCOUNT_ID=<id>

# Pi-hole tuning:
FTLCONF_dns_upstreams=127.0.0.1#5353
FTLCONF_dnsmasq_port=53
FTLCONF_webserver_port=8001
```

---

## Resource Limits

### Current Configuration
```yaml
resources:
  requests: {}     # None specified
  limits: {}       # None specified
```

### Recommended (for production)
```yaml
resources:
  requests:
    cpu: 100m           # 0.1 core minimum
    memory: 256Mi       # 256MB minimum
  limits:
    cpu: 500m           # 0.5 core max
    memory: 512Mi       # 512MB max
```

---

## Backup & Recovery

### What to Backup
1. **Configuration Files:**
   ```bash
   sudo tar czf /backups/pihole-$(date +%Y%m%d).tar.gz \
     /DATA/AppData/big-bear-pihole-unbound/
   ```

2. **Database (Query History):**
   - Part of config backup
   - Can be trimmed via Pi-hole UI if space is critical

### Recovery Procedure
1. Stop pod: `kubectl delete pod -n dns <pod-name>`
2. Restore files: `sudo tar xzf /backups/pihole-YYYYMMDD.tar.gz -C /`
3. Restart: `kubectl rollout restart deploy/pihole -n dns`
4. Verify: `dig @10.0.9.99 google.com`

---

## Monitoring & Observability

### Logs
```bash
# Real-time logs
kubectl logs -n dns -l app=pihole -f

# Historical logs (last 1000 lines)
kubectl logs -n dns -l app=pihole --tail=1000
```

### Metrics (Not Currently Exported)
- Pi-hole query stats: Available via web UI
- Unbound performance: Query times, cache hit rate
- System metrics: CPU, memory usage

**Future:** Add Prometheus exporter for automated monitoring

### Alerts (Not Currently Configured)
Recommended:
- Pod not Ready for >5 minutes
- DNS query latency >500ms
- High query error rate (>5%)

---

## Related Systems

### WARP (Cloudflare)
- **Purpose:** Egress tunnel for container network fetch
- **Status:** Configured on host, NOT in container
- **Impact:** `unbound-anchor` gracefully skips if WARP unavailable

### Tailscale
- **Purpose:** Secure network tunnel, exit node
- **Status:** Running on NUCUBT01
- **DNS Integration:** Global nameservers configured (see above)

### Vaultwarden (Future)
- **Purpose:** Password manager, runs in separate container
- **DNS:** Will use Pi-hole service when deployed
- **HTTPS:** Can use Tailscale cert (domain: nucubt01.tailbdee54.ts.net)

---

## Troubleshooting Checklist

- [ ] Pod status: `kubectl get pod -n dns`
- [ ] Pod logs: `kubectl logs -n dns -l app=pihole`
- [ ] Port 53 availability: `sudo ss -tlnp | grep 53`
- [ ] DNS resolution: `dig @10.0.9.99 google.com`
- [ ] Host path permissions: `ls -la /DATA/AppData/big-bear-pihole-unbound/`
- [ ] Image availability: `docker pull bigbeartechworld/big-bear-pihole-unbound:2026.04.0`
- [ ] K8s coredns disabled: `kubectl get deploy -n kube-system coredns`
