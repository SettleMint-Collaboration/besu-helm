{{/*
External p2p addressing: perPodService and hostNetwork.

Both features make each Besu pod reachable on a stable, externally-routable
host:port so it can advertise a valid enode to peers in another cluster.

  - perPodService: emits one Service per pod (LoadBalancer or NodePort),
    each selecting a single pod via statefulset.kubernetes.io/pod-name.
  - hostNetwork:    pod shares the node's network namespace; no Service is
                    emitted. Requires pod-to-node pinning and the
                    hostnetwork-v2 SCC on OpenShift. One pod per node.

The two are mutually exclusive within a component (validators or rpcNodes).
Both populate a single env var BESU_ADVERTISED_HOSTS (comma-separated,
indexed by pod ordinal); the wrapper script in besu-stack.validators.startCommand
reads that env var and exports BESU_P2P_HOST before execing Besu.

When both are disabled (default), nothing here is rendered and the chart
behaves exactly as before.
*/}}

{{/*
Per-pod service enablement helpers.
*/}}
{{- define "besu-stack.validators.perPodEnabled" -}}
{{- if and .Values.validators.p2p.perPodService .Values.validators.p2p.perPodService.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "besu-stack.rpcNodes.perPodEnabled" -}}
{{- if and .Values.rpcNodes.p2p.perPodService .Values.rpcNodes.p2p.perPodService.enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
hostNetwork enablement helpers.
*/}}
{{- define "besu-stack.validators.hostNetworkEnabled" -}}
{{- if and .Values.validators.p2p.hostNetwork .Values.validators.p2p.hostNetwork.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "besu-stack.rpcNodes.hostNetworkEnabled" -}}
{{- if and .Values.rpcNodes.p2p.hostNetwork .Values.rpcNodes.p2p.hostNetwork.enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
Unified: is any external-advertised-host mode active for this component?
True when perPodService OR hostNetwork is enabled. Used by the args helper
(to flip --p2p-host to --p2p-interface) and the StatefulSet env block.
*/}}
{{- define "besu-stack.validators.advertisedHostsEnabled" -}}
{{- if or (include "besu-stack.validators.perPodEnabled" .) (include "besu-stack.validators.hostNetworkEnabled" .) -}}
true
{{- end -}}
{{- end -}}

{{- define "besu-stack.rpcNodes.advertisedHostsEnabled" -}}
{{- if or (include "besu-stack.rpcNodes.perPodEnabled" .) (include "besu-stack.rpcNodes.hostNetworkEnabled" .) -}}
true
{{- end -}}
{{- end -}}

{{/*
Comma-separated advertised hosts list per component. Selects from whichever
feature is enabled (validated to be at most one via perpod.validate).
*/}}
{{- define "besu-stack.validators.advertisedHostsCsv" -}}
{{- if include "besu-stack.validators.perPodEnabled" . -}}
{{- join "," (.Values.validators.p2p.perPodService.advertisedHosts | default list) -}}
{{- else if include "besu-stack.validators.hostNetworkEnabled" . -}}
{{- join "," (.Values.validators.p2p.hostNetwork.advertisedHosts | default list) -}}
{{- end -}}
{{- end -}}

{{- define "besu-stack.rpcNodes.advertisedHostsCsv" -}}
{{- if include "besu-stack.rpcNodes.perPodEnabled" . -}}
{{- join "," (.Values.rpcNodes.p2p.perPodService.advertisedHosts | default list) -}}
{{- else if include "besu-stack.rpcNodes.hostNetworkEnabled" . -}}
{{- join "," (.Values.rpcNodes.p2p.hostNetwork.advertisedHosts | default list) -}}
{{- end -}}
{{- end -}}

{{/*
Effective advertised endpoint count for validators. This defaults to the
running replica count, but DR warm clusters can reserve failover endpoints
while validators.replicas is 0.
*/}}
{{- define "besu-stack.validators.perPodAdvertisedReplicaCount" -}}
{{- $cfg := .Values.validators.p2p.perPodService -}}
{{- if and $cfg (hasKey $cfg "advertisedReplicaCount") (ne $cfg.advertisedReplicaCount nil) -}}
{{- $cfg.advertisedReplicaCount | int -}}
{{- else -}}
{{- .Values.validators.replicas | int -}}
{{- end -}}
{{- end -}}

{{- define "besu-stack.validators.hostNetworkAdvertisedReplicaCount" -}}
{{- $cfg := .Values.validators.p2p.hostNetwork -}}
{{- if and $cfg (hasKey $cfg "advertisedReplicaCount") (ne $cfg.advertisedReplicaCount nil) -}}
{{- $cfg.advertisedReplicaCount | int -}}
{{- else -}}
{{- .Values.validators.replicas | int -}}
{{- end -}}
{{- end -}}

