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
      - "0x..."
      - "0x..."
      - "0x..."
      - "0x..."
```

Or use pre-existing secret:

```yaml
validators:
  keys:
    existingSecret: my-validator-keys
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

## Upgrade

```bash
helm upgrade besu-stack ./besu-stack -n besu-stack -f my-values.yaml
```

## Uninstall

```bash
helm uninstall besu-stack -n besu-stack
kubectl delete namespace besu-stack
```
