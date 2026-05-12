# Changelog

## 0.3.4

- Fix: rename the Conjur authenticator init container from `conjur-authenticator` to `authenticator`.

## 0.3.3

- Fix: deduplicate imagePullSecrets rendered by the `besu-stack.imagePullSecrets` helper. Previously, when the same secret name was provided in both `global.imagePullSecrets` and `imagePullSecrets`, the helper emitted duplicate entries, causing `helm upgrade` to fail with a typed-patch error on Kubernetes server-side apply.
