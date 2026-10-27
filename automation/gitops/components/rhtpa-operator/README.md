# RHTPA via the operator (3.x)

Installs Red Hat Trusted Profile Analyzer with the **RHTPA operator**
(`TrustedProfileAnalyzer`, `rhtpa.io/v1`) instead of the `charts.openshift.io`
Helm chart that `components/rhtpa` uses.

**Mutually exclusive with `components.rhtpa`** — both publish the same Route
and own the same `server`/`importer` Deployments. `bootstrap-infra` fails the
render if both are enabled.

## Why you would use it

Exploit Intelligence. It integrates through `spec.exploitIntelligence` on this
CR, and the Helm chart has no equivalent — so a chart-installed RHTPA cannot
use Exploit Intelligence at all. If you don't need that, the Helm chart is
simpler and is still the default.

## What it reuses

Nothing here provisions infrastructure. `components.rhtpaPrerequisites` stays
enabled and continues to own all three shared pieces:

| Resource | Provides |
|---|---|
| `tpa-postgresql` (Deployment + Secret) | the database |
| `trustify` (Secret from the ObjectBucketClaim) | S3 credentials |
| `oidc-tpa-cli` (Secret) | the `tpa-cli` client secret |

That is what makes switching a swap rather than a rebuild.

## Things worth knowing before you edit it

**The CR is unvalidated.** The CRD declares `spec` as a bare object with
`x-kubernetes-preserve-unknown-fields: true` and no property schema — this is
a Helm-based operator and `spec` passes straight through to the bundled
chart's values. The API server will therefore accept **any** shape, including
typos. A misspelt key does not get rejected; it silently has no effect. After
changing a field, check the rendered Deployment rather than trusting that the
resource applied cleanly.

**`appDomain` is a suffix, not a hostname.** The server is published at
`server<appDomain>`, so it must begin with a separator —
`-trusted-profile-analyzer.<domain>`.

**The Route timeout annotation goes on the Ingress.** RHTPA's Route is
generated from an Ingress by the ingress-to-route controller and carries an
`ownerReference`, so annotating the Route directly is reverted. It is set via
`ingress.additionalAnnotations` here.

**OperatorGroup.** The CSV supports only `OwnNamespace`/`SingleNamespace`, so
it cannot live in `openshift-operators` the way the Quay and Pipelines
operators do. This chart creates one — but set `createOperatorGroup: false` if
the namespace already has one. Two OperatorGroups in a namespace put every
operator in it into an error state, and the symptom never mentions
OperatorGroups.

## Migrating an existing Helm-chart install

This is a major version move (Trustify 2.x → 3.x) **and** an install-method
change, not a flag flip. The operator's `migrateDatabase` module runs against
the same Postgres the old release used.

```sh
# 1. Back up the database. Non-optional -- the migration is in-place.
PG=$(oc -n trusted-profile-analyzer get pod --no-headers | grep postgres | awk '{print $1}')
oc -n trusted-profile-analyzer exec $PG -- pg_dump -U postgres -d trustify \
  | gzip > trustify-pre-3.x.sql.gz

# 2. Remove the Helm-managed app so the operator can own server/importer.
#    Prerequisites stay -- they are a separate Application.
oc -n openshift-gitops patch application ssc-rhtpa --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
oc -n openshift-gitops delete application ssc-rhtpa

# 3. Switch the flags and re-render bootstrap-infra.
#      components.rhtpa.enabled:         false
#      components.rhtpaOperator.enabled: true

# 4. Watch the migration.
oc -n trusted-profile-analyzer get pods -w
oc -n trusted-profile-analyzer logs -l job-name=migrate-db
```

Expect the Route to be unavailable during the cutover, and expect anything
depending on RHTPA — the `agentic-cve-*` pipelines and `upload-sbom-to-rhtpa`
— to fail while it is down.

If the migration fails, restore by recreating the database from the dump and
re-enabling `components.rhtpa`. The Lightwell dataset is separately
re-loadable with `pipelines/ops/rhtpa-load-lightwell-data.sh`.

## Verifying

```sh
oc -n trusted-profile-analyzer get trustedprofileanalyzer
oc -n trusted-profile-analyzer get pods
curl -sk https://server-trusted-profile-analyzer.<domain>/.well-known/trustify
```

The version in `/.well-known/trustify` should report 3.x. Then re-check an
authenticated call with the pipeline's own credentials, because the OIDC
wiring is the part most likely to differ:

```sh
oc -n tssc-app-ci get secret tpa-secret -o jsonpath='{.data.oidc_issuer_url}' | base64 -d
```
