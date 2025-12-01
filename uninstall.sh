#!/usr/bin/env bash
set -euo pipefail

# Besu Stack Uninstaller
# Cleanly removes besu-stack deployments with stuck resource handling

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Besu Stack Uninstaller

Cleanly removes besu-stack Helm releases and their namespaces,
including handling of stuck resources with finalizers.

Usage: $0 [options]

Options:
  -n, --namespace <ns>    Namespace to uninstall (default: besu-stack)
  -r, --release <name>    Helm release name (default: besu-stack)
  -a, --all               Uninstall all besu-stack releases in cluster
  -f, --force             Force removal of stuck resources
  -k, --keep-pvcs         Keep PersistentVolumeClaims (retain blockchain data)
  -d, --dry-run           Show what would be uninstalled without uninstalling
  -h, --help              Show this help message

Examples:
  $0                              # Uninstall from default namespace
  $0 -n besu-testnet              # Uninstall from besu-testnet namespace
  $0 -n besu-production -f        # Force uninstall from besu-production
  $0 -n besu-production -k        # Uninstall but keep PVCs
  $0 -a                           # Uninstall all besu-stack releases
  $0 -a -f                        # Force uninstall all releases

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

# Remove finalizers from stuck resources in a namespace
remove_finalizers() {
    local namespace=$1
    log_info "Removing finalizers from stuck resources in $namespace..."

    # Remove finalizers from HTTPProxy
    for proxy in $(kubectl get httpproxy -n "$namespace" -o name 2>/dev/null || true); do
        log_info "  Removing finalizers from $proxy"
        kubectl patch "$proxy" -n "$namespace" \
            -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done

    # Remove finalizers from certificates (cert-manager)
    for cert in $(kubectl get certificates -n "$namespace" -o name 2>/dev/null || true); do
        log_info "  Removing finalizers from $cert"
        kubectl patch "$cert" -n "$namespace" \
            -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done

    # Remove finalizers from PVCs (only if not keeping them)
    if [[ "${KEEP_PVCS:-false}" != true ]]; then
        for pvc in $(kubectl get pvc -n "$namespace" -o name 2>/dev/null || true); do
            log_info "  Removing finalizers from $pvc"
            kubectl patch "$pvc" -n "$namespace" \
                -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
    fi
}

# Force delete a namespace that's stuck in Terminating
force_delete_namespace() {
    local namespace=$1
    log_info "Force deleting namespace $namespace..."

    # First, try to remove finalizers from all resources
    remove_finalizers "$namespace"

    # Check if namespace is stuck in Terminating
    local ns_status
    ns_status=$(kubectl get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "$ns_status" == "Terminating" ]]; then
        log_warn "Namespace $namespace is stuck in Terminating state"

        # Remove finalizers from namespace itself
        log_info "Removing finalizers from namespace..."
        kubectl get namespace "$namespace" -o json | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f - 2>/dev/null || true
    fi
}

# Uninstall a single release
uninstall_release() {
    local namespace=$1
    local release=$2
    local force=$3
    local dry_run=$4
    local keep_pvcs=$5

    log_step "Uninstalling $release from namespace $namespace..."

    if [[ "$dry_run" == true ]]; then
        log_info "Would uninstall Helm release: $release from $namespace"
        if [[ "$keep_pvcs" == true ]]; then
            log_info "Would keep PVCs in namespace"
        fi
        log_info "Would delete namespace: $namespace"
        return 0
    fi

    # Check if release exists
    if ! helm status "$release" -n "$namespace" &>/dev/null; then
        log_warn "Release $release not found in namespace $namespace"
    else
        # Uninstall Helm release
        log_info "Uninstalling Helm release..."
        helm uninstall "$release" -n "$namespace" --wait --timeout 5m || {
            log_warn "Helm uninstall timed out, continuing with cleanup..."
        }
    fi

    # Handle PVCs if keeping them
    if [[ "$keep_pvcs" == true ]]; then
        log_info "Keeping PVCs in namespace $namespace"
        # Label PVCs to preserve them
        for pvc in $(kubectl get pvc -n "$namespace" -o name 2>/dev/null || true); do
            kubectl label "$pvc" -n "$namespace" besu-stack/preserved=true 2>/dev/null || true
        done
        log_warn "PVCs preserved. To delete them later:"
        log_warn "  kubectl delete pvc -n $namespace -l besu-stack/preserved=true"
        return 0
    fi

    # Delete namespace
    log_info "Deleting namespace $namespace..."
    kubectl delete namespace "$namespace" --wait=false 2>/dev/null || true

    # If force mode, handle stuck resources
    if [[ "$force" == true ]]; then
        # Wait a moment for deletion to start
        sleep 2
        force_delete_namespace "$namespace"
    fi

    # Wait for namespace to be deleted
    log_info "Waiting for namespace deletion..."
    local timeout=60
    local elapsed=0
    while kubectl get namespace "$namespace" &>/dev/null && [[ $elapsed -lt $timeout ]]; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [[ $((elapsed % 10)) -eq 0 ]]; then
            log_info "  Still waiting... ($elapsed seconds)"
        fi
    done

    if kubectl get namespace "$namespace" &>/dev/null; then
        if [[ "$force" == true ]]; then
            log_error "Namespace $namespace still exists after force deletion"
        else
            log_warn "Namespace $namespace is stuck. Run with -f/--force to force removal."
        fi
    else
        log_info "Namespace $namespace deleted successfully"
    fi
}

# Default values
NAMESPACE="besu-stack"
RELEASE_NAME="besu-stack"
UNINSTALL_ALL=false
FORCE=false
KEEP_PVCS=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r|--release)
            RELEASE_NAME="$2"
            shift 2
            ;;
        -a|--all)
            UNINSTALL_ALL=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -k|--keep-pvcs)
            KEEP_PVCS=true
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

# Check for required tools
command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed"; exit 1; }
if [[ "$FORCE" == true ]]; then
    command -v jq >/dev/null 2>&1 || { log_error "jq is required for force mode but not installed"; exit 1; }
fi

echo ""
echo "=============================================="
echo "  Besu Stack Uninstaller"
echo "=============================================="
echo ""

if [[ "$UNINSTALL_ALL" == true ]]; then
    # Find all besu-stack releases
    log_info "Finding all besu-stack releases..."
    RELEASES=$(helm list -A --filter 'besu-stack' -o json | jq -r '.[] | "\(.namespace) \(.name)"' 2>/dev/null || true)

    if [[ -z "$RELEASES" ]]; then
        log_info "No besu-stack releases found"
        exit 0
    fi

    echo "$RELEASES" | while read -r ns rel; do
        if [[ -n "$ns" && -n "$rel" ]]; then
            uninstall_release "$ns" "$rel" "$FORCE" "$DRY_RUN" "$KEEP_PVCS"
            echo ""
        fi
    done
else
    uninstall_release "$NAMESPACE" "$RELEASE_NAME" "$FORCE" "$DRY_RUN" "$KEEP_PVCS"
fi

if [[ "$DRY_RUN" == false ]]; then
    echo ""
    echo "=============================================="
    echo "  Uninstall Complete!"
    echo "=============================================="
    echo ""
fi