{{/*
Validate per-pod + hostNetwork configuration.
Checks (per component, when enabled):
  - perPodService and hostNetwork are mutually exclusive.
  - advertisedHosts length == advertised endpoint count.
  - NodePort only: nodePorts length == advertised endpoint count, ports in 30000-32767,
    no duplicates across validators + rpcNodes combined.
*/}}
{{- define "besu-stack.perpod.validate" -}}
{{- $allNodePorts := list -}}
{{- /* --- validators --- */ -}}
{{- if and (include "besu-stack.validators.perPodEnabled" .) (include "besu-stack.validators.hostNetworkEnabled" .) -}}
{{- fail "validators.p2p.perPodService.enabled and validators.p2p.hostNetwork.enabled are mutually exclusive" -}}
{{- end -}}
{{- if include "besu-stack.validators.perPodEnabled" . -}}
{{- $cfg := .Values.validators.p2p.perPodService -}}
{{- $replicas := include "besu-stack.validators.perPodAdvertisedReplicaCount" . | int -}}
{{- $hosts := $cfg.advertisedHosts | default list -}}
{{- if ne (len $hosts) $replicas -}}
{{- fail (printf "validators.p2p.perPodService.advertisedHosts must have %d entries (one per advertised validator endpoint), got %d" $replicas (len $hosts)) -}}
{{- end -}}
{{- if eq ($cfg.type | default "LoadBalancer") "NodePort" -}}
{{- $ports := $cfg.nodePorts | default list -}}
{{- if ne (len $ports) $replicas -}}
{{- fail (printf "validators.p2p.perPodService.nodePorts must have %d entries when type=NodePort, got %d" $replicas (len $ports)) -}}
{{- end -}}
{{- range $p := $ports -}}
{{- $pi := int $p -}}
{{- if or (lt $pi 30000) (gt $pi 32767) -}}
{{- fail (printf "validators.p2p.perPodService.nodePorts entry %v is outside the default NodePort range 30000-32767" $p) -}}
{{- end -}}
{{- $allNodePorts = append $allNodePorts $pi -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if include "besu-stack.validators.hostNetworkEnabled" . -}}
{{- $cfg := .Values.validators.p2p.hostNetwork -}}
{{- $replicas := include "besu-stack.validators.hostNetworkAdvertisedReplicaCount" . | int -}}
{{- $hosts := $cfg.advertisedHosts | default list -}}
{{- if ne (len $hosts) $replicas -}}
{{- fail (printf "validators.p2p.hostNetwork.advertisedHosts must have %d entries (one per advertised validator endpoint), got %d" $replicas (len $hosts)) -}}
{{- end -}}
{{- end -}}
{{- /* --- rpcNodes --- */ -}}
{{- if and (include "besu-stack.rpcNodes.perPodEnabled" .) (include "besu-stack.rpcNodes.hostNetworkEnabled" .) -}}
{{- fail "rpcNodes.p2p.perPodService.enabled and rpcNodes.p2p.hostNetwork.enabled are mutually exclusive" -}}
{{- end -}}
{{- if include "besu-stack.rpcNodes.perPodEnabled" . -}}
{{- $cfg := .Values.rpcNodes.p2p.perPodService -}}
{{- $replicas := .Values.rpcNodes.replicas | int -}}
{{- $hosts := $cfg.advertisedHosts | default list -}}
{{- if ne (len $hosts) $replicas -}}
{{- fail (printf "rpcNodes.p2p.perPodService.advertisedHosts must have %d entries (one per RPC replica), got %d" $replicas (len $hosts)) -}}
{{- end -}}
{{- if eq ($cfg.type | default "LoadBalancer") "NodePort" -}}
{{- $ports := $cfg.nodePorts | default list -}}
{{- if ne (len $ports) $replicas -}}
{{- fail (printf "rpcNodes.p2p.perPodService.nodePorts must have %d entries when type=NodePort, got %d" $replicas (len $ports)) -}}
{{- end -}}
{{- range $p := $ports -}}
{{- $pi := int $p -}}
{{- if or (lt $pi 30000) (gt $pi 32767) -}}
{{- fail (printf "rpcNodes.p2p.perPodService.nodePorts entry %v is outside the default NodePort range 30000-32767" $p) -}}
{{- end -}}
{{- $allNodePorts = append $allNodePorts $pi -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if include "besu-stack.rpcNodes.hostNetworkEnabled" . -}}
{{- $cfg := .Values.rpcNodes.p2p.hostNetwork -}}
{{- $replicas := .Values.rpcNodes.replicas | int -}}
{{- $hosts := $cfg.advertisedHosts | default list -}}
{{- if ne (len $hosts) $replicas -}}
{{- fail (printf "rpcNodes.p2p.hostNetwork.advertisedHosts must have %d entries (one per RPC replica), got %d" $replicas (len $hosts)) -}}
{{- end -}}
{{- end -}}
{{- /* --- uniqueness across combined validator + RPC nodePort list --- */ -}}
{{- $seen := dict -}}
{{- range $p := $allNodePorts -}}
{{- $k := toString $p -}}
{{- if hasKey $seen $k -}}
{{- fail (printf "nodePort %v is used by more than one perPodService entry; each NodePort must be unique across validators and rpcNodes" $p) -}}
{{- end -}}
{{- $_ := set $seen $k true -}}
{{- end -}}
{{- end -}}

