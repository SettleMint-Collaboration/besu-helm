#!/usr/bin/env bash
set -euo pipefail

# Besu Stack Helm Chart Installer
# Usage: ./install.sh [devnet|testnet|production] [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/besu-stack"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Besu Stack Helm Chart Installer

Usage: $0 <environment> [options]

Environments:
  devnet      Development network (minimal resources)
  testnet     Staging/testnet network
  production  Production deployment (high availability)

Options:
  -n, --namespace <ns>    Kubernetes namespace (default: besu-stack)
  -r, --release <name>    Helm release name (default: besu-stack)
  -o, --openshift         Use OpenShift-specific values
  -c, --cloud <provider>  Cloud provider: aws, gke, azure (optional)
  -p, --performance <tier> Performance tier: low, medium, high (default: low)
  -t, --cert-manager      Use cert-manager for TLS certificates
  -i, --ingress <type>    Ingress controller: auto, contour, nginx, none (default: auto)
  -f, --values <file>     Additional values file to merge
  -s, --set <key=value>   Set a Helm value (can be used multiple times)
  -d, --dry-run           Perform a dry run (template only)
  -u, --upgrade           Upgrade existing release instead of install
  -h, --help              Show this help message

Cloud Provider Settings (-c):
  aws     AWS EKS: Uses cluster default storage, NLB annotations
  gke     Google GKE: Uses cluster default storage, external LB
  azure   Azure AKS: Uses cluster default storage, external LB

Performance Tiers (-p):
  low     Development/Testing (minimal resources, 10Gi storage)
  medium  Testnet nodes (moderate resources, 100-200Gi storage)
  high    Production (high resources, 500Gi-1Ti storage)

Examples:
  $0 devnet -p low                    # Install devnet with minimal resources
  $0 testnet -n besu-testnet -p medium # Install testnet in custom namespace
  $0 production -o -p high            # Install production on OpenShift
  $0 testnet -o -n besu-test          # Install testnet on OpenShift
  $0 production -u                    # Upgrade existing production release
  $0 devnet -d                        # Dry run for devnet
  $0 production -c aws -p high        # AWS with high-performance settings
  $0 testnet -c gke -p medium -t      # GKE with cert-manager TLS
  $0 testnet -i contour               # Contour ingress with HTTPProxy
  $0 testnet -i none                  # Disable ingress (LoadBalancer only)

Genesis Configuration:
  The genesis.json must be generated beforehand using the Network Bootstrapper:
  docker run --rm ghcr.io/settlemint/network-bootstrapper generate --help

  Pass the genesis via values file:
    genesis:
      raw: |
        {
          "config": { ... },
          "alloc": { ... }
        }

EOF
    exit "${1:-0}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Default values
NAMESPACE="besu-stack"
RELEASE_NAME="besu-stack"
OPENSHIFT=false
CLOUD_PROVIDER=""
CERT_MANAGER=false
INGRESS_CONTROLLER="auto"
EXTRA_VALUES=""
HELM_SETS=()
DRY_RUN=false
UPGRADE=false
ENVIRONMENT=""
PERFORMANCE_TIER="low"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        devnet|testnet|production)
            ENVIRONMENT="$1"
            shift
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r|--release)
            RELEASE_NAME="$2"
            shift 2
            ;;
        -o|--openshift)
            OPENSHIFT=true
            shift
            ;;
        -c|--cloud)
            CLOUD_PROVIDER="$2"
            if [[ ! "$CLOUD_PROVIDER" =~ ^(aws|gke|azure)$ ]]; then
                log_error "Invalid cloud provider: $CLOUD_PROVIDER (must be aws, gke, or azure)"
            fi
            shift 2
            ;;
        -p|--performance)
            PERFORMANCE_TIER="$2"
            if [[ ! "$PERFORMANCE_TIER" =~ ^(low|medium|high)$ ]]; then
                log_error "Invalid performance tier: $PERFORMANCE_TIER (must be low, medium, or high)"
            fi
            shift 2
            ;;
        -t|--cert-manager)
            CERT_MANAGER=true
            shift
            ;;
        -i|--ingress)
            INGRESS_CONTROLLER="$2"
            if [[ ! "$INGRESS_CONTROLLER" =~ ^(auto|contour|nginx|none)$ ]]; then
                log_error "Invalid ingress controller: $INGRESS_CONTROLLER (must be auto, contour, nginx, or none)"
            fi
            shift 2
            ;;
        -f|--values)
            EXTRA_VALUES="$2"
            shift 2
            ;;
        -s|--set)
            HELM_SETS+=("$2")
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -u|--upgrade)
            UPGRADE=true
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            log_error "Unknown option: $1"
            ;;
    esac
done

# Validate environment selection
if [[ -z "$ENVIRONMENT" ]]; then
    log_error "Environment must be specified: devnet, testnet, or production"
fi

# Check for required tools
command -v helm >/dev/null 2>&1 || log_error "helm is required but not installed"
command -v kubectl >/dev/null 2>&1 || log_error "kubectl is required but not installed"

# Determine values file based on environment and platform
if [[ "$OPENSHIFT" == true ]]; then
    if [[ "$ENVIRONMENT" == "production" ]]; then
        VALUES_FILE="${CHART_DIR}/examples/values-openshift-production.yaml"
    else
        VALUES_FILE="${CHART_DIR}/examples/values-openshift-devnet.yaml"
    fi
    log_info "Using OpenShift configuration for ${ENVIRONMENT}"
else
    VALUES_FILE="${CHART_DIR}/examples/values-${ENVIRONMENT}.yaml"
    log_info "Using Kubernetes configuration for ${ENVIRONMENT}"
fi

