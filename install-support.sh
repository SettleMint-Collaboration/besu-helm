#!/usr/bin/env bash
set -euo pipefail

# Besu Stack Support Infrastructure Installer
# Installs Contour (ingress) and cert-manager (TLS) before deploying besu-stack

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="${SCRIPT_DIR}/besu-stack/examples"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Besu Stack Support Infrastructure Installer

Installs Contour (ingress controller) and optionally cert-manager (TLS certificates)
in your Kubernetes cluster before deploying besu-stack.

Usage: $0 [options]

Options:
  -c, --cloud <provider>   Cloud provider: aws, gke, azure (required)
  -t, --tls                Install cert-manager for TLS certificates
  -e, --email <email>      Email for Let's Encrypt (required with -t)
  -p, --prometheus         Install Prometheus stack for monitoring
  -d, --dry-run            Show what would be installed without installing
  -u, --upgrade            Upgrade existing installations
  -h, --help               Show this help message

Cloud Providers:
  aws     AWS EKS with internet-facing NLB
  gke     Google GKE with external LoadBalancer
  azure   Azure AKS with external LoadBalancer

Examples:
  $0 -c aws                           # Install Contour on AWS
  $0 -c aws -t -e admin@example.com   # Install Contour + cert-manager on AWS
  $0 -c gke -t -e admin@example.com   # Install Contour + cert-manager on GKE
  $0 -c azure -p                      # Install Contour + Prometheus on Azure
  $0 -c aws -u                        # Upgrade Contour on AWS

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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Default values
CLOUD_PROVIDER=""
INSTALL_TLS=false
INSTALL_PROMETHEUS=false
LETSENCRYPT_EMAIL=""
DRY_RUN=false
UPGRADE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cloud)
            CLOUD_PROVIDER="$2"
            if [[ ! "$CLOUD_PROVIDER" =~ ^(aws|gke|azure)$ ]]; then
                log_error "Invalid cloud provider: $CLOUD_PROVIDER (must be aws, gke, or azure)"
            fi
            shift 2
            ;;
        -t|--tls)
            INSTALL_TLS=true
            shift
            ;;
        -e|--email)
            LETSENCRYPT_EMAIL="$2"
            shift 2
            ;;
        -p|--prometheus)
            INSTALL_PROMETHEUS=true
            shift
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

# Validate arguments
if [[ -z "$CLOUD_PROVIDER" ]]; then
    log_error "Cloud provider is required. Use -c/--cloud <aws|gke|azure>"
fi

if [[ "$INSTALL_TLS" == true && -z "$LETSENCRYPT_EMAIL" ]]; then
    log_error "Email is required for TLS. Use -e/--email <your-email>"
fi

# Check for required tools
command -v helm >/dev/null 2>&1 || log_error "helm is required but not installed"
command -v kubectl >/dev/null 2>&1 || log_error "kubectl is required but not installed"

# Verify values files exist
CONTOUR_VALUES="${EXAMPLES_DIR}/support/contour-values.yaml"
if [[ ! -f "$CONTOUR_VALUES" ]]; then
    log_error "Contour values file not found: $CONTOUR_VALUES"
fi

echo ""
echo "=============================================="
echo "  Besu Stack Support Infrastructure Installer"
echo "=============================================="
echo ""
log_info "Cloud provider: $CLOUD_PROVIDER"
log_info "TLS (cert-manager): $INSTALL_TLS"
log_info "Prometheus monitoring: $INSTALL_PROMETHEUS"
if [[ "$INSTALL_TLS" == true ]]; then
    log_info "Let's Encrypt email: $LETSENCRYPT_EMAIL"
fi
log_info "Upgrade mode: $UPGRADE"
log_info "Dry run: $DRY_RUN"
echo ""

# ============================================
# Step 1: Install Contour
# ============================================
log_step "Installing Contour ingress controller..."

HELM_ACTION="install"
if [[ "$UPGRADE" == true ]]; then
    HELM_ACTION="upgrade"
fi

# Add Helm repo
if [[ "$DRY_RUN" == false ]]; then
    helm repo add contour https://projectcontour.github.io/helm-charts 2>/dev/null || true
    helm repo update contour
fi

CONTOUR_CMD=(
    "helm" "$HELM_ACTION" "contour" "contour/contour"
    "-n" "gateway" "--create-namespace"
    "-f" "$CONTOUR_VALUES"
)

if [[ "$DRY_RUN" == true ]]; then
    log_info "Would execute: ${CONTOUR_CMD[*]}"
else
    if [[ "$UPGRADE" == false ]] && helm status contour -n gateway &>/dev/null; then
        log_warn "Contour already installed. Use -u/--upgrade to upgrade."
    else
        log_info "Executing: ${CONTOUR_CMD[*]}"
        "${CONTOUR_CMD[@]}"
        log_info "Contour installed successfully"
    fi
fi

