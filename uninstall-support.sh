#!/usr/bin/env bash
set -euo pipefail

# Besu Stack Support Infrastructure Uninstaller
# Cleanly removes Contour and cert-manager with stuck resource handling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Besu Stack Support Infrastructure Uninstaller

Cleanly removes Contour (ingress), cert-manager (TLS), and Prometheus (monitoring)
from your cluster, including handling of stuck CRDs and resources with finalizers.

Usage: $0 [options]

Options:
  -f, --force             Force removal of stuck resources and CRDs
  -c, --contour-only      Only uninstall Contour (keep cert-manager, Prometheus)
  -m, --certmanager-only  Only uninstall cert-manager (keep Contour, Prometheus)
  -p, --prometheus-only   Only uninstall Prometheus (keep Contour, cert-manager)
  -d, --dry-run           Show what would be uninstalled without uninstalling
  -h, --help              Show this help message

Examples:
  $0                      # Uninstall Contour, cert-manager, and Prometheus
  $0 -f                   # Force uninstall with stuck resource cleanup
  $0 -c                   # Only uninstall Contour
  $0 -m -f                # Force uninstall only cert-manager
  $0 -p                   # Only uninstall Prometheus

Warning:
  This will remove ingress routing, TLS certificates, and monitoring.
  Make sure no besu-stack deployments are using these services before uninstalling.

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
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Remove finalizers from a CRD to allow deletion
force_delete_crd() {
    local crd=$1
    log_info "  Force deleting CRD: $crd"

    # First, delete all instances of this CRD across all namespaces
    local kind
    kind=$(echo "$crd" | cut -d. -f1)

    # Remove finalizers from all instances
    for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        for resource in $(kubectl get "$kind" -n "$ns" -o name 2>/dev/null || true); do
            kubectl patch "$resource" -n "$ns" \
                -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
    done

    # Also check cluster-scoped resources
    for resource in $(kubectl get "$kind" -o name 2>/dev/null || true); do
        kubectl patch "$resource" \
            -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done

    # Delete the CRD
    kubectl delete crd "$crd" --timeout=30s 2>/dev/null || {
        # If still stuck, patch the CRD finalizers
        kubectl patch crd "$crd" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete crd "$crd" --timeout=10s 2>/dev/null || true
    }
}

# Remove finalizers from namespace resources
remove_namespace_finalizers() {
    local namespace=$1
    log_info "Removing finalizers from resources in $namespace..."

    # Common resource types that can have finalizers
    local resource_types=("challenges" "orders" "certificates" "certificaterequests" "issuers" "httpproxies" "extensionservices")

    for rt in "${resource_types[@]}"; do
        for resource in $(kubectl get "$rt" -n "$namespace" -o name 2>/dev/null || true); do
            kubectl patch "$resource" -n "$namespace" \
                -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
    done
}

# Force delete a namespace
force_delete_namespace() {
    local namespace=$1

    if ! kubectl get namespace "$namespace" &>/dev/null; then
        return 0
    fi

    log_info "Force deleting namespace $namespace..."
    remove_namespace_finalizers "$namespace"

    kubectl delete namespace "$namespace" --wait=false 2>/dev/null || true

    # Check if stuck in Terminating
    local ns_status
    ns_status=$(kubectl get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "$ns_status" == "Terminating" ]]; then
        log_info "Removing namespace finalizers..."
        kubectl get namespace "$namespace" -o json | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f - 2>/dev/null || true
    fi

    # Wait for deletion
    local timeout=30
    local elapsed=0
    while kubectl get namespace "$namespace" &>/dev/null && [[ $elapsed -lt $timeout ]]; do
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