{{/*
Unified entrypoint wrapper for validators.
Combines:
  - advertised-host lookup (perPodService or hostNetwork; both populate
    BESU_ADVERTISED_HOSTS) which sets BESU_P2P_HOST for the enode
  - Conjur key fetch (if enabled) which writes /secrets/nodekey
into a single shell script. Emits nothing if none of the above is active.

Run order:
  1. Extract pod ordinal from $HOSTNAME.
  2. advertisedHosts block: export BESU_P2P_HOST=list[ordinal].
  3. Conjur block: summon → /secrets/nodekey.
  4. exec besu "$@" with the StatefulSet's normal args.
*/}}
{{- define "besu-stack.validators.startCommand" -}}
{{- $advertised := include "besu-stack.validators.advertisedHostsEnabled" . -}}
{{- $conjur := include "besu-stack.conjur.enabled" . -}}
{{- if or $advertised $conjur }}
command:
  - /bin/sh
  - -c
  - |
    set -eu
    ORDINAL="${HOSTNAME##*-}"
    {{- if $advertised }}
    # --- advertise the per-ordinal external host in our enode ---
    if [ -z "${BESU_ADVERTISED_HOSTS:-}" ]; then
      echo "besu-stack: BESU_ADVERTISED_HOSTS env var is empty" >&2; exit 1
    fi
    HOST=$(echo "$BESU_ADVERTISED_HOSTS" | awk -F, -v idx="$((ORDINAL+1))" '{print $idx}')
    if [ -z "$HOST" ]; then
      echo "besu-stack: no advertised host for ordinal $ORDINAL" >&2; exit 1
    fi
    export BESU_P2P_HOST="$HOST"
    echo "besu-stack: ordinal $ORDINAL advertising $HOST in enode"
    {{- end }}
    {{- if $conjur }}
    # --- Conjur: fetch this validator's private key into /secrets/nodekey ---
    if ! command -v summon >/dev/null 2>&1; then
      echo "Conjur: summon binary not found in Besu image" >&2
      exit 1
    fi
    if [ ! -x /usr/local/lib/summon/summon-conjur ]; then
      echo "Conjur: summon-conjur provider not found at /usr/local/lib/summon/summon-conjur" >&2
      exit 1
    fi
    echo "Conjur: Fetching private key for ordinal ${ORDINAL}"
    KEY_PATH=$(printf '%s' "${CONJUR_KEY_PATH_TEMPLATE}" | sed "s/{{ "{{ordinal}}" }}/${ORDINAL}/g")
    umask 077
    mkdir -p /tmp/summon
    printf 'BESU_PRIVATE_KEY: !var %s\n' "${KEY_PATH}" > /tmp/summon/secrets.yml
    summon --ignore-all -f /tmp/summon/secrets.yml sh -c \
      'printf %s "$BESU_PRIVATE_KEY" > /secrets/nodekey && chmod 400 /secrets/nodekey'
    echo "Conjur: Successfully wrote nodekey"
    {{- end }}
    exec besu "$@"
  - --
{{- end -}}
{{- end -}}

{{/*
Entrypoint wrapper for RPC nodes (no Conjur support on RPC side today).
*/}}
{{- define "besu-stack.rpcNodes.perPodCommand" -}}
{{- if include "besu-stack.rpcNodes.advertisedHostsEnabled" . }}
command:
  - /bin/sh
  - -c
  - |
    set -eu
    ORDINAL="${HOSTNAME##*-}"
    if [ -z "${BESU_ADVERTISED_HOSTS:-}" ]; then
      echo "besu-stack: BESU_ADVERTISED_HOSTS env var is empty" >&2; exit 1
    fi
    HOST=$(echo "$BESU_ADVERTISED_HOSTS" | awk -F, -v idx="$((ORDINAL+1))" '{print $idx}')
    if [ -z "$HOST" ]; then
      echo "besu-stack: no advertised host for ordinal $ORDINAL" >&2; exit 1
    fi
    export BESU_P2P_HOST="$HOST"
    echo "besu-stack: ordinal $ORDINAL advertising $HOST in enode"
    exec besu "$@"
  - --
{{- end }}
{{- end -}}
