# rhtas

Red Hat Trusted Artifact Signer. Two subcharts:

| Wave | Subchart | What it does |
|---|---|---|
| 1 | `rhtas-operator` | Subscription for `rhtas-operator` in `openshift-operators` |
| 2 | `trusted-artifact-signer` | a `Securesign` CR, which the operator expands into Fulcio, Rekor, CTlog, Trillian, a timestamp authority and a TUF server |

Vendored from `redhat-ads-tech/ocp-app-platform-demo-helm` v1.4.2, which is
what the reference cluster runs.

## What the demo uses it for

Keyless signing of the container image the Maven pipeline builds. `cosign`
obtains an OIDC token from the `trusted-artifact-signer` client in the Keycloak
`backstage` realm, Fulcio issues a short-lived certificate bound to that
identity, and the signature is logged to Rekor. There is no long-lived key
anywhere, which is the point.

The pipeline's verification step reads the Rekor URL and TUF mirror from its
own parameters; those must point at this namespace
(`trusted-artifact-signer`), not at the `tssc-tas` the upstream workshop uses.

## The OIDC issuer

`securesignCR.yaml` takes its issuer from the
`trusted-artifact-signer.oidcIssuer` helper: an explicit `oidc` value wins,
otherwise it is built as `https://<ssoHostPrefix>.<global.cluster.subdomain>/realms/<realm>`.
That has to resolve to exactly the same string Keycloak publishes as its
issuer — Fulcio fetches `/.well-known/openid-configuration` from it and
validates the `iss` claim against it, so a trailing-slash or realm-name
mismatch fails at signing time with a token-validation error that names
neither component.

`bootstrap-infra` passes `realm` from the same value it gives Keycloak, so
the two cannot drift when installed together.

## Removed from upstream

`cosign-keygen-{job,serviceaccount,clusterrole,clusterrolebinding}.yaml` — a
Job that generated a cosign key pair and wrote it into Vault, plus the
cluster-scoped RBAC it needed to do so. ssc-demo has no Vault and signs
keylessly, so the key pair had no consumer and the ClusterRole was pure
attack surface.

## Changed

* **Catalog source** `redhat-operators-snapshot` → `redhat-operators` (the
  snapshot catalog is workshop-only).
* **Namespace is templated.** Upstream's `Securesign` CR took the namespace
  from the release; here it is `trusted-artifact-signer.namespace`, so the
  Argo Application and the CR cannot disagree.
* **`values.yaml` rewritten** around `global.cluster.subdomain` instead of
  per-cluster hostnames.

## Values you must set

| Value | Notes |
|---|---|
| `global.cluster.subdomain` | apps subdomain, no leading dot |
| `trusted-artifact-signer.realm` | must match the Keycloak component's realm |

`email` / `org` populate the certificate authority's subject and are cosmetic
for the demo.
