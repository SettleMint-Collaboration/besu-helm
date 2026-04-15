# Besu Stack

Production-ready Hyperledger Besu blockchain network for Kubernetes.

## Installation

```bash
helm install besu-stack ./besu-stack -n besu-stack --create-namespace \
  -f besu-stack/examples/values-devnet.yaml \
  -f my-genesis-values.yaml
```

## Configuration

See [values.yaml](values.yaml) for all available options.

### Required Configuration

#### Genesis

Generate with [Network Bootstrapper](https://github.com/settlemint/network-bootstrapper):

```yaml
genesis:
  raw: |
    { "config": { ... }, "alloc": { ... } }
```

#### Validator Keys

```yaml
validators:
  replicas: 4
  keys:
    inline:
      - privateKey: "0x..."
        publicKey: "0x..."
        nodeAddress: "0x..."
```

Or use pre-existing secret:

```yaml
validators:
  keys:
    existingSecret:
      name: my-validator-keys
```

Or fetch validator private keys from Conjur:

```yaml
global:
  conjur:
    enabled: true
    applianceUrl: "https://conjur.example.com/api"
    account: "myorg"
    authnUrl: "https://conjur.example.com/api/authn-k8s/cluster"
    authnLogin: "host/conjur/authn-k8s/cluster/apps/besu/*/*"

validators:
  image:
    repository: besu-conjur
  conjur:
    keyPath: "besu/validators/{{ordinal}}/private-key"
  keys:
    inline:
      - publicKey: "0x..."
        nodeAddress: "0x..."
```

### Validators

```yaml
validators:
  enabled: true
  replicas: 4
  image:
    repository: hyperledger/besu
    tag: "24.12.1"
  resources:
    requests:
      cpu: "1"
      memory: "4Gi"
    limits:
      cpu: "2"
      memory: "8Gi"
  persistence:
    size: 100Gi
    storageClass: ""
```

### RPC Nodes

```yaml
rpcNodes:
  enabled: true
  replicas: 2
  rpc:
    http:
      enabled: true
      port: 8545
      api: "ETH,NET,WEB3,TXPOOL"
    ws:
      enabled: true
      port: 8546
    graphql:
      enabled: false
  service:
    type: ClusterIP
```

### Ingress

Standard Kubernetes Ingress:

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: besu.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: besu-tls
      hosts:
        - besu.example.com
```

Contour HTTPProxy:

```yaml
httpProxy:
  enabled: true
  host: besu.example.com
  tls:
    enabled: true
    secretName: besu-tls
```

### Pod Disruption Budget

```yaml
podDisruptionBudget:
  validators:
    enabled: true
    minAvailable: 3
  rpcNodes:
    enabled: true
    minAvailable: 1
```

### Monitoring

```yaml
serviceMonitor:
  enabled: true
  interval: 30s
  labels:
    release: prometheus
```

### OpenShift

```yaml
openshift:
  enabled: true
```

## Examples

Example values files in `examples/`:

- `values-devnet.yaml` - Development
- `values-testnet.yaml` - Staging
- `values-production.yaml` - Production
- `values-cloud-aws.yaml` - AWS EKS
- `values-cloud-gke.yaml` - Google GKE
- `values-cloud-azure.yaml` - Azure AKS
- `values-openshift-devnet.yaml` - OpenShift dev
- `values-openshift-production.yaml` - OpenShift prod
- `values-ingress-contour.yaml` - Contour ingress
- `values-tls-certmanager.yaml` - TLS with cert-manager
- `values-external-secrets.yaml` - External Secrets Operator
- `values-conjur.yaml` - CyberArk Conjur integration with inline public metadata placeholders
- `values-conjur-perpod.yaml` - Conjur + per-pod LoadBalancer Services (cross-cluster peering with vault-backed keys)
- `values-nodeport-perpod.yaml` - Per-pod NodePort Services with an any-node VIP (cross-cluster peering without a LoadBalancer provider)
- `values-hostnetwork.yaml` - hostNetwork mode (pod binds to node IP directly; no LoadBalancer, no NodePort, no VIP needed)
- `values-main.yaml` - Hot-warm DR: Main cluster overlay (active 4 validators + 2 RPC)
- `values-dr.yaml` - Hot-warm DR: DR cluster overlay (warm 0 validators + 2 RPC, same keys)

## Disaster Recovery

For deploying `besu-stack` across two clusters (hot-warm topology, failover
runbook, cross-cluster network configuration, verification), see the
dedicated guide: [**DR.md**](DR.md).

The rest of this README describes the general-purpose networking features
that make cross-cluster peering possible — use them for DR or any other
multi-cluster / external-peer scenario.

## External p2p addressing

By default, each validator / RPC pod advertises its **pod IP** in the enode
URL it gives to peers. Pod IPs are cluster-internal and churn on restart —
fine for in-cluster peering, not fine for peers in another cluster.

The chart ships three mutually-exclusive modes for making a pod
externally-addressable, all off by default:

| Mode | Best for | Pod spec impact |
|---|---|---|
| `perPodService` with `type: LoadBalancer` | Cloud or MetalLB available | One extra Service per pod |
| `perPodService` with `type: NodePort` | No LB provider, VIP available | One extra Service per pod, same NodePort on every node |
| `hostNetwork` | No LB, no VIP, node IPs routable from peer | Pod shares node netns; no Service emitted |

All three are wired through the same wrapper: each pod looks up its
advertised host from `BESU_ADVERTISED_HOSTS[ordinal]` at startup, exports
`BESU_P2P_HOST`, and then execs Besu. Validation is shared (length match,
NodePort range/uniqueness, mutual exclusivity).

### Per-pod p2p Services (LoadBalancer / NodePort)

For cross-cluster peering you need each Besu pod reachable on a *stable,
externally-routable* address — one address per pod, because every node
advertises a unique enode (pubkey + host:port) and the consensus protocol
validates the source IP. The headless Service the chart ships by default
gives only a single VIP and only resolves inside the cluster, so it is not
sufficient on its own.

The `perPodService` feature emits one extra `Service` per StatefulSet
ordinal (in addition to the headless one) so each pod gets its own external
address from MetalLB / a cloud LB / a NodePort. **Default is OFF — existing
deployments are not affected.**

```yaml
validators:
  p2p:
    perPodService:
      enabled: true
      type: LoadBalancer                 # or NodePort
      externalTrafficPolicy: Cluster
      commonAnnotations:                 # applied to every per-pod Service
        metallb.universe.tf/address-pool: besu-p2p
      perPodAnnotations:                 # length must equal validators.replicas
        - metallb.universe.tf/loadBalancerIPs: "10.1.25.1"
        - metallb.universe.tf/loadBalancerIPs: "10.1.25.2"
        - metallb.universe.tf/loadBalancerIPs: "10.1.25.3"
        - metallb.universe.tf/loadBalancerIPs: "10.1.25.4"
      advertisedHosts:                   # length must equal validators.replicas
        - "10.1.25.1"                    # what each pod puts in its enode
        - "10.1.25.2"
        - "10.1.25.3"
        - "10.1.25.4"

rpcNodes:
  p2p:
    perPodService:
      enabled: true
      perPodAnnotations:
        - metallb.universe.tf/loadBalancerIPs: "10.1.25.10"
        - metallb.universe.tf/loadBalancerIPs: "10.1.25.11"
      advertisedHosts: ["10.1.25.10", "10.1.25.11"]
```

What this generates per cluster (4 validators + 2 RPC):

- Existing headless Services (`besu-validators`, `besu-rpc-headless`) — unchanged.
- 4 new `besu-validators-{0..3}-p2p` LoadBalancer Services, each selecting
  exactly one pod via `statefulset.kubernetes.io/pod-name`.
- 2 new `besu-rpc-{0..1}-p2p` LoadBalancer Services, same pattern.
- Besu CLI flips from `--p2p-host=0.0.0.0` to `--p2p-interface=0.0.0.0`
  (still binds to all interfaces) and the wrapper script sets
  `BESU_P2P_HOST=<advertisedHosts[ordinal]>` per pod so each enode
  advertises the right external address.

Notes:

- `advertisedHosts[i]` must equal what peers can actually reach. Usually that
  is the LoadBalancer IP — pin it via `perPodAnnotations` so a Service
  recreation does not change the address.
- For NodePort mode, set `type: NodePort` and provide a `nodePorts: []` list
  (length must equal replicas). See the "NodePort patterns" subsection
  below for how to set `advertisedHosts` and `externalTrafficPolicy`.

#### NodePort patterns

NodePort works but has three constraints LoadBalancer does not:

1. **Ports must be unique across the release.** Each Service takes one
   `nodePort` on every node. Example for 4 validators + 2 RPC:
   `validators.nodePorts: [30303, 30304, 30305, 30306]`,
   `rpcNodes.nodePorts: [30310, 30311]`. The chart fails `helm template`
   loudly on duplicates or out-of-range values.
2. **`advertisedHosts` must be reachable from the other cluster.** A
   NodePort opens on *every* node's IP, so what you advertise is your
   choice among three patterns.
3. **Firewall.** Open TCP+UDP on the chosen NodePort range from the peer
   cluster's egress IPs to every node IP on your side.

Pick one of these three patterns:

**A. Any-node VIP (recommended, simplest).** A static VIP in front of the
node pool (F5, haproxy, keepalived) forwards the chosen NodePort range to
all nodes. Every pod advertises the same VIP; kube-proxy routes traffic
from VIP:nodePort to the right pod regardless of which node hosts it.

```yaml
validators:
  p2p:
    perPodService:
      enabled: true
      type: NodePort
      externalTrafficPolicy: Cluster
      nodePorts: [30303, 30304, 30305, 30306]
      advertisedHosts:
        - "10.1.24.100"       # same VIP for every pod
        - "10.1.24.100"
        - "10.1.24.100"
        - "10.1.24.100"
```

Pros: pods can move freely, single IP to firewall from the peer side.
Cons: VIP is a dependency you must provision outside the chart.

**B. Per-node IP with pod-to-node pinning.** Advertise a specific node IP
for each pod, use `externalTrafficPolicy: Local` so kube-proxy only accepts
traffic on the node that actually hosts the pod, and pin each pod to its
node. Pinning is usually done via a local-PV storage class with
`volumeBindingMode: WaitForFirstConsumer` — the PV is created on a specific
node and the pod follows.

```yaml
validators:
  persistence:
    storageClass: "local-vol-rer"  # binds PV to a specific node
  p2p:
    perPodService:
      enabled: true
      type: NodePort
      externalTrafficPolicy: Local
      nodePorts: [30303, 30304, 30305, 30306]
      advertisedHosts:
        - "10.1.24.7"    # node hosting validator-0
        - "10.1.24.8"    # node hosting validator-1
        - "10.1.24.9"    # node hosting validator-2
        - "10.1.24.10"   # node hosting validator-3
```

Pros: fewer external dependencies than A. Cons: if a node dies, the pinned
pod can't reschedule until the node (or its PV) returns; the advertised
host becomes unreachable until then.

**C. Any-node-IP round-robin.** Advertise any reachable node IP for each
pod, accepting that peering may occasionally hit a dead path. Peer
discovery retries, so with `externalTrafficPolicy: Cluster` the traffic
reaches the right pod via kube-proxy. This is the least-work pattern but
has the worst failure behavior — avoid unless the peer cluster is tolerant
of flaky first connections.

A runnable NodePort example is at
[`examples/values-nodeport-perpod.yaml`](examples/values-nodeport-perpod.yaml).
- `perPodService` composes with `global.conjur.enabled` — see the next
  section.

#### Combining perPodService with Conjur

When you need both cross-cluster peering *and* Conjur-backed validator keys
(common in regulated environments where keys must come from a hardware vault),
enable both features. The chart emits a single combined entrypoint wrapper
that handles them in this order at pod startup:

```
1. Extract pod ordinal from $HOSTNAME (e.g. besu-validators-2 → 2)
2. perPod block (if enabled):
     - Look up advertised host from BESU_ADVERTISED_HOSTS[ordinal]
     - export BESU_P2P_HOST=<that host>           ← drives the enode address
3. Conjur block (if enabled):
     - Render summon secrets.yml with the ordinal-specific key path
     - summon → fetch private key → write /secrets/nodekey
4. exec besu "$@"                                  ← original args from values
```

Both blocks share the same `ORDINAL` (each cluster's `besu-validators-2` pod
gets the same Conjur key path *and* the per-ordinal external host that
peers should reach it on). Either block is omitted if its feature is off; if
both are off, no wrapper is emitted and Besu's default entrypoint runs.

Minimal combined configuration:

```yaml
global:
  conjur:
    enabled: true
    applianceUrl: "https://follower.dapvault.svc.cluster.local/api"
    account: "myorg"
    authnUrl:   "https://follower.dapvault.svc.cluster.local/api/authn-k8s/main-cluster"
    authnLogin: "host/conjur/authn-k8s/main-cluster/apps/<ns>/*/*"

validators:
  replicas: 4
  image:
    # MUST contain summon + summon-conjur (upstream hyperledger/besu does not).
    repository: "registry.example.com/besu-conjur"
    tag: "26.4.0"
  conjur:
    keyPath: "besu/validators/{{ordinal}}/private-key"
  keys:
    inline:                                # public material only — privkeys come from Conjur
      - {nodeAddress: "0x...", publicKey: "0x..."}
      - {nodeAddress: "0x...", publicKey: "0x..."}
      - {nodeAddress: "0x...", publicKey: "0x..."}
      - {nodeAddress: "0x...", publicKey: "0x..."}
  p2p:
    perPodService:
      enabled: true
      type: LoadBalancer
      perPodAnnotations:
        - {metallb.universe.tf/loadBalancerIPs: "10.1.25.1"}
        - {metallb.universe.tf/loadBalancerIPs: "10.1.25.2"}
        - {metallb.universe.tf/loadBalancerIPs: "10.1.25.3"}
        - {metallb.universe.tf/loadBalancerIPs: "10.1.25.4"}
      advertisedHosts:                     # what each pod puts in its enode
        - "10.1.25.1"
        - "10.1.25.2"
        - "10.1.25.3"
        - "10.1.25.4"
```

A complete runnable example is at
[`examples/values-conjur-perpod.yaml`](examples/values-conjur-perpod.yaml).

Notes:

- RPC pods do not currently have a Conjur path in this chart — only
  validators do. The combined wrapper therefore only matters on the
  validator side. Enabling `rpcNodes.p2p.perPodService.enabled` works
  independently regardless of `global.conjur.enabled`.
- The Conjur image / safe / authn policy must already be in place before
  install — the chart does not create them. See the standalone Conjur
  example at [`examples/values-conjur.yaml`](examples/values-conjur.yaml)
  for the full Conjur-only setup and prerequisites.
- For DR: in both clusters, `validators.conjur.keyPath` and
  `validators.p2p.perPodService.advertisedHosts` should point at the *same*
  4 Conjur paths (so warm DR validators come up with identical keys) but at
  *different* per-cluster LoadBalancer IPs in `advertisedHosts`. Both
  clusters' `staticNodes.raw` must list all 8 enodes (4 Main + 4 DR shared
  pubkeys, plus the 2 RPC enodes per cluster).

### hostNetwork mode

When there is no LoadBalancer provider (no MetalLB, no cloud LB) and no VIP
for the NodePort pattern, the simplest path is to bind Besu directly to the
node's network interface. The pod spec gets `hostNetwork: true` + the
required `dnsPolicy: ClusterFirstWithHostNet`, and no extra Service is
emitted — each pod is reachable at `<nodeIP>:<p2p.port>` directly.

```yaml
validators:
  replicas: 4
  persistence:
    storageClass: "local-vol-rer"       # local PV pins pods to specific nodes
  p2p:
    hostNetwork:
      enabled: true
      advertisedHosts:                  # one per replica; hosting node's IP
        - "10.1.24.7"                   # -> validator-0
        - "10.1.24.8"                   # -> validator-1
        - "10.1.24.9"                   # -> validator-2
        - "10.1.24.10"                  # -> validator-3
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: besu-stack
              app.kubernetes.io/component: validator
          topologyKey: kubernetes.io/hostname
```

Constraints:

- **One validator per node** — port 30303 is a node-wide port, two pods
  can't share it. Use `requiredDuringSchedulingIgnoredDuringExecution` pod
  anti-affinity as above.
- **Ordinal ↔ node pinning** — `advertisedHosts[i]` is fixed at install
  time, so the pod that owns ordinal `i` must always land on the same
  node. The standard pattern is a local-PV `StorageClass` with
  `volumeBindingMode: WaitForFirstConsumer` — the PV is created on the
  first-scheduling node and the pod follows forever.
- **OpenShift SCC** — grant the release's ServiceAccount the
  `hostnetwork-v2` SCC:
  `oc adm policy add-scc-to-user hostnetwork-v2 -z <sa> -n <ns>`.
- **Failure mode** — if a node dies, its pinned validator cannot
  reschedule until the node (or the local PV) returns.
- **Security teams** — Bitdefender / Falco / similar node-level endpoint
  security will see Besu traffic on the node network namespace.
  Coordinate before enabling.

A runnable example is at
[`examples/values-hostnetwork.yaml`](examples/values-hostnetwork.yaml).

## Upgrade

```bash
helm upgrade besu-stack ./besu-stack -n besu-stack -f my-values.yaml
```

## Uninstall

```bash
helm uninstall besu-stack -n besu-stack
kubectl delete namespace besu-stack
```