# ============================================
# Step 2: Install cert-manager (if requested)
# ============================================
if [[ "$INSTALL_TLS" == true ]]; then
    log_step "Installing cert-manager..."

    # Add Helm repo
    if [[ "$DRY_RUN" == false ]]; then
        helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
        helm repo update jetstack
    fi

    CERTMGR_CMD=(
        "helm" "$HELM_ACTION" "cert-manager" "jetstack/cert-manager"
        "-n" "cert-manager" "--create-namespace"
        "--set" "crds.enabled=true"
        "--set" "crds.keep=false"
        "--set" "extraArgs={--enable-gateway-api}"
    )

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would execute: ${CERTMGR_CMD[*]}"
    else
        if [[ "$UPGRADE" == false ]] && helm status cert-manager -n cert-manager &>/dev/null; then
            log_warn "cert-manager already installed. Use -u/--upgrade to upgrade."
        else
            log_info "Executing: ${CERTMGR_CMD[*]}"
            "${CERTMGR_CMD[@]}"
            log_info "cert-manager installed successfully"

            # Wait for cert-manager to be ready
            log_info "Waiting for cert-manager webhook to be ready..."
            kubectl wait --for=condition=available --timeout=120s \
                deployment/cert-manager-webhook -n cert-manager
        fi
    fi

    # ============================================
    # Step 3: Create ClusterIssuer
    # ============================================
    log_step "Creating Let's Encrypt ClusterIssuer..."

    CLUSTERISSUER_YAML=$(cat <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: contour
EOF
)

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would create ClusterIssuer with email: $LETSENCRYPT_EMAIL"
        echo "$CLUSTERISSUER_YAML"
    else
        echo "$CLUSTERISSUER_YAML" | kubectl apply -f -
        log_info "ClusterIssuer created successfully"
    fi
fi

# ============================================
# Step 4: Install Prometheus (if requested)
# ============================================
if [[ "$INSTALL_PROMETHEUS" == true ]]; then
    log_step "Installing Prometheus stack..."

    PROMETHEUS_VALUES="${EXAMPLES_DIR}/support/prometheus-values.yaml"
    if [[ ! -f "$PROMETHEUS_VALUES" ]]; then
        log_warn "Prometheus values file not found: $PROMETHEUS_VALUES"
        log_warn "Using default values"
        PROMETHEUS_VALUES=""
    fi

    # Add Helm repo
    if [[ "$DRY_RUN" == false ]]; then
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
        helm repo update prometheus-community
    fi

    PROM_CMD=(
        "helm" "$HELM_ACTION" "prometheus" "prometheus-community/kube-prometheus-stack"
        "-n" "monitoring" "--create-namespace"
    )

    if [[ -n "$PROMETHEUS_VALUES" ]]; then
        PROM_CMD+=("-f" "$PROMETHEUS_VALUES")
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Would execute: ${PROM_CMD[*]}"
    else
        if [[ "$UPGRADE" == false ]] && helm status prometheus -n monitoring &>/dev/null; then
            log_warn "Prometheus already installed. Use -u/--upgrade to upgrade."
        else
            log_info "Executing: ${PROM_CMD[*]}"
            "${PROM_CMD[@]}"
            log_info "Prometheus installed successfully"
        fi
    fi
fi

# ============================================
# Verification
# ============================================
if [[ "$DRY_RUN" == false ]]; then
    echo ""
    log_step "Verifying installation..."

    # Check Contour
    log_info "Checking Contour pods..."
    kubectl get pods -n gateway -l app.kubernetes.io/name=contour

    log_info "Checking Envoy service..."
    kubectl get svc -n gateway contour-envoy

    # Get LoadBalancer address
    echo ""
    log_info "LoadBalancer address (may take a few minutes to provision):"
    if [[ "$CLOUD_PROVIDER" == "aws" ]]; then
        kubectl get svc -n gateway contour-envoy \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "(pending)"
    else
        kubectl get svc -n gateway contour-envoy \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "(pending)"
    fi
    echo ""

    if [[ "$INSTALL_TLS" == true ]]; then
        log_info "Checking cert-manager pods..."
        kubectl get pods -n cert-manager

        log_info "Checking ClusterIssuer..."
        kubectl get clusterissuer letsencrypt-prod
    fi

    if [[ "$INSTALL_PROMETHEUS" == true ]]; then
        log_info "Checking Prometheus pods..."
        kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
    fi

    echo ""
    echo "=============================================="
    echo "  Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Wait for LoadBalancer to get an external address"
    echo "  2. Configure DNS to point to the LoadBalancer"
    echo "  3. Install besu-stack with:"
    echo ""
    if [[ "$INSTALL_TLS" == true ]]; then
        echo "     ./install.sh testnet -c $CLOUD_PROVIDER -i contour -t \\"
        echo "       -s httpProxy.host=besu.example.com"
    else
        echo "     ./install.sh testnet -c $CLOUD_PROVIDER -i contour \\"
        echo "       -s httpProxy.host=besu.example.com"
    fi
    echo ""
fi
