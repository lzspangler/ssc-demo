# ssc-demo platform — GitOps install

Everything the supply-chain demo needs, other than the pipelines themselves,
installed by Argo CD onto a cluster that already has OpenShift GitOps running.

| Component | Where the chart comes from | What it gives the demo |
|---|---|---|
| `components/pipelines` | this repo | OpenShift Pipelines (Tekton) operator |
| `components/keycloak` | vendored from `redhat-ads-tech/ocp-app-platform-demo-helm` v1.4.2 | the `backstage` realm; `tpa-cli` / `tpa-frontend` / `trusted-artifact-signer` clients |
| `components/gitlab` | vendored from the same, heavily reworked | the application repository, the CVE issue board, the `/remediate` webhook, and the pipeline's SCM credential |
| `components/rhtas` | vendored from the same | Fulcio / Rekor / CTlog / TSA / TUF for keyless signing |
| `components/rhtpa/tpa-prerequisites` | vendored from the same | RHTPA's Postgres, OIDC secret and S3 bucket |
| RHTPA itself | `https://charts.openshift.io/`, chart `redhat-trusted-profile-analyzer` 1.2.6 | SBOM ingest, vulnerability analysis, backport/fix-version lookup |
| `artifactory/` | `https://charts.jfrog.io`, chart `artifactory-oss` | the Maven mirror. **Separate install — see `artifactory/INSTALL.md`.** |

`bootstrap-infra` is the app-of-apps that creates an Argo CD `Application` for
each of the first six. Artifactory is deliberately not part of it: it has its
own runbook, its own secrets and its own `oc apply` ordering, and it already
works.

## Where this came from

The reference cluster this reproduces is not built from this repository. Its
platform comes from `redhat-ads-tech/ocp-app-platform-demo-helm` at tag
`v1.4.2` — a Red Hat workshop environment that also ships Developer Hub, Vault,
DevSpaces, Quay and an orchestrator. The charts here are that upstream with
everything ssc-demo does not use removed, the per-cluster values collapsed onto
a single `deployer.domain`, and three things added that the reference cluster
still had wired by hand:

* the GitLab group, imported application repository and CVE labels,
* the issue-comment webhook that drives `agentic-cve-remediation`,
* the GitLab project access token the pipeline pushes and opens MRs with,
  written straight into the pipeline namespace as `scm-auth-secret`.

Per-component deviations are documented at the top of each chart's
`values.yaml`.

## Prerequisites

* `oc` logged in as cluster-admin.
* OpenShift GitOps installed, with the default `openshift-gitops` Argo CD
  running and its application-controller holding cluster-admin (the default).
* A default RWO StorageClass. The install provisions PVCs for GitLab (10Gi),
  its Postgres and Redis, Keycloak's Postgres (5Gi) and RHTPA's Postgres
  (20Gi).
* **OpenShift Data Foundation**, if you keep the default S3 storage for RHTPA.
  See *Storage* below for the alternative.
* Egress to `charts.openshift.io`, `registry.redhat.io`, `quay.io`,
  `github.com` (the GitLab import and two of RHTPA's importers clone from
  there) and `redhat.com` (the CSAF importer).

## Install

### 1. Collect the cluster domain

```sh
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
```

### 2. Write an uncommitted overrides file

Four credentials have no sensible default and must not live in git. Put them,
with the domain, in a file you keep out of the repository:

```sh
cat > /tmp/ssc-demo-values.yaml <<EOF
deployer:
  domain: $(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
credentials:
  keycloakDbPassword: $(openssl rand -hex 16)
  gitlabRootPassword: $(openssl rand -hex 16)
  tpaDbPassword: $(openssl rand -hex 16)
  tpaCliClientSecret: $(openssl rand -hex 16)
EOF
chmod 600 /tmp/ssc-demo-values.yaml
```

Keep this file. `tpaCliClientSecret` in particular is needed again in step 5,
and `gitlabRootPassword` is how you log into GitLab as root.

### 3. Create the Applications

```sh
helm template ssc automation/gitops/bootstrap-infra \
  -f /tmp/ssc-demo-values.yaml | oc apply -f -
```

The waves then run themselves: pipelines (0) → keycloak (5) → gitlab (8) →
rhtas + rhtpa-prerequisites (10) → rhtpa (15). A wave does not start until the
previous one is Healthy, so an Application stuck in Progressing blocks
everything after it.

```sh
oc -n openshift-gitops get applications -l app.kubernetes.io/part-of=ssc-demo
```

Expect 20–30 minutes for the operators and GitLab, then hours for RHTPA's
first full ingest of the CVE, OSV and CSAF feeds.

