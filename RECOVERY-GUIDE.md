# DNS Recovery Guide

If your DNS or Tailscale egress configuration goes down, use the automated recovery script to restore everything in one command.

## Quick Fix (One Command)

```bash
sudo ./dns-recovery.sh
```

This script automatically:
1. ✅ Fixes `/etc/resolv.conf` with fallback DNS
2. ✅ Starts/restarts PiHole container
3. ✅ Validates DNS is working
4. ✅ Configures Tailscale exit node + routes
5. ✅ Tests end-to-end connectivity

If anything fails, it rolls back automatically.

## What Gets Fixed

### /etc/resolv.conf
- **Backup:** Saves original to `/etc/resolv.conf.backup` before changes
- **During startup:** Uses external DNS (1.1.1.1, 8.8.8.8) until PiHole is ready
- **After PiHole:** Updates to use local PiHole (127.0.0.1) with external fallback

### PiHole Container
- **Cleanup:** Removes any stale/crashed containers
- **Start:** Launches fresh PiHole with proper networking
- **Retry:** Attempts up to 3 times if startup fails
- **Port 53:** Verifies DNS is listening on all interfaces

### Tailscale Routes
- **IPv4 routes:** `10.0.9.0/24`, `10.0.253.0/27`, `0.0.0.0/0`
- **IPv6 routes:** `::/0`
- **Exit node:** Enabled for phone VPN access

### Validation
- DNS resolution to 127.0.0.1 (localhost PiHole)
- DNS resolution to 10.0.9.99 (LAN access)
- Port 53 listening (TCP/UDP, IPv4/IPv6)
- Tailscale exit node status

## Error Recovery

If the script fails:

1. **Check error message** — states which phase failed
2. **Automatic rollback** — `/etc/resolv.conf` restored from backup
3. **Review logs** — the script logs all operations in color

## Manual Recovery (if script fails)

### Restore DNS Manually
```bash
# Use external DNS until investigation
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
```

### Check PiHole Status
```bash
# Is container running?
podman ps | grep pihole

# View logs
podman logs pihole-dns | tail -50

# Check port 53
sudo ss -tlnp | grep 53
```

### Restart Tailscale Routes
```bash
sudo tailscale set --advertise-routes=10.0.9.0/24,10.0.253.0/27,0.0.0.0/0,::/0
```

## Testing After Recovery

### From Server
```bash
# Test localhost PiHole
dig @127.0.0.1 google.com

# Test from LAN
dig @10.0.9.99 google.com

# Test from Tailscale
dig @100.71.53.83 google.com
```

### From Phone (via Tailscale)
1. Open Tailscale app
2. Settings → Exit Node → Select **nucubt01**
3. Open Safari → Visit `google.com` (should load)
4. Try Vaultwarden: `https://nucubt01.tailbdee54.ts.net/`

## Configuration Details

### PiHole Container
- **Name:** `pihole-dns`
- **Network:** Host (inherits NUCUBT01's network stack)
- **Restart policy:** Always (auto-restart on crash)
- **Capabilities:** NET_ADMIN, NET_RAW (required for DNS)

### Tailscale Routes
The script configures:
- **LAN network:** `10.0.9.0/24` (Ethernet)
- **Wireless network:** `10.0.253.0/27` (WiFi)
- **Default route:** `0.0.0.0/0` (all IPv4 internet)
- **IPv6 default:** `::/0` (all IPv6 internet)

## Troubleshooting

### DNS not resolving from phone
- Check Tailscale app — is exit node set to **nucubt01**?
- Run script again: `sudo ./dns-recovery.sh`
- Verify PiHole is running: `podman ps | grep pihole`
- Check port 53: `sudo ss -tlnp | grep 53`

### Internet access works but slow
- This is normal during first DNS queries (unbound caching)
- Wait 30 seconds and retry
- Check PiHole logs: `podman logs pihole-dns | tail -20`

### PiHole container won't start
- Check logs: `podman logs pihole-dns`
- Remove container: `podman rm pihole-dns`
- Restart script: `sudo ./dns-recovery.sh`

## Accessing Services After Recovery

### Vaultwarden Password Manager
- **Via Tailscale:** `https://nucubt01.tailbdee54.ts.net/`
- **Via LAN:** `https://10.0.9.99:443/`
- **Via Tailscale IP:** `https://100.71.53.83:443/`

### PiHole Dashboard
- **Via LAN:** `http://10.0.9.99:8053`
- **Via Tailscale:** `http://100.71.53.83:8053`

## Version History

- **2026-10-04:** Initial release with PiHole Docker deployment
