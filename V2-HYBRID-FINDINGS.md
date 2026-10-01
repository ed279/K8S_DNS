# v2 Hybrid Deployment Findings

**Status:** Attempted | Not Viable | v1.1 Remains Production

---

## What We Tried

Deployed v2 Hybrid (Tailscale sidecar + Pi-hole main) in single K8s pod with:
- `hostNetwork: true` (shared host network, WARP tunnel inherited)
- Tailscale sidecar (should join tailnet, advertise exit node)
- Pi-hole container (main DNS service)
- Self-healing probes (startup/readiness/liveness)

## Why It Failed

### Root Cause: Tailscale Operator Pattern Incompatibility

The `tailscale/tailscale:latest` container image is built for the **Tailscale Operator** pattern, which requires:
1. Access to K8s API server (`kubernetes.default.svc:443`)
2. Ability to read/write K8s Secrets for state management
3. RBAC permissions (get, create, patch on Events)

### The Problem in hostNetwork Pod

When running with `hostNetwork: true`:
- Pod uses host IP stack (10.0.9.99)
- `kubernetes.default.svc` is a K8s-internal DNS name that does NOT resolve in hostNetwork pods
- Tailscale container tries to access K8s API during startup
- DNS resolution fails (can't reach K8s API, can't join tailnet)
- Container crashes in CrashLoopBackOff

### Attempted Fixes (All Failed)

1. **DNS Policy: None** → Explicit 127.0.0.1 resolver
   - Problem: Pi-hole not ready yet when Tailscale starts
   - Result: DNS query on :53 fails, Tailscale crashes

2. **DNS Policy: Default** → Use host DNS (8.8.8.8)
   - Problem: `kubernetes.default.svc` doesn't resolve on host network
   - Result: K8s API lookup still fails

3. **TS_USERSPACE=true** → Disable K8s integration
   - Problem: Container image still tries K8s operator mode
   - Result: Same errors, TS_USERSPACE not honored

---

## Technical Details

**Error Log (typical):**
```
error setting up for running on Kubernetes: getting Tailscale state Secret tailscale:
Get "https://kubernetes.default.svc/api/v1/namespaces/dns/secrets/tailscale":
dial tcp: lookup kubernetes.default.svc: no such host
```

**Root Cause Analysis:**
- `tailscale/tailscale` image embeds K8s operator logic by default
- This logic runs even if not needed (no way to disable in container)
- With hostNetwork=true, K8s DNS (coredns) unreachable
- K8s API access fails, container exits

---

## Solution Path

### Option 1: v1.1 (Current — CHOSEN)
✅ **Production Ready**
- WARP + Tailscale on host (systemd services)
- Pi-hole in K8s pod with self-healing probes
- DNS works on both LAN + Tailscale endpoints
- Slightly decoupled (services on host, not in pod)
- Recovery SLA: <90 seconds guaranteed

### Option 2: Custom Tailscale Image
- Build custom Docker image with only `tailscaled` daemon (no operator)
- Remove K8s operator startup logic
- Requires maintaining custom image
- Effort: Medium | Risk: High (maintenance burden)

### Option 3: Alternative Exit Node
- Replace Tailscale sidecar with lightweight WireGuard or other VPN
- More compatible with hostNetwork pods
- Effort: High | Risk: High (complex integration)

### Option 4: v2 Full (Wait for WARP Image)
- If `caomingjun/warp:latest` becomes available, try v2 Full
- But this still requires Tailscale sidecar fix (same issue)
- Blocked: No viable WARP image source

---

## Lessons Learned

1. **Tailscale operator != standalone tailscaled**
   - Container image is tied to K8s operator pattern
   - Not suitable for direct pod deployment in hostNetwork mode

2. **hostNetwork=true breaks K8s DNS resolution**
   - kubernetes.default.svc only resolvable via coredns (127.0.0.1:10053)
   - hostNetwork pods bypass pod DNS, get host resolver instead
   - Breaks services expecting K8s API access

3. **Init container sequencing crucial**
   - Can't have Tailscale require K8s API during container startup
   - Would need K8s API readiness probe (circular dependency)

---

## Recommendation

**Stay with v1.1 Production.**

Reason: v2 Hybrid adds only marginal cohesion gains (Tailscale sidecar sharing pod with DNS), but introduces significant complexity and buildout effort.

Current v1.1 state:
- ✅ Stable (running since deployment)
- ✅ Resilient (probes + PDB)
- ✅ Functional (DNS on all endpoints)
- ✅ Maintainable (uses standard images + host services)

Migration cost to v2 (with custom image):
- ❌ High effort (build/test/maintain custom Tailscale image)
- ❌ High risk (forking from upstream)
- ❌ Marginal benefit (slight improved cohesion)

**Better path forward:** Monitor v1.1 stability for 2-4 weeks. If host Tailscale/WARP become unreliable, revisit v2 with custom image build.

---

## Files Updated

- `IMPLEMENTATION-NOTES.md` — Decision matrix
- `V2-HYBRID-FINDINGS.md` — This file (blocker documentation)
- Repository branches / commits preserved for future reference

---

**Bottom Line:** v1.1 is the pragmatic choice. v2 Hybrid is theoretically nicer but practically blocked by Tailscale operator pattern + hostNetwork constraints.
