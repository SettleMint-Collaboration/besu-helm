# Disaster Recovery (hot-warm, two clusters)

This document covers deploying `besu-stack` across two Kubernetes clusters
for geographic redundancy. For the underlying chart features that make it
possible (per-pod Services, hostNetwork, Conjur integration, NodePort
patterns) see [`README.md`](README.md).

## Topology

| | Main | DR |
|---|---|---|
| Validators | 4, active | 4, `replicas=0` (warm, same keys as Main) |
| RPC nodes | 2, active | 2, active (continuously syncing) |
| RPC ingress | enabled | disabled until failover |

The DR cluster keeps validator pods scaled to zero and brings them online
manually only after Main is confirmed dead. This is **mandatory**: both
validator sets share the same private keys (that is what makes them the
same validator identity for QBFT), and running them simultaneously would
double-sign blocks and corrupt the chain.

## Pre-requisites (both clusters)

1. **`besu-validator-keys` Secret** with keys `validator-0..3` —
   **identical content** in Main and DR. This is what makes them the same
   validator identity.
2. **`besu-rpc-keys` Secret** with keys `rpc-0`, `rpc-1` — **distinct
   content** per cluster (Main and DR RPC nodes are different physical
   peers and must not share enodes).
3. **Routable cross-cluster networking** on TCP+UDP `30303` (VPN / VPC
   peering; no NAT — enode IPs must match).
4. **External addressing per pod** — each validator and RPC must be
   reachable from the peer cluster on a stable `host:port`. Pick the mode
   in [`README.md`](README.md) that fits your environment:
   - `validators.p2p.perPodService` with MetalLB / cloud LB (simplest when
     available)
   - `validators.p2p.perPodService` with NodePort + VIP (on-prem, no LB)
   - `validators.p2p.hostNetwork` (on-prem, no LB, no VIP; node IPs
     routable from peer)
   - VPN-routed pod CIDRs + `external-dns` or CNI-pinned pod IPs
     (see "Cross-cluster network configuration" below)
5. **Identical `genesis.raw`** in both values files.

## Cross-cluster network configuration

Three layers have to be right for validators and RPC nodes to peer across
clusters.

**1. Cloud / network fabric (pod-to-pod routability).** Same cloud: use
VPC peering for single-region, cross-region peering or Transit Gateway /
Cloud Router for multi-region. Cross-cloud or on-prem ↔ cloud:
site-to-site IPsec VPN or a Direct Connect / ExpressRoute link. VPN
tunnels drop MTU to ~1400 — Besu p2p handles this fine, but note it if
you also run big RPC responses over the same path.

**2. Kubernetes-side pre-requisites.**

- **Non-overlapping pod CIDRs.** Main's pod CIDR (e.g. `10.10.0.0/16`)
  must not overlap DR's (e.g. `10.20.0.0/16`). If they do, you cannot
  route between them without NAT, and NAT breaks Besu p2p — discovery
  validates the source IP against the enode, so rewritten IPs are
  rejected.
- **No NAT in the path.** Confirm with `kubectl exec` + `tcpdump` that
  packets arrive with the original pod IP, not a gateway IP.
- **Firewall / security groups.** Allow TCP+UDP `30303` (or your chosen
  port/range) from the peer cluster's egress on the node security group
  (not just the VPC ACL). Cloud-managed Kubernetes often blocks
  pod-to-pod inbound from outside the VPC by default.
- **NetworkPolicy.** When `networkPolicy.enabled: true`, add an ingress
  rule allowing the peer cluster's pod CIDR / LB IPs on the p2p port.

**3. DNS / addressability per pod.** StatefulSet pods have stable *names*
but pod **IPs change on restart**, and their headless-service DNS does
not resolve outside the cluster. If you rely on VPN-routed pod CIDRs
(rather than the chart's `perPodService` / `hostNetwork` modes), use one
of:

- **`external-dns` per cluster** watching pods and publishing
  `<pod>.besu.internal` → current pod IP into a shared private zone
  (Route 53 private, Cloud DNS private, or self-hosted).
- **Stable pod IPs via CNI**: Calico IP reservations or Cilium with
  fixed IP pools, then hard-code those IPs in `staticNodes.raw`.
  Operationally brittle — pods must never migrate.

## Install

```bash
# Main cluster
helm install besu ./besu-stack -n besu -f examples/values-main.yaml

# DR cluster (separate kubectl context)
helm install besu ./besu-stack -n besu -f examples/values-dr.yaml
```

Verify peering from a DR RPC node — `admin_peers` should list Main's
enodes and `net_peerCount` should be ≥ 6 (4 Main validators + 2 Main
RPC).

## Verification sequence

```bash
# 1. Raw TCP reachability from DR to Main
kubectl --context dr exec besu-rpc-0 -- nc -zv <main-validator-0-ip> 30303

# 2. Peer discovery working (run from a DR RPC pod)
kubectl --context dr exec besu-rpc-0 -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"admin_peers","id":1}' \
  http://localhost:8545 | jq '.result | length'
# Expect >= 6 after a minute (4 Main validators + 2 Main RPC)

# 3. Pod flap test — restart a validator and watch DR reconnect
kubectl --context main delete pod besu-validators-0
# The advertised host stays the same (perPodService LB IP / hostNetwork
# node IP), so peering recovers as soon as the new pod is Ready.
```

## Failover (manual runbook)

When Main is confirmed dead (not just degraded — **explicit human gate**):

1. **Verify Main is fully down.** Block height flat for >N seconds
   (`besu_blockchain_height` Prometheus metric), API unreachable,
   `kubectl get` from Main returns connection error. A false positive
   here causes double-signing and chain corruption.
2. **Cut RPC traffic to Main** at the ingress / DNS layer.
3. **On the DR cluster**:
   ```bash
   helm upgrade besu ./besu-stack -f examples/values-dr.yaml \
     --set validators.replicas=4
   ```
4. **Watch DR validator logs** as they mount the pre-seeded
   `besu-validator-keys` Secret, peer with DR RPC nodes (already in
   sync), catch up, and resume block production. With 4/4 validators
   online, the 66% QBFT threshold is met.
5. **Repoint RPC traffic** to DR's ingress.
6. **Before bringing Main back later**: scale DR validators to `0` first
   and confirm they have stopped — same anti-double-signing rule.

## DR-specific example overlays

- [`examples/values-main.yaml`](examples/values-main.yaml) — Main cluster
  (active 4 validators + 2 RPC, same `besu-validator-keys` Secret as DR).
- [`examples/values-dr.yaml`](examples/values-dr.yaml) — DR cluster
  (`validators.replicas=0`, same validator keys, distinct RPC keys,
  identical `staticNodes.raw` listing all 8 enodes).
- [`examples/values-conjur-perpod.yaml`](examples/values-conjur-perpod.yaml) —
  regulated-environment variant: validator keys from Conjur, cross-cluster
  p2p via per-pod LoadBalancer Services.