### 4. Check what GitLab seeded

The seeding Job does the parts that used to be manual. When
`initialize-gitlab` completes, the pipeline namespace should already hold both
credentials:

```sh
oc -n gitlab get job initialize-gitlab
oc -n tssc-app-ci get secret scm-auth-secret gitlab-webhook-secret
```

`scm-auth-secret` holds a GitLab **project** access token scoped to the one
application repository, not the root PAT. If the Secret already exists and
holds a real token, the Job leaves it alone — so re-running the seeding does
not invalidate a credential a pipeline is mid-run with.

### 5. Finish the RHTPA credential

`tpa-cli`'s client secret reaches Keycloak and RHTPA through the chart, but the
Tekton tasks read it from their own Secret, which is not managed here. The
pipelines pass `tpa-secret` as `TRUSTIFICATION_SECRET_NAME`, and
`upload-sbom-to-trustification` requires exactly these four keys:

```sh
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
oc -n tssc-app-ci create secret generic tpa-secret \
  --from-literal=bombastic_api_url="https://server-trusted-profile-analyzer.${DOMAIN}" \
  --from-literal=oidc_issuer_url="https://sso.${DOMAIN}/realms/backstage" \
  --from-literal=oidc_client_id=tpa-cli \
  --from-literal=oidc_client_secret='<tpaCliClientSecret from step 2>' \
  --dry-run=client -o yaml | oc apply -f -
```

A wrong `oidc_client_secret` here is invisible until a build reaches the
upload step and the token request comes back 401.

## Storage

RHTPA stores SBOMs and advisory documents in object storage, and the reference
cluster uses ODF: the prerequisites chart creates an `ObjectBucketClaim`
against `openshift-storage.noobaa.io`, and RHTPA reads the resulting Secret.
That is the default here.

Without ODF, switch to filesystem storage **in both places at once** —
`components.rhtpa.storage.type` drives the RHTPA chart, and the prerequisites
chart only skips the bucket when it sees the same value:

```yaml
components:
  rhtpa:
    storage:
      type: filesystem
      storageClassName: <an RWX class>
```

Be aware of what you are accepting. Chart 1.2.6 mounts one PVC, named
`storage`, into **both** the server and the importer Deployment — and
hardcodes `accessModes: [ReadWriteOnce]` on it, with no value to override.
An RWX-capable storage class does not help: the claim still requests RWO, so
Kubernetes will only schedule the two pods together, and the second stays
Pending whenever it cannot land on the first one's node. Filesystem mode works
for a single-node-ish demo and is fragile anywhere else.

S3 is the path the reference cluster uses and the one to prefer.

## Timeouts

Two routes in this platform need HAProxy's `timeout server` raised from its
30 s default, for reasons documented where they are set:

* **RHTPA** (`bootstrap-infra/values.yaml`, `components.rhtpa.routeTimeout`) —
  `/purl/recommend` cannot complete inside 30 s at any batch size. RHTPA's
  Route is generated from an Ingress by the ingress-to-route controller and
  carries an `ownerReference`, so annotating the Route directly is reverted;
  the annotation goes on the Ingress through the chart's
  `ingress.additionalAnnotations`.
* **GitLab** (`components/gitlab/templates/rt-gitlab.yaml`) — the seeding job's
  repository import is a server-side clone of a GitHub repository held open on
  the API connection, and the pipeline pushes remediation branches through the
  same Route. This Route is created directly, so the annotation sits on it.

Artifactory has the same problem and solves it differently — the pipeline
talks to its in-cluster Service and skips the router entirely. See the
Artifactory note in `pipelines/README.md`.

## Things to know before you edit

* **Every Application has `selfHeal: true`.** An `oc edit` or `oc annotate`
  against a managed resource is reverted on the next reconcile. Change the
  chart.
* **The Keycloak realm re-randomises on every render.** Unset client secrets
  default to a fresh `randAlphaNum 32` and resource ids to a fresh `uuidv4`,
  so the rendered `KeycloakRealmImport` never matches the live one. The
  Application ignores differences on `.id`, `.containerId` and `.secret`;
  without that, selfHeal would rotate the secret of every client in use.
* **The GitLab seeding Job is `Replace=true`.** A Job's pod template is
  immutable, so editing the playbook would otherwise fail the sync with "field
  is immutable" and silently keep the old seeding. Replace is also how you
  re-seed: change the ConfigMap and sync.
* **`components/lightwell-repo`** is the older Nexus-based artifact repository.
  It is not wired into `bootstrap-infra` — Artifactory replaced it — and is
  left in the tree only for reference.
