<p align="center">
  <img src="besu.png" width="120px" align="center" alt="Hyperledger Besu logo" />
  <h1 align="center">Besu Stack Helm Chart</h1>
  <p align="center">
    Production-ready Hyperledger Besu blockchain network deployment for Kubernetes.
    <br/>
    Maintained by <a href="https://settlemint.com">SettleMint</a>
  </p>
</p>
<br/>
<p align="center">
<a href="https://github.com/settlemint/besu-helm/actions?query=branch%3Amain"><img src="https://github.com/settlemint/besu-helm/actions/workflows/release.yml/badge.svg?event=push&branch=main" alt="CI status" /></a>
<a href="https://github.com/settlemint/besu-helm" rel="nofollow"><img src="https://img.shields.io/badge/helm-v3%20%7C%20v4-blue" alt="Helm v3 | v4"></a>
<a href="https://github.com/settlemint/besu-helm" rel="nofollow"><img src="https://img.shields.io/badge/kubernetes-1.24%2B-blue" alt="Kubernetes 1.24+"></a>
<a href="https://github.com/settlemint/besu-helm" rel="nofollow"><img src="https://img.shields.io/github/license/settlemint/besu-helm" alt="License"></a>
<a href="https://github.com/settlemint/besu-helm" rel="nofollow"><img src="https://img.shields.io/github/stars/settlemint/besu-helm" alt="stars"></a>
</p>

<div align="center">
  <a href="https://besu.hyperledger.org/">Documentation</a>
  <span>&nbsp;&nbsp;•&nbsp;&nbsp;</span>
  <a href="https://github.com/settlemint/besu-helm/issues">Issues</a>
  <span>&nbsp;&nbsp;•&nbsp;&nbsp;</span>
  <a href="https://hyperledger.org/projects/besu">Hyperledger Besu</a>
  <span>&nbsp;&nbsp;•&nbsp;&nbsp;</span>
  <a href="https://settlemint.com">SettleMint</a>
  <br />
</div>

## Introduction

