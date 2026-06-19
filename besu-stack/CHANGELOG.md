# Changelog

## 0.3.5

- Feat: add `openshift.fsGroup` knob. The OpenShift pod securityContext helper now emits `fsGroup` when this value is set, making `/secrets` (an emptyDir) group-writable by the non-root UID under SCCs that use `fsGroup: RunAsAny` (e.g. hostnetwork-v2/custom SCCs that do not auto-inject an fsGroup). Empty/unset = unchanged behaviour, so existing installs are byte-for-byte identical. This lets OpenShift deployments keep `openshift.enabled: true` and drop the per-value securityContext workarounds.
- Fix: the `wait-for-validators` init container (non-OpenShift branch) no longer hardcodes `runAsUser: 1000`; it now inherits `rpcNodes.containerSecurityContext` like the other containers, so it is overridable.
- Docs: clarify that `validators.podSecurityContext` / `rpcNodes.podSecurityContext` are the non-OpenShift (vanilla k8s) defaults and are ignored when `openshift.enabled` is true.

## 0.3.4

- Fix: rename the Conjur authenticator init container from `conjur-authenticator` to `authenticator`.

## 0.3.3

- Fix: deduplicate imagePullSecrets rendered by the `besu-stack.imagePullSecrets` helper. Previously, when the same secret name was provided in both `global.imagePullSecrets` and `imagePullSecrets`, the helper emitted duplicate entries, causing `helm upgrade` to fail with a typed-patch error on Kubernetes server-side apply.
