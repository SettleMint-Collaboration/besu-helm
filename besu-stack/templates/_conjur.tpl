{{/*
Conjur Secret Management Integration
These helpers provide CyberArk Conjur integration for fetching validator private keys.
When global.conjur.enabled is false (default), all helpers return empty strings.
*/}}

{{/*
Check if Conjur is enabled
*/}}
{{- define "besu-stack.conjur.enabled" -}}
{{- if and .Values.global.conjur .Values.global.conjur.enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
Validate required Conjur configuration when integration is enabled
*/}}
{{- define "besu-stack.conjur.validate" -}}
{{- if include "besu-stack.conjur.enabled" . -}}
{{- if not .Values.global.conjur.applianceUrl -}}
{{- fail "global.conjur.applianceUrl is required when global.conjur.enabled=true" -}}
{{- end -}}
{{- if not .Values.global.conjur.account -}}
{{- fail "global.conjur.account is required when global.conjur.enabled=true" -}}
{{- end -}}
{{- if not .Values.global.conjur.authnUrl -}}
{{- fail "global.conjur.authnUrl is required when global.conjur.enabled=true" -}}
{{- end -}}
{{- if not .Values.global.conjur.authnLogin -}}
{{- fail "global.conjur.authnLogin is required when global.conjur.enabled=true" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the Conjur authenticator image
*/}}
{{- define "besu-stack.conjur.image" -}}
{{- $registry := .Values.global.conjur.image.registry -}}
{{- if .Values.global.imageRegistry -}}
{{- $registry = .Values.global.imageRegistry -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry .Values.global.conjur.image.repository .Values.global.conjur.image.tag -}}
{{- end -}}

{{/*
Render the CyberArk Conjur authenticator init container
Authenticates with Conjur and writes access token to /run/conjur/access-token
*/}}
{{- define "besu-stack.conjur.initContainer" -}}
{{- if include "besu-stack.conjur.enabled" . }}
- name: conjur-authenticator
  image: {{ include "besu-stack.conjur.image" . }}
  imagePullPolicy: {{ .Values.global.conjur.image.pullPolicy | default "Always" }}
  env:
    - name: CONTAINER_MODE
      value: init
    - name: CONJUR_APPLIANCE_URL
      value: {{ .Values.global.conjur.applianceUrl | quote }}
    - name: CONJUR_AUTHN_URL
      value: {{ .Values.global.conjur.authnUrl | quote }}
    - name: CONJUR_ACCOUNT
      value: {{ .Values.global.conjur.account | quote }}
    - name: CONJUR_AUTHN_LOGIN
      value: {{ .Values.global.conjur.authnLogin | quote }}
    - name: CONJUR_VERSION
      value: {{ .Values.global.conjur.version | default "5" | quote }}
    {{- if .Values.global.conjur.tokenTimeout }}
    - name: CONJUR_TOKEN_TIMEOUT
      value: {{ .Values.global.conjur.tokenTimeout | quote }}
    {{- end }}
    - name: CONJUR_SSL_CERTIFICATE
      valueFrom:
        configMapKeyRef:
          name: {{ .Values.global.conjur.certificateConfigMap.name | default "conjur-certificate" }}
          key: {{ .Values.global.conjur.certificateConfigMap.key | default "ssl-certificate" }}
    - name: MY_POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: MY_POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: MY_POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
  volumeMounts:
    - name: conjur-access-token
      mountPath: /run/conjur
  {{- with .Values.global.conjur.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Render Conjur-specific volumes:
- conjur-access-token: emptyDir (memory-backed) for the authenticator token
*/}}
{{- define "besu-stack.conjur.volumes" -}}
{{- if include "besu-stack.conjur.enabled" . }}
- name: conjur-access-token
  emptyDir:
    medium: Memory
{{- end }}
{{- end -}}

{{/*
Render Conjur volume mounts for the main container
*/}}
{{- define "besu-stack.conjur.volumeMounts" -}}
{{- if include "besu-stack.conjur.enabled" . }}
- name: conjur-access-token
  mountPath: /run/conjur
{{- end }}
{{- end -}}

{{/*
Render Conjur environment variables for the main Besu container
*/}}
{{- define "besu-stack.conjur.envVars" -}}
{{- if include "besu-stack.conjur.enabled" . }}
- name: CONJUR_APPLIANCE_URL
  value: {{ .Values.global.conjur.applianceUrl | quote }}
- name: CONJUR_ACCOUNT
  value: {{ .Values.global.conjur.account | quote }}
- name: CONJUR_VERSION
  value: {{ .Values.global.conjur.version | default "5" | quote }}
- name: CONJUR_SSL_CERTIFICATE
  valueFrom:
    configMapKeyRef:
      name: {{ .Values.global.conjur.certificateConfigMap.name | default "conjur-certificate" }}
      key: {{ .Values.global.conjur.certificateConfigMap.key | default "ssl-certificate" }}
- name: CONJUR_AUTHN_TOKEN_FILE
  value: /run/conjur/access-token
- name: CONJUR_KEY_PATH_TEMPLATE
  value: {{ .Values.validators.conjur.keyPath | default "besu/validators/{{ordinal}}/private-key" | quote }}
{{- end }}
{{- end -}}

{{/*
The Conjur entrypoint wrapper has moved into besu-stack.validators.startCommand
(_perpod.tpl) so it can compose with the perPodService wrapper.
*/}}