# Uninstall Contour
uninstall_contour() {
    local force=$1
    local dry_run=$2

    log_step "Uninstalling Contour..."

    if [[ "$dry_run" == true ]]; then
        log_info "Would uninstall Helm release: contour from gateway namespace"
        log_info "Would delete Contour CRDs"
        log_info "Would delete namespace: gateway"
        return 0
    fi

    # Check if Contour is installed
    if ! helm status contour -n gateway &>/dev/null; then
        log_warn "Contour release not found in gateway namespace"
    else
        log_info "Uninstalling Contour Helm release..."
        helm uninstall contour -n gateway --wait --timeout 2m || {
            log_warn "Helm uninstall timed out, continuing with cleanup..."
        }
    fi

    # Delete Contour CRDs
    log_info "Deleting Contour CRDs..."
    CONTOUR_CRDS=(
        "contourconfigurations.projectcontour.io"
        "contourdeployments.projectcontour.io"
        "extensionservices.projectcontour.io"
        "httpproxies.projectcontour.io"
        "tlscertificatedelegations.projectcontour.io"
    )

    for crd in "${CONTOUR_CRDS[@]}"; do
        if kubectl get crd "$crd" &>/dev/null; then
            if [[ "$force" == true ]]; then
                force_delete_crd "$crd"
            else
                kubectl delete crd "$crd" --timeout=30s 2>/dev/null || {
                    log_warn "CRD $crd is stuck. Run with -f/--force to force removal."
                }
            fi
        fi
    done

    # Delete namespace
    log_info "Deleting gateway namespace..."
    if [[ "$force" == true ]]; then
        force_delete_namespace "gateway"
    else
        kubectl delete namespace gateway --wait=false 2>/dev/null || true
    fi

    log_info "Contour uninstalled"
}

# Uninstall cert-manager
uninstall_certmanager() {
    local force=$1
    local dry_run=$2

    log_step "Uninstalling cert-manager..."

    if [[ "$dry_run" == true ]]; then
        log_info "Would delete ClusterIssuer: letsencrypt-prod"
        log_info "Would uninstall Helm release: cert-manager from cert-manager namespace"
        log_info "Would delete cert-manager CRDs"
        log_info "Would delete namespace: cert-manager"
        return 0
    fi

    # Delete ClusterIssuers first
    log_info "Deleting ClusterIssuers..."
    for issuer in $(kubectl get clusterissuers -o name 2>/dev/null || true); do
        if [[ "$force" == true ]]; then
            kubectl patch "$issuer" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        fi
        kubectl delete "$issuer" --timeout=30s 2>/dev/null || true
    done

    # Check if cert-manager is installed
    if ! helm status cert-manager -n cert-manager &>/dev/null; then
        log_warn "cert-manager release not found in cert-manager namespace"
    else
        log_info "Uninstalling cert-manager Helm release..."
        helm uninstall cert-manager -n cert-manager --wait --timeout 2m || {
            log_warn "Helm uninstall timed out, continuing with cleanup..."
        }
    fi

    # Delete cert-manager CRDs
    log_info "Deleting cert-manager CRDs..."
    CERTMGR_CRDS=(
        "certificaterequests.cert-manager.io"
        "certificates.cert-manager.io"
        "challenges.acme.cert-manager.io"
        "clusterissuers.cert-manager.io"
        "issuers.cert-manager.io"
        "orders.acme.cert-manager.io"
    )

    for crd in "${CERTMGR_CRDS[@]}"; do
        if kubectl get crd "$crd" &>/dev/null; then
            if [[ "$force" == true ]]; then
                force_delete_crd "$crd"
            else
                kubectl delete crd "$crd" --timeout=30s 2>/dev/null || {
                    log_warn "CRD $crd is stuck. Run with -f/--force to force removal."
                }
            fi
        fi
    done

    # Clean up cluster-scoped resources
    log_info "Cleaning up cluster resources..."
    kubectl delete clusterrole -l app.kubernetes.io/instance=cert-manager 2>/dev/null || true
    kubectl delete clusterrolebinding -l app.kubernetes.io/instance=cert-manager 2>/dev/null || true
    kubectl delete mutatingwebhookconfiguration cert-manager-webhook 2>/dev/null || true
    kubectl delete validatingwebhookconfiguration cert-manager-webhook 2>/dev/null || true

    # Delete namespace
    log_info "Deleting cert-manager namespace..."
    if [[ "$force" == true ]]; then
        force_delete_namespace "cert-manager"
    else
        kubectl delete namespace cert-manager --wait=false 2>/dev/null || true
    fi

    log_info "cert-manager uninstalled"
}

