# keycloak

The identity provider the rest of the platform authenticates against. Four
subcharts, installed in this order by sync wave:

| Wave | Subchart | What it does |
|---|---|---|
| -3 | `keycloak-operator` | OperatorGroup + Subscription for `rhbk-operator` |
| -3 | `keycloak-db` | PostgreSQL for Keycloak itself (5Gi PVC) |
| -1 | `keycloak` | the `Keycloak` CR and its Route |
| -1 | `keycloak-realm-import` | the `KeycloakRealmImport` CR — a 2200-line realm document |

Vendored from `redhat-ads-tech/ocp-app-platform-demo-helm` v1.4.2, which is
what the reference cluster runs.

## What the demo actually uses

The realm is published at `https://sso.<subdomain>/realms/backstage`, and three
of its clients matter:

* **`tpa-cli`** — confidential client, client-credentials grant. Every
  machine-to-machine call to RHTPA uses it: the Tekton tasks uploading SBOMs,
  the `lightwell` analysis calls, and RHTPA's own importers.
* **`tpa-frontend`** — public client, browser login to the RHTPA console. Its
  redirect URIs default to the RHTPA server Route derived from the subdomain.
* **`trusted-artifact-signer`** — public client the RHTAS `SecureSign` CR names
  as its OIDC client for keyless signing.

`backstage`, `backstage-plugin` and `openshift` are also in the realm and are
unused here. They are left in because removing clients from a single large
import document is more likely to break the realm than to help, and an
unreferenced client costs nothing. They are not inert in one respect — see
*Null redirect URIs* below.

## The realm name is load-bearing

`backstage` is baked into the issuer URL that the RHTAS `SecureSign` CR, the
RHTPA chart, the `tpa-prerequisites` PreSync hook and the pipeline's
`oidc-issuer` parameter all carry. `bootstrap-infra` derives all of them from
one `components.keycloak.realm`, so renaming it there is safe; renaming it
anywhere else is not.

## Null redirect URIs

A client whose `redirectUri` is unset renders a list with a single null entry,
and the Keycloak operator rejects the whole import — taking `tpa-cli` and
`tpa-frontend` down with the clients nobody uses. `keycloak-realmimport.yaml`
therefore gives `tpaFrontend`, `backstage` and `openshift` derived defaults
based on the cluster subdomain rather than leaving them empty.

## Why the Argo Application ignores `.secret` and `.id`

The realm template defaults every unset client secret to `randAlphaNum 32` and
every resource id to `uuidv4`. Both are evaluated at render time, so two
renders of the same values never match, and the Application would be
permanently OutOfSync. With `selfHeal: true` that is not cosmetic: Argo CD
would re-import the realm on every reconcile and rotate the secret of every
client currently in use. `bootstrap-infra` adds:

```yaml
ignoreDifferences:
  - group: k8s.keycloak.org
    kind: KeycloakRealmImport
    jqPathExpressions:
      - '.. | (.id, .containerId, .secret)? | strings'
```

Set a secret explicitly (as `tpa-cli` is) and it is stable regardless.

## Changed from upstream

* **`values.yaml` exists.** Upstream's umbrella `values.yaml` is a zero-byte
  file; every value came from the environment's own overlay. This one carries
  the defaults the demo needs.
* **Catalog source** `redhat-operators-snapshot` → `redhat-operators`. The
  snapshot catalog only exists in the Red Hat workshop environment the
  reference cluster is built from.
* **Hostnames derive from `global.cluster.subdomain`.** `keycloak.ocpDomain`
  prefers it and only falls back to the IngressController `lookup`, because
  Argo CD renders with `helm template` and no cluster connection — there the
  lookup returns an empty dict and the hostname silently collapses to
  `sso.`.
* **Fixed a duplicate `annotations:` key** in `keycloak/templates/route.yaml`
  (a latent bug in the vendored source — the second block won, discarding the
  first).
* **Sample users off**, groups trimmed to developers / platformengineers /
  infrastructure. Nothing in ssc-demo logs in as a human.

## Values you must set

| Value | Notes |
|---|---|
| `global.cluster.subdomain` | apps subdomain, no leading dot |
| `keycloak-db.pgsql.password` | not committed |
| `keycloak-realm-import.client.tpaCli.secret` | **shared** — the same value goes to `rhtpa/tpa-prerequisites` and the pipeline's `tpa-secret`; see the root README |