# Verify values file exists
if [[ ! -f "$VALUES_FILE" ]]; then
    log_error "Values file not found: $VALUES_FILE"
fi

log_info "Values file: $VALUES_FILE"
log_info "Namespace: $NAMESPACE"
log_info "Release: $RELEASE_NAME"

# Build layered values files array
VALUES_FILES=()
VALUES_FILES+=("$VALUES_FILE")

# Add cloud provider values file if specified
if [[ -n "$CLOUD_PROVIDER" ]]; then
    CLOUD_VALUES="${CHART_DIR}/examples/values-cloud-${CLOUD_PROVIDER}.yaml"
    if [[ -f "$CLOUD_VALUES" ]]; then
        VALUES_FILES+=("$CLOUD_VALUES")
        log_info "Cloud provider: $CLOUD_PROVIDER (using $CLOUD_VALUES)"
    else
        log_error "Cloud values file not found: $CLOUD_VALUES"
    fi
fi

# Add performance tier values file
PERF_VALUES="${CHART_DIR}/examples/values-performance-${PERFORMANCE_TIER}.yaml"
if [[ -f "$PERF_VALUES" ]]; then
    VALUES_FILES+=("$PERF_VALUES")
    log_info "Performance tier: $PERFORMANCE_TIER (using $PERF_VALUES)"
else
    log_error "Performance values file not found: $PERF_VALUES"
fi

# Add cert-manager values file if requested
if [[ "$CERT_MANAGER" == true ]]; then
    CERTMGR_VALUES="${CHART_DIR}/examples/values-tls-certmanager.yaml"
    if [[ -f "$CERTMGR_VALUES" ]]; then
        VALUES_FILES+=("$CERTMGR_VALUES")
        log_info "TLS: Using cert-manager (letsencrypt-prod)"
    else
        log_error "cert-manager values file not found: $CERTMGR_VALUES"
    fi
fi

# Add ingress controller configuration
case "$INGRESS_CONTROLLER" in
    contour)
        # Check for Contour HTTPProxy CRD (installed with Contour Helm chart)
        if ! kubectl get crd httpproxies.projectcontour.io &>/dev/null; then
            log_warn "Contour HTTPProxy CRD not found. Install Contour first:"
            log_warn "  ./install-support.sh -c $CLOUD_PROVIDER"
            log_error "Contour is required for HTTPProxy ingress"
        fi
        # Add Contour ingress values file
        CONTOUR_VALUES="${CHART_DIR}/examples/values-ingress-contour.yaml"
        if [[ -f "$CONTOUR_VALUES" ]]; then
            VALUES_FILES+=("$CONTOUR_VALUES")
            log_info "Ingress: Contour with HTTPProxy (using $CONTOUR_VALUES)"
        else
            log_error "Contour values file not found: $CONTOUR_VALUES"
        fi
        ;;
    nginx)
        HELM_SETS+=("ingress.enabled=true")
        HELM_SETS+=("ingress.className=nginx")
        log_info "Ingress: NGINX"
        ;;
    none)
        HELM_SETS+=("ingress.enabled=false")
        HELM_SETS+=("httpProxy.enabled=false")
        log_info "Ingress: Disabled"
        ;;
    auto|"")
        log_info "Ingress: Auto-detection enabled"
        ;;
esac

# Build helm command using array (no eval for security)
HELM_CMD=("helm")

if [[ "$DRY_RUN" == true ]]; then
    HELM_CMD+=("template")
else
    if [[ "$UPGRADE" == true ]]; then
        HELM_CMD+=("upgrade")
    else
        HELM_CMD+=("install")
    fi
fi

HELM_CMD+=("$RELEASE_NAME" "$CHART_DIR")
HELM_CMD+=("-n" "$NAMESPACE")

# Add all layered values files
for vf in "${VALUES_FILES[@]}"; do
    HELM_CMD+=("-f" "$vf")
done

# Add extra values file if specified
if [[ -n "$EXTRA_VALUES" ]]; then
    if [[ ! -f "$EXTRA_VALUES" ]]; then
        log_error "Extra values file not found: $EXTRA_VALUES"
    fi
    HELM_CMD+=("-f" "$EXTRA_VALUES")
fi

# Add --set arguments
if [[ ${#HELM_SETS[@]} -gt 0 ]]; then
    for set_arg in "${HELM_SETS[@]}"; do
        HELM_CMD+=("--set" "$set_arg")
        log_info "Set: $set_arg"
    done
fi

if [[ "$DRY_RUN" == false ]]; then
    HELM_CMD+=("--create-namespace")
    if [[ "$UPGRADE" == false ]]; then
        # Check if release already exists
        if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
            log_warn "Release '$RELEASE_NAME' already exists in namespace '$NAMESPACE'"
            log_info "Use -u/--upgrade to upgrade the existing release"
            exit 1
        fi
    fi
fi

# Execute
log_info "Executing: ${HELM_CMD[*]}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    "${HELM_CMD[@]}"
else
    "${HELM_CMD[@]}"

    echo ""
    log_info "Installation complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Check pod status:"
    echo "     kubectl get pods -n $NAMESPACE"
    echo ""
    echo "  2. View validator logs:"
    echo "     kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=validator -f"
    echo ""
    echo "  3. View RPC node logs:"
    echo "     kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=rpc -f"
    echo ""
    echo "  4. Access RPC endpoint:"
    echo "     kubectl port-forward -n $NAMESPACE svc/${RELEASE_NAME}-rpc 8545:8545"
    echo ""
    echo "  5. Test RPC connection:"
    echo "     curl -X POST http://localhost:8545 \\"
    echo "       -H 'Content-Type: application/json' \\"
    echo "       -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}'"
    echo ""
fi
