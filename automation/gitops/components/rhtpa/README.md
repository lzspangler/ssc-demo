# rhtpa

Red Hat Trusted Profile Analyzer — the SBOM store and vulnerability analyzer
the demo's CVE issues and remediation advice come from.

**The RHTPA chart itself is not vendored here.** It is the Red Hat chart
`redhat-trusted-profile-analyzer` from `https://charts.openshift.io/`, pinned
to 1.2.6, referenced directly by the `ssc-rhtpa` Argo Application. Its values
live in `bootstrap-infra/templates/applications.yaml`, which is the only place
to change them.

This directory holds only what that chart expects to already exist:

```
tpa-prerequisites/
  postgresql-*            PostgreSQL 16, 20Gi PVC — RHTPA's graph database
  secret-oidc-cli.yaml    the `oidc-tpa-cli` Secret RHTPA reads its client secret from
  objectbucketclaim.yaml  the S3 bucket (s3 mode only)
  wait-for-keycloak.yaml  PreSync hook: block until the Keycloak issuer answers
```

Vendored from `redhat-ads-tech/ocp-app-platform-demo-helm` v1.4.2
(`trusted-profile-analyzer/charts/tpa-prerequisites`).

## Two charts, one set of values

Three values must agree across the prerequisites chart and the upstream chart,
and nothing checks that they do:

| Value | Here | In the RHTPA chart |
|---|---|---|
| Postgres password | `pgsql.password` | `database.password` (via the `tpa-postgresql` Secret) |
| OIDC issuer | `oidc.issuerUrl` | `oidc.issuerUrl` |
| Storage mode | `storage.type` | `storage.type` |

`bootstrap-infra` derives all three from single values
(`credentials.tpaDbPassword`, `components.keycloak.realm` + `deployer.domain`,
`components.rhtpa.storage.type`), so installing through the app-of-apps keeps
them in step. Installing this chart standalone does not.

The fourth consumer of `tpa-cli`'s secret — the pipeline's `tpa-secret` — is
not GitOps-managed at all; see step 5 of the root README.

## The PreSync hook

`wait-for-keycloak.yaml` polls the realm's
`/.well-known/openid-configuration` before the rest of the sync proceeds. It
is why `keycloak` is a lower sync wave than this component: RHTPA's server
reads its OIDC configuration once at startup and does not retry, so starting
it against a realm that is not yet serving produces a pod that comes up
Healthy and rejects every request.

## Storage

**s3 (default, matches the reference cluster).** Requires OpenShift Data
Foundation. This chart creates an `ObjectBucketClaim` against the
`openshift-storage.noobaa.io` provisioner; ODF answers with a Secret and
ConfigMap named after the claim, and the RHTPA Application reads the access
keys out of that Secret. Note that the `region` RHTPA is given is NooBaa's S3
endpoint URL, not an AWS region name.

**filesystem.** This chart creates nothing and RHTPA provisions its own PVC,
named `storage`. That PVC is mounted by **both** the server and the importer
Deployments, and chart 1.2.6 hardcodes `accessModes: [ReadWriteOnce]` on it
(`templates/services/server/010-PersistentVolumeClaim-storage.yaml`) with no
value to override. Pointing `storageClassName` at an RWX class therefore does
not make it shareable — the claim still requests RWO, Kubernetes requires both
pods on one node, and the importer stays Pending whenever that is not
possible. Usable for a small single-worker demo; prefer s3 otherwise.

Switch `components.rhtpa.storage.type` and nothing else; `bootstrap-infra`
fans it out to both charts.

## Postgres sizing

Upstream's 250m/1Gi and a 1-second readiness timeout do not survive the first
ingest. RHTPA's importers replay the entire CVE List v5, the GitHub advisory
database and the Red Hat CSAF feed — hours of sustained write load. At the
upstream limits the ingest saturates the CPU quota, a `SELECT 1` queued behind
it counts as a failed readiness probe, Postgres is marked NotReady mid-ingest,
and the analysis endpoints end up answering from partial data. The values here
(2 CPU / 4Gi, 5-second probe timeout) are what the reference cluster converged
on.

## Route timeout

RHTPA's Route is **generated from an Ingress** by the ingress-to-route
controller and carries an `ownerReference`, so `oc annotate` on the Route is
reverted within seconds. The `haproxy.router.openshift.io/timeout: 300s`
annotation goes on the Ingress instead, through the chart's
`ingress.additionalAnnotations` — set from `components.rhtpa.routeTimeout`.

The default 30 s is not survivable: `/purl/recommend` cannot complete inside
it at any batch size, and the failure surfaces to the pipeline as a truncated
response rather than an error.

## Changed from upstream

* `objectbucketclaim.yaml` is now conditional on `storage.type == "s3"`, and
  its names come from values rather than being hardcoded.
* `_helpers.tpl` gained `tpa-prerequisites.issuerUrl`, so the issuer can be
  derived from `global.cluster.subdomain` instead of passed in; the PreSync
  hook uses it.
* `values.yaml` rewritten with the resource/probe changes above documented in
  place.
