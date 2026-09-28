# Artifactory OSS on OpenShift (GitOps)

Installs **JFrog Artifactory OSS** (Helm chart `artifactory-oss` 107.161.26 / app
7.161.26) as an Argo CD Application and preconfigures two **remote Maven proxy**
repositories plus a **virtual** repo that aggregates them:

| Repo key               | Kind    | Proxies / aggregates                                                              |
| ---------------------- | ------- | -------------------------------------------------------------------------------- |
| `lightwell-validated`  | remote  | `https://packages.redhat.com/lightwell/public-lightwell-demo/java/validated/`     |
| `lightwell-remediated` | remote  | `https://packages.redhat.com/lightwell/public-lightwell-demo/java/remediated/`    |
| `maven-central`        | remote  | `https://repo.maven.apache.org/maven2/`                                            |
| `lightwell`            | virtual | `lightwell-validated` + `lightwell-remediated` + `maven-central`                   |
| `maven`                | virtual | `lightwell-validated` + `lightwell-remediated` + `maven-central`                   |

Point Maven at a virtual repo: `https://<route>/artifactory/maven` (or `/lightwell`).
In each virtual the Lightwell proxies are listed ABOVE `maven-central`, so curated
Red Hat artifacts win and Central is the fallback.

> REMINDER: repos can ONLY be created by the first-boot bootstrap importer (OSS
> has no runtime create path — REST *or* UI). Editing this repo set on an
> already-initialized instance requires reinitializing so the importer re-runs
> (delete the `artifactory`+`artifactory-postgresql` StatefulSets and their PVCs;
> the config lives in the Postgres `configs` store, so the DB PVC must go too).

## Files

- `application-artifactory.yaml` — Argo CD Application (chart-repo source, umbrella
  values). Wires the repo bootstrap via `configMapName` + `copyOnEveryStartup`.
- `openshift-extras.yaml` — cluster-specific manifests that the chart-repo source
  can't carry: admin/keys Secrets, the custom SCC, the Route, and the repository
  bootstrap **ConfigMap** (`artifactory-repo-bootstrap`).

## Apply order

See **INSTALL.md** for the full fresh-cluster runbook (prereqs, verification,
troubleshooting). The essential ordering — apply the extras FIRST, then OVERWRITE
the REPLACE_ME stubs with real secrets, then the Application:

```sh
oc create namespace artifactory --dry-run=client -o yaml | oc apply -f -

# SCC + Route + repo-bootstrap ConfigMap + REPLACE_ME secret stubs:
oc apply -f openshift-extras.yaml

# Overwrite the stubs with real values (do NOT commit real values). Must run
# BEFORE applying the Application so pods never start with placeholders, and the
# Postgres secret in particular MUST be a plain oc-created secret (no Helm/Argo CD
# ownership) so existingSecret suppresses the chart's own secret template:
oc -n artifactory create secret generic artifactory-admin \
  --from-literal=password='admin@*=<STRONG-PASSWORD>' \
  --dry-run=client -o yaml | oc apply -f -
oc -n artifactory create secret generic artifactory-keys \
  --from-literal=master-key="$(openssl rand -hex 32)" \
  --from-literal=join-key="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n artifactory create secret generic artifactory-postgresql \
  --from-literal=postgres-password="$(openssl rand -hex 16)" \
  --from-literal=password="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f application-artifactory.yaml
```

## Why the repos are bootstrapped, not created via API

On **Artifactory OSS 7.161** there is no unguarded programmatic way to *create* a
repository at runtime:

- `PUT/POST /api/repositories/{key}` (public REST) and
  `/ui/api/v1/ui/repositories/{type}` (the UI's own backend) both return
  **HTTP 400 "This REST API is available only in Artifactory Pro"** — for local,
  remote, and virtual alike. (`GET /api/repositories`, `GET /api/system/version`,
  and `GET /api/system/ping` *do* work on OSS.)
- 7.161 also moved repositories **out of the config descriptor**
  (`artifactory.config.xml`) into a separate store, so pushing them via
  `POST /api/system/configuration` is rejected with *"config descriptor contains
  old repositories configuration, please use the new repositories export format
  instead."*

The one path that is **not** Pro-gated is the **first-boot bootstrap importer**
(`org.artifactory.repo.service.RepositoryConfigBootstrapServiceImpl`). On startup,
if only the default repos exist, it reads:

```
$ARTIFACTORY_HOME/etc/artifactory/artifactory.repository.config.import.json
```

and deserializes it into `org.artifactory.model.AggregatedReposConfig` (the "new
repositories export format"). We ship that JSON in the `artifactory-repo-bootstrap`
ConfigMap and let the chart deliver it:

```
ConfigMap (configMapName)  ->  /bootstrap/            (mounted)
                           ->  /artifactory_bootstrap/ (chart preStart copy)
copyOnEveryStartup         ->  <mountPath>/etc/artifactory/   (chart copy)
```

`copyOnEveryStartup` re-copies on every boot, which is harmless: the importer only
runs when just the default repos are present, and skips otherwise.

> NOTE: a REST bootstrap Job (the pattern used elsewhere, e.g. the RHTPA
> importers) does **not** work here because of the OSS Pro gate above. Do not
> re-introduce one for repo creation.

## Platform notes (verified on cluster-6jnws)

- `artifactory-oss` is an **umbrella** chart: every value nests under a top-level
  `artifactory:` key (hence `artifactory.artifactory.*`).
- **Custom SCC required**: the pods set fixed non-root uids (1030/1031/1127, and
  bundled postgres 1001) *and* `seccompProfile: RuntimeDefault`. No stock SCC
  allows both, so `openshift-extras.yaml` ships `artifactory-scc`
  (= anyuid + `seccompProfiles:[runtime/default]` + `seLinuxContext: RunAsAny`)
  granted to SAs `artifactory`, `default`, `artifactory-postgresql`.
- **Bundled PostgreSQL required** — 7.161 hard-rejects embedded Derby.
- **master/join keys** must be hex (`openssl rand -hex 32` / `-hex 16`).
- **admin** seed: the `password` secret key is mounted verbatim as
  `access/bootstrap.creds`, so it must be `admin@*=<PASSWORD>`.
- **Pin the Postgres password** (`postgresql.auth.existingSecret`). The bundled
  bitnami subchart's secret template reuses an existing password only via a
  cluster `lookup`, which Argo CD's repo-server can't do during `helm template`,
  so without `existingSecret` it mints a NEW random password on every render.
  A re-sync then rewrites the secret while the Postgres data dir still holds the
  original -> `password authentication failed`. The pinned secret must be a plain
  secret with NO Helm/Argo CD ownership labels (`oc create secret` produces this),
  so `existingSecret` suppresses the chart's template and pruning leaves it alone.
- **StatefulSet shows a permanent, harmless OutOfSync** (pod never rolls). Two
  cosmetic causes under `ServerSideApply=true`: the chart's per-render
  `checksum/artifactory-unified-secret` pod annotation, and Kubernetes
  server-defaulted STS fields. Both are silenced via `ignoreDifferences` in the
  Application; see the comment there.