The Besu Stack Helm Chart provides a production-ready deployment solution for running Hyperledger Besu blockchain networks on Kubernetes and OpenShift clusters. This chart is developed and maintained by [SettleMint](https://settlemint.com), leveraging enterprise deployment experience to simplify Besu network operations.

## Features

- **Two StatefulSets**: Separate validators (consensus) and RPC nodes (API access)
- **DNS-based discovery**: Automatic node discovery using Kubernetes DNS
- **Flexible secret management**: Inline keys, pre-existing secrets, or external secret operators
- **OpenShift compatible**: Full support for OpenShift security contexts
- **Cloud-optimized**: Pre-configured values for AWS, GKE, and Azure
- **High availability**: Pod disruption budgets, anti-affinity rules
- **Monitoring**: Prometheus ServiceMonitor integration
- **Ingress options**: Contour HTTPProxy, NGINX, or LoadBalancer

## Prerequisites

- Kubernetes 1.24+
- Helm 3.0+
- Genesis file generated with [Network Bootstrapper](https://github.com/settlemint/network-bootstrapper)

## Quick Start

### 1. Generate Genesis Configuration

Use the [Network Bootstrapper](https://github.com/settlemint/network-bootstrapper) CLI to generate your genesis file and validator keys for a 4-validator network:

```bash
docker run --rm ghcr.io/settlemint/network-bootstrapper generate \
  --validators 4 \
  --outputType screen \
  --accept-defaults
```

This outputs:

- **genesis.json** - The genesis block configuration with validator addresses in extraData
- **Validator keys** - Private keys for each validator node
- **Static nodes** - Enode URLs for peer discovery

For Kubernetes deployments, use `--outputType kubernetes` to generate ConfigMaps and Secrets directly.

### 2. Create Values File

Create a values file with the generated genesis and validator keys:

```yaml
# my-network-values.yaml
genesis:
  raw: |
    {
      "config": {
        "chainId": 1337,
        "berlinBlock": 0,
        "qbft": {
          "blockperiodseconds": 2,
          "epochlength": 30000,
          "requesttimeoutseconds": 4
        }
      },
      "nonce": "0x0",
      "timestamp": "0x0",
      "gasLimit": "0x1fffffffffffff",
      "difficulty": "0x1",
      "mixHash": "0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365",
      "coinbase": "0x0000000000000000000000000000000000000000",
      "alloc": {
        "0xYourFaucetAddress": {
          "balance": "0x446c3b15f9926687d2c40534fdb564000000000000"
        }
      },
      "extraData": "0x..." # Generated extraData with validator addresses
    }

validators:
  replicas: 4
  keys:
    inline:
      - "0x..." # validator-0 private key (from generate output)
      - "0x..." # validator-1 private key
      - "0x..." # validator-2 private key
      - "0x..." # validator-3 private key

rpcNodes:
  replicas: 2
```

### 3. Install

```bash
# Development network
./install.sh devnet -f my-values.yaml

# Production with HA
./install.sh production -c aws -f my-values.yaml
```

## Installation

### Basic Installation

```bash
# Install devnet (minimal resources)
./install.sh devnet

# Install testnet
./install.sh testnet -n besu-testnet

# Install production (HA configuration)
./install.sh production -n besu-prod
```

### Cloud Providers

```bash
# AWS EKS with gp3 storage
./install.sh production -c aws

# Google GKE with premium storage
./install.sh production -c gke

# Azure AKS with managed-premium storage
./install.sh production -c azure
```

### OpenShift

```bash
# OpenShift devnet
./install.sh devnet -o

# OpenShift production
./install.sh production -o
```

### With Ingress

```bash
# Install support infrastructure first
./install-support.sh -c aws -t -e admin@example.com

# Then install with Contour ingress
./install.sh testnet -c aws -i contour \
  -s httpProxy.host=besu.example.com
```

## Secret Management

### Option 1: Inline Keys (Development)

```yaml
validators:
  keys:
    inline:
      - "0xprivatekey1..."
      - "0xprivatekey2..."
```

### Option 2: Pre-existing Secret (Production)

Create a secret with your validator keys:

```bash
kubectl create secret generic besu-validator-keys \
  --from-literal=key-0=0x... \
  --from-literal=key-1=0x... \
  --from-literal=key-2=0x... \
  --from-literal=key-3=0x...
```

Reference in values:

```yaml
validators:
  keys:
    existingSecret: besu-validator-keys
```

### Option 3: External Secrets Operator

```yaml
validators:
  keys:
    existingSecrets:
      - name: vault-validator-0-key
        key: private-key
      - name: vault-validator-1-key
        key: private-key
```

See `besu-stack/examples/values-external-secrets.yaml` for full example.

## Configuration

### Environment Values Files

| File                     | Description                                        |
| ------------------------ | -------------------------------------------------- |
| `values-devnet.yaml`     | Development (4 validators, minimal resources)      |
| `values-testnet.yaml`    | Staging/testnet (4 validators, moderate resources) |
| `values-production.yaml` | Production (7 validators, HA, high resources)      |

### Cloud Values Files

| File                      | Description              |
| ------------------------- | ------------------------ |
| `values-cloud-aws.yaml`   | AWS EKS optimizations    |
| `values-cloud-gke.yaml`   | Google GKE optimizations |
| `values-cloud-azure.yaml` | Azure AKS optimizations  |

### OpenShift Values Files

| File                               | Description           |
| ---------------------------------- | --------------------- |
| `values-openshift-devnet.yaml`     | OpenShift development |
| `values-openshift-production.yaml` | OpenShift production  |

### Feature Values Files

| File                           | Description                     |
| ------------------------------ | ------------------------------- |
| `values-ingress-contour.yaml`  | Contour HTTPProxy configuration |
| `values-tls-certmanager.yaml`  | cert-manager TLS configuration  |
| `values-external-secrets.yaml` | External secrets example        |

## Scripts

| Script                 | Description                               |
| ---------------------- | ----------------------------------------- |
| `install.sh`           | Install besu-stack                        |
| `install-support.sh`   | Install Contour, cert-manager, Prometheus |
| `uninstall.sh`         | Uninstall besu-stack                      |
| `uninstall-support.sh` | Uninstall support infrastructure          |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Validators StatefulSet                  │   │
│  │  ┌───────────┐ ┌───────────┐ ┌───────────┐         │   │
│  │  │validator-0│ │validator-1│ │validator-2│ ...     │   │
│  │  └───────────┘ └───────────┘ └───────────┘         │   │
│  │           ▲           ▲           ▲                 │   │
│  │           └───────────┼───────────┘                 │   │
│  │                       │                             │   │
│  │              Headless Service                       │   │
│  │         (DNS-based peer discovery)                  │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼ (bootnode connection)            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │               RPC Nodes StatefulSet                  │   │
│  │  ┌───────────┐ ┌───────────┐                        │   │
│  │  │  rpc-0    │ │  rpc-1    │ ...                    │   │
│  │  └───────────┘ └───────────┘                        │   │
│  │           ▲           ▲                             │   │
│  │           └───────────┘                             │   │
│  │                  │                                  │   │
│  │           ClusterIP Service                         │   │
│  │         (HTTP RPC, WebSocket)                       │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Ingress / HTTPProxy                       │   │
│  │                    │                                │   │
│  │                    ▼                                │   │
│  │             External Access                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Monitoring

Enable Prometheus ServiceMonitor:

```yaml
serviceMonitor:
  enabled: true
  interval: 30s
  labels:
    release: prometheus
```

Access Besu metrics at `http://<pod-ip>:9545/metrics`.

## Upgrading

```bash
# Upgrade existing release
./install.sh production -u -f my-values.yaml

# Or with helm directly
helm upgrade besu-stack ./besu-stack -n besu-stack -f my-values.yaml
```

## Uninstalling

```bash
# Uninstall besu-stack
./uninstall.sh -n besu-stack

# Force uninstall (handles stuck resources)
./uninstall.sh -n besu-stack -f

# Keep PVCs (preserve blockchain data)
./uninstall.sh -n besu-stack -k
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n besu-stack
kubectl describe pod <pod-name> -n besu-stack
```

### View Logs

```bash
# Validator logs
kubectl logs -n besu-stack -l app.kubernetes.io/component=validator -f

# RPC node logs
kubectl logs -n besu-stack -l app.kubernetes.io/component=rpc -f
```

### Test RPC Connection

```bash
# Port forward
kubectl port-forward -n besu-stack svc/besu-stack-rpc 8545:8545

# Test
curl -X POST http://localhost:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Run Helm Tests

```bash
helm test besu-stack -n besu-stack
```

## Contributing

Contributions are welcome! Please submit pull requests to the [GitHub repository](https://github.com/settlemint/besu-helm).

## About

### Hyperledger Besu

[Hyperledger Besu](https://besu.hyperledger.org/) is an open-source Ethereum client designed for enterprise use cases. It supports both public and private permissioned network configurations, and includes consensus algorithms like QBFT and IBFT 2.0.

### SettleMint

[SettleMint](https://settlemint.com) is the leading enterprise blockchain platform, providing tools and infrastructure for building, deploying, and managing blockchain applications at scale.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
