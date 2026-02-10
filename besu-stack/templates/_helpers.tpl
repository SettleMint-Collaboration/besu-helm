{{/*
Expand the name of the chart.
*/}}
{{- define "besu-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "besu-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "besu-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "besu-stack.labels" -}}
helm.sh/chart: {{ include "besu-stack.chart" . }}
{{ include "besu-stack.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "besu-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "besu-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels for immutable resources (PVCs) - excludes version which changes
*/}}
{{- define "besu-stack.immutableLabels" -}}
helm.sh/chart: {{ .Chart.Name }}
{{ include "besu-stack.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "besu-stack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "besu-stack.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Determine the ingress type to use (auto-detection or explicit)
*/}}
{{- define "besu-stack.ingressType" -}}
{{- $type := .Values.ingress.type -}}
{{- if eq $type "auto" -}}
  {{- if .Capabilities.APIVersions.Has "projectcontour.io/v1" -}}
    httpproxy
  {{- else if .Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1" -}}
    httproute
  {{- else if .Capabilities.APIVersions.Has "route.openshift.io/v1" -}}
    route
  {{- else if .Capabilities.APIVersions.Has "networking.k8s.io/v1" -}}
    ingress
  {{- else -}}
    none
  {{- end -}}
{{- else -}}
  {{- $type -}}
{{- end -}}
{{- end -}}

{{/*
Return the proper image name for validators
*/}}
{{- define "besu-stack.validators.image" -}}
{{- $registry := .Values.validators.image.registry -}}
{{- if .Values.global.imageRegistry -}}
{{- $registry = .Values.global.imageRegistry -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry .Values.validators.image.repository (.Values.validators.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{/*
Return the proper image name for RPC nodes
*/}}
{{- define "besu-stack.rpcNodes.image" -}}
{{- $registry := .Values.rpcNodes.image.registry | default .Values.validators.image.registry -}}
{{- if .Values.global.imageRegistry -}}
{{- $registry = .Values.global.imageRegistry -}}
{{- end -}}
{{- $repository := .Values.rpcNodes.image.repository | default .Values.validators.image.repository -}}
{{- $tag := .Values.rpcNodes.image.tag | default .Values.validators.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- end -}}

{{/*
Return the proper image name for init containers
*/}}
{{- define "besu-stack.initContainers.image" -}}
{{- $registry := .Values.initContainers.image.registry -}}
{{- if .Values.global.imageRegistry -}}
{{- $registry = .Values.global.imageRegistry -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry .Values.initContainers.image.repository .Values.initContainers.image.tag -}}
{{- end -}}

{{/*
Return the validator headless service name
*/}}
{{- define "besu-stack.validators.serviceName" -}}
{{- include "besu-stack.fullname" . }}-validators
{{- end -}}

{{/*
Return the RPC service name
*/}}
{{- define "besu-stack.rpcNodes.serviceName" -}}
{{- include "besu-stack.fullname" . }}-rpc
{{- end -}}

{{/*
Generate bootnode enode URLs from validators
Format: enode://<pubkey>@<host>:<port>
If discovery.bootnodes is set, use those. Otherwise, generate from validator service DNS.
*/}}
{{- define "besu-stack.bootnodes" -}}
{{- if .Values.discovery.bootnodes -}}
{{- join "," .Values.discovery.bootnodes -}}
{{- else -}}
{{- $serviceName := include "besu-stack.validators.serviceName" . -}}
{{- $namespace := .Release.Namespace -}}
{{- $port := .Values.validators.p2p.port | default 30303 | int -}}
{{- $replicas := .Values.validators.replicas | int -}}
{{- $nodes := list -}}
{{- range $i := until $replicas -}}
{{- $nodes = append $nodes (printf "%s-%d.%s.%s.svc.cluster.local:%d" $serviceName $i $serviceName $namespace $port) -}}
{{- end -}}
{{- join "," $nodes -}}
{{- end -}}
{{- end -}}

{{/*
Generate static-nodes.json content
Priority:
1. staticNodes.raw - User-provided full enode URLs
2. validators.keys.inline with publicKey - Build enode URLs from public keys
3. DNS-only format - For DNS-based discovery (Xdns-enabled)
*/}}
{{- define "besu-stack.staticNodes" -}}
{{- $staticNodesRaw := .Values.staticNodes.raw | default list -}}
{{- if gt (len $staticNodesRaw) 0 -}}
{{- /* Use user-provided static nodes with full enode URLs */ -}}
{{- $staticNodesRaw | toJson -}}
{{- else -}}
{{- /* Build static nodes from validators */ -}}
{{- $serviceName := include "besu-stack.validators.serviceName" . -}}
{{- $namespace := .Release.Namespace -}}
{{- $port := .Values.validators.p2p.port | int | default 30303 -}}
{{- $replicas := .Values.validators.replicas | int -}}
{{- $inlineKeys := .Values.validators.keys.inline | default list -}}
{{- $hasPublicKeys := false -}}
{{- range $inlineKeys -}}
{{- if .publicKey -}}
{{- $hasPublicKeys = true -}}
{{- end -}}
{{- end -}}
{{- $nodes := list -}}
{{- range $i := until $replicas -}}
{{- $host := printf "%s-%d.%s.%s.svc.cluster.local" $serviceName $i $serviceName $namespace -}}
{{- if and $hasPublicKeys (lt $i (len $inlineKeys)) -}}
{{- /* Build full enode URL with public key */ -}}
{{- $key := index $inlineKeys $i -}}
{{- $pubKey := $key.publicKey | replace "0x" "" | trimPrefix "04" -}}
{{- $nodes = append $nodes (printf "enode://%s@%s:%d?discport=%d" $pubKey $host $port $port) -}}
{{- else -}}
{{- /* DNS-only format for DNS-based discovery */ -}}
{{- $nodes = append $nodes (printf "%s:%d" $host $port) -}}
{{- end -}}
{{- end -}}
{{- $nodes | toJson -}}
{{- end -}}
{{- end -}}

{{/*
Get static-nodes ConfigMap name
Returns either the external configMapRef name or the generated name
*/}}
{{- define "besu-stack.staticNodesConfigMapName" -}}
{{- if .Values.staticNodes.configMapRef.name -}}
{{- .Values.staticNodes.configMapRef.name -}}
{{- else -}}
{{- include "besu-stack.fullname" . -}}-static-nodes
{{- end -}}
{{- end -}}

{{/*
Get static-nodes ConfigMap key
Returns the key to use for static-nodes.json
*/}}
{{- define "besu-stack.staticNodesConfigMapKey" -}}
{{- if .Values.staticNodes.configMapRef.name -}}
{{- .Values.staticNodes.configMapRef.key | default "static-nodes.json" -}}
{{- else -}}
static-nodes.json
{{- end -}}
{{- end -}}

{{/*
Get validator key secret name for a specific index
Returns the secret name that should be used for mounting validator keys
*/}}
{{- define "besu-stack.validators.keySecretName" -}}
{{- $index := .index -}}
{{- $root := .root -}}
{{- if $root.Values.validators.keys.existingSecrets -}}
{{- $secret := index $root.Values.validators.keys.existingSecrets $index -}}
{{- $secret.name -}}
{{- else if $root.Values.validators.keys.existingSecret.name -}}
{{- $root.Values.validators.keys.existingSecret.name -}}
{{- else if $root.Values.validators.keys.inline -}}
{{- include "besu-stack.fullname" $root -}}-validator-keys
{{- else -}}
{{- /* No keys configured - will auto-generate */ -}}
{{- end -}}
{{- end -}}

{{/*
Get validator key file key for a specific index
Returns the key name within the secret
*/}}
{{- define "besu-stack.validators.keySecretKey" -}}
{{- $index := .index -}}
{{- $root := .root -}}
{{- if $root.Values.validators.keys.existingSecrets -}}
{{- $secret := index $root.Values.validators.keys.existingSecrets $index -}}
{{- $secret.key | default "nodekey" -}}
{{- else if $root.Values.validators.keys.existingSecret.name -}}
{{- printf "%s%d" ($root.Values.validators.keys.existingSecret.keyPrefix | default "validator-") $index -}}
{{- else if $root.Values.validators.keys.inline -}}
{{- printf "validator-%d" $index -}}
{{- else -}}
nodekey
{{- end -}}
{{- end -}}

{{/*
Check if validators have keys configured (includes Conjur as a key source)
*/}}
{{- define "besu-stack.validators.hasKeys" -}}
{{- if or .Values.validators.keys.inline .Values.validators.keys.existingSecrets (and .Values.validators.keys.existingSecret .Values.validators.keys.existingSecret.name) (include "besu-stack.conjur.enabled" .) -}}
true
{{- end -}}
{{- end -}}

{{/*
Get RPC node key secret name for a specific index
*/}}
{{- define "besu-stack.rpcNodes.keySecretName" -}}
{{- $index := .index -}}
{{- $root := .root -}}
{{- if $root.Values.rpcNodes.keys.existingSecrets -}}
{{- $secret := index $root.Values.rpcNodes.keys.existingSecrets $index -}}
{{- $secret.name -}}
{{- else if $root.Values.rpcNodes.keys.existingSecret.name -}}
{{- $root.Values.rpcNodes.keys.existingSecret.name -}}
{{- else if $root.Values.rpcNodes.keys.inline -}}
{{- include "besu-stack.fullname" $root -}}-rpc-keys
{{- else -}}
{{- /* No keys configured - will auto-generate */ -}}
{{- end -}}
{{- end -}}

{{/*
Check if RPC nodes have keys configured
*/}}
{{- define "besu-stack.rpcNodes.hasKeys" -}}
{{- if or .Values.rpcNodes.keys.inline .Values.rpcNodes.keys.existingSecrets (and .Values.rpcNodes.keys.existingSecret .Values.rpcNodes.keys.existingSecret.name) -}}
true
{{- end -}}
{{- end -}}

{{/*
Common annotations
*/}}
{{- define "besu-stack.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Pod annotations for config/secret checksums
*/}}
{{- define "besu-stack.podAnnotations" -}}
checksum/genesis: {{ include (print $.Template.BasePath "/configmap-genesis.yaml") . | sha256sum }}
{{- range $key, $value := .Values.podAnnotations }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}

{{/*
OpenShift container security context
Used for all containers when running on OpenShift
*/}}
{{- define "besu-stack.openshiftContainerSecurityContext" -}}
allowPrivilegeEscalation: false
runAsNonRoot: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
OpenShift pod security context
*/}}
{{- define "besu-stack.openshiftPodSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Image pull secrets (combining global and local)
*/}}
{{- define "besu-stack.imagePullSecrets" -}}
{{- $pullSecrets := list }}
{{- range .Values.global.imagePullSecrets }}
{{- if kindIs "string" . }}
{{- $pullSecrets = append $pullSecrets . }}
{{- else if .name }}
{{- $pullSecrets = append $pullSecrets .name }}
{{- end }}
{{- end }}
{{- range .Values.imagePullSecrets }}
{{- if kindIs "string" . }}
{{- $pullSecrets = append $pullSecrets . }}
{{- else if .name }}
{{- $pullSecrets = append $pullSecrets .name }}
{{- end }}
{{- end }}
{{- if $pullSecrets }}
imagePullSecrets:
{{- range $pullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Besu command args for validators - uses FOREST storage for consensus nodes
*/}}
{{- define "besu-stack.validators.args" -}}
- --data-path=/data/besu
- --genesis-file=/etc/genesis/genesis.json
- --node-private-key-file=/secrets/nodekey
- --static-nodes-file=/etc/besu/static-nodes.json
# Storage and performance
- --data-storage-format=FOREST
- --bonsai-limit-trie-logs-enabled=false
- --cache-last-blocks=1024
- --receipt-compaction-enabled=true
- --min-gas-price=0
# Transaction pool
- --tx-pool=SEQUENCED
- --tx-pool-max-size=100000
- --tx-pool-no-local-priority=true
- --tx-pool-limit-by-account-percentage=1
- --tx-pool-enable-save-restore=true
# P2P networking
- --p2p-enabled=true
- --discovery-enabled=true
- --p2p-host=0.0.0.0
- --p2p-port={{ .Values.validators.p2p.port }}
- --max-peers=25
- --nat-method=NONE
- --Xdns-enabled={{ .Values.discovery.dnsEnabled }}
- --Xdns-update-enabled={{ .Values.discovery.dnsEnabled }}
- --random-peer-priority-enabled=true
- --remote-connections-limit-enabled=false
# Sync
- --sync-mode=FULL
{{- if .Values.validators.rpc.http.enabled }}
# HTTP RPC
- --rpc-http-enabled
- --rpc-http-host=0.0.0.0
- --rpc-http-port={{ .Values.validators.rpc.http.port }}
- --rpc-http-api={{ .Values.validators.rpc.http.api }}
- --rpc-http-cors-origins=all
- --rpc-http-authentication-enabled=false
- --rpc-http-max-active-connections=2000
- --rpc-http-max-request-content-length=524288000
- --rpc-http-max-batch-size=512
- --host-allowlist=*
- --revert-reason-enabled=true
- --rpc-tx-feecap=0
{{- end }}
{{- if .Values.validators.rpc.ws.enabled }}
# WebSocket RPC
- --rpc-ws-enabled
- --rpc-ws-host=0.0.0.0
- --rpc-ws-port={{ .Values.validators.rpc.ws.port }}
- --rpc-ws-api={{ .Values.validators.rpc.ws.api | default .Values.validators.rpc.http.api }}
- --rpc-ws-authentication-enabled=false
- --rpc-ws-max-active-connections=2000
- --rpc-ws-max-frame-size=2097152
{{- end }}
{{- if .Values.validators.metrics.enabled }}
# Metrics
- --metrics-enabled
- --metrics-host=0.0.0.0
- --metrics-port={{ .Values.validators.metrics.port }}
{{- end }}
{{- range .Values.validators.extraArgs }}
- {{ . }}
{{- end }}
{{- end -}}

{{/*
Besu command args for RPC nodes - uses BONSAI storage for faster queries
*/}}
{{- define "besu-stack.rpcNodes.args" -}}
- --data-path=/data/besu
- --genesis-file=/etc/genesis/genesis.json
{{- if include "besu-stack.rpcNodes.hasKeys" . }}
- --node-private-key-file=/secrets/nodekey
{{- end }}
- --static-nodes-file=/etc/besu/static-nodes.json
- --data-storage-format=FOREST
- --bonsai-limit-trie-logs-enabled=false
- --cache-last-blocks=1024
- --receipt-compaction-enabled=true
- --min-gas-price=0
# Transaction pool
- --tx-pool=SEQUENCED
- --tx-pool-max-size=100000
- --tx-pool-no-local-priority=true
- --tx-pool-limit-by-account-percentage=1
- --tx-pool-enable-save-restore=true
# P2P networking
- --p2p-enabled=true
- --discovery-enabled=true
- --p2p-host=0.0.0.0
- --p2p-port={{ .Values.rpcNodes.p2p.port }}
- --max-peers=25
- --nat-method=NONE
- --Xdns-enabled={{ .Values.discovery.dnsEnabled }}
- --Xdns-update-enabled={{ .Values.discovery.dnsEnabled }}
- --random-peer-priority-enabled=true
- --remote-connections-limit-enabled=false
# Sync
- --sync-mode=FULL
{{- if .Values.rpcNodes.rpc.http.enabled }}
# HTTP RPC
- --rpc-http-enabled
- --rpc-http-host=0.0.0.0
- --rpc-http-port={{ .Values.rpcNodes.rpc.http.port }}
- --rpc-http-api={{ .Values.rpcNodes.rpc.http.api }}
- --rpc-http-cors-origins=all
- --rpc-http-authentication-enabled=false
- --rpc-http-max-active-connections=2000
- --rpc-http-max-request-content-length=524288000
- --rpc-http-max-batch-size=512
- --host-allowlist=*
- --revert-reason-enabled=true
- --rpc-tx-feecap=0
{{- end }}
{{- if .Values.rpcNodes.rpc.ws.enabled }}
# WebSocket RPC
- --rpc-ws-enabled
- --rpc-ws-host=0.0.0.0
- --rpc-ws-port={{ .Values.rpcNodes.rpc.ws.port }}
- --rpc-ws-api={{ .Values.rpcNodes.rpc.ws.api }}
- --rpc-ws-authentication-enabled=false
- --rpc-ws-max-active-connections=2000
- --rpc-ws-max-frame-size=2097152
{{- end }}
{{- if .Values.rpcNodes.rpc.graphql.enabled }}
# GraphQL
- --graphql-http-enabled
- --graphql-http-host=0.0.0.0
- --graphql-http-port={{ .Values.rpcNodes.rpc.graphql.port }}
- --graphql-http-cors-origins=all
{{- end }}
{{- if .Values.rpcNodes.metrics.enabled }}
# Metrics
- --metrics-enabled
- --metrics-host=0.0.0.0
- --metrics-port={{ .Values.rpcNodes.metrics.port }}
{{- end }}
{{- range .Values.rpcNodes.extraArgs }}
- {{ . }}
{{- end }}
{{- end -}}