# Uninstall Prometheus
uninstall_prometheus() {
    local force=$1
    local dry_run=$2

    log_step "Uninstalling Prometheus..."

    if [[ "$dry_run" == true ]]; then
        log_info "Would uninstall Helm release: prometheus from monitoring namespace"
        log_info "Would delete Prometheus CRDs"
        log_info "Would delete namespace: monitoring"
        return 0
    fi

    # Check if Prometheus is installed
    if ! helm status prometheus -n monitoring &>/dev/null; then
        log_warn "Prometheus release not found in monitoring namespace"
    else
        log_info "Uninstalling Prometheus Helm release..."
        helm uninstall prometheus -n monitoring --wait --timeout 2m || {
            log_warn "Helm uninstall timed out, continuing with cleanup..."
        }
    fi

    # Delete Prometheus CRDs
    log_info "Deleting Prometheus CRDs..."
    PROM_CRDS=(
        "alertmanagerconfigs.monitoring.coreos.com"
        "alertmanagers.monitoring.coreos.com"
        "podmonitors.monitoring.coreos.com"
        "probes.monitoring.coreos.com"
        "prometheusagents.monitoring.coreos.com"
        "prometheuses.monitoring.coreos.com"
        "prometheusrules.monitoring.coreos.com"
        "scrapeconfigs.monitoring.coreos.com"
        "servicemonitors.monitoring.coreos.com"
        "thanosrulers.monitoring.coreos.com"
    )

    for crd in "${PROM_CRDS[@]}"; do
        if kubectl get crd "$crd" &>/dev/null; then
            if [[ "$force" == true ]]; then
                force_delete_crd "$crd"
            else
                kubectl delete crd "$crd" --timeout=30s 2>/dev/null || {
                    log_warn "CRD $crd is stuck. Run with -f/--force to force removal."
                }
            fi
        fi
    done

    # Delete namespace
    log_info "Deleting monitoring namespace..."
    if [[ "$force" == true ]]; then
        force_delete_namespace "monitoring"
    else
        kubectl delete namespace monitoring --wait=false 2>/dev/null || true
    fi

    log_info "Prometheus uninstalled"
}

# Default values
FORCE=false
CONTOUR_ONLY=false
CERTMANAGER_ONLY=false
PROMETHEUS_ONLY=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        -c|--contour-only)
            CONTOUR_ONLY=true
            shift
            ;;
        -m|--certmanager-only)
            CERTMANAGER_ONLY=true
            shift
            ;;
        -p|--prometheus-only)
            PROMETHEUS_ONLY=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage 1
            ;;
    esac
done

# Validate options
ONLY_COUNT=0
[[ "$CONTOUR_ONLY" == true ]] && ((ONLY_COUNT++))
[[ "$CERTMANAGER_ONLY" == true ]] && ((ONLY_COUNT++))
[[ "$PROMETHEUS_ONLY" == true ]] && ((ONLY_COUNT++))

if [[ $ONLY_COUNT -gt 1 ]]; then
    log_error "Cannot use multiple -only flags together"
fi

# Check for required tools
command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed"; exit 1; }
if [[ "$FORCE" == true ]]; then
    command -v jq >/dev/null 2>&1 || { log_error "jq is required for force mode but not installed"; exit 1; }
fi

echo ""
echo "=============================================="
echo "  Besu Stack Support Infrastructure Uninstaller"
echo "=============================================="
echo ""
log_info "Force mode: $FORCE"
log_info "Dry run: $DRY_RUN"
echo ""

# Check for active besu-stack deployments
if [[ "$DRY_RUN" == false ]]; then
    BESU_RELEASES=$(helm list -A --filter 'besu-stack' -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
    if [[ -n "$BESU_RELEASES" ]]; then
        log_warn "Active besu-stack deployments found:"
        echo "$BESU_RELEASES" | while read -r rel; do
            echo "  - $rel"
        done
        echo ""
        log_warn "These deployments will lose ingress routing, TLS certificates, and monitoring."
        echo ""
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            exit 0
        fi
    fi
fi

# Uninstall components
if [[ "$CERTMANAGER_ONLY" == true ]]; then
    uninstall_certmanager "$FORCE" "$DRY_RUN"
elif [[ "$CONTOUR_ONLY" == true ]]; then
    uninstall_contour "$FORCE" "$DRY_RUN"
elif [[ "$PROMETHEUS_ONLY" == true ]]; then
    uninstall_prometheus "$FORCE" "$DRY_RUN"
else
    # Uninstall all - cert-manager first, then Contour, then Prometheus
    uninstall_certmanager "$FORCE" "$DRY_RUN"
    echo ""
    uninstall_contour "$FORCE" "$DRY_RUN"
    echo ""
    uninstall_prometheus "$FORCE" "$DRY_RUN"
fi

if [[ "$DRY_RUN" == false ]]; then
    echo ""
    echo "=============================================="
    echo "  Uninstall Complete!"
    echo "=============================================="
    echo ""
    log_info "Support infrastructure has been removed."
    echo ""
fi
