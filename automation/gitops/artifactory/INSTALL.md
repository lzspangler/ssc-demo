# Fresh-cluster install runbook — Artifactory OSS (GitOps)

Step-by-step to install this Artifactory OSS instance (chart `artifactory-oss`
107.161.26) with the two Lightwell remote Maven proxies + the `lightwell` virtual
repo, on a brand-new OpenShift cluster. Run from this directory
(`automation/gitops/artifactory/`).

> The only true manual step is **creating three real secrets** (§3). Everything
> else is `oc apply`. Ordering matters — read §0 and follow the steps in order.

## 0. Prerequisites

- **`oc` logged in as cluster-admin.** Required: the custom SCC is cluster-scoped,
  and you create a cluster-scoped Argo CD Application.
- **OpenShift GitOps (Argo CD) installed** and the default `openshift-gitops`
  Argo CD instance running. Its application-controller has cluster-admin by
  default, which it needs to apply the SCC. Verify:
  ```sh
  oc -n openshift-gitops get pods | grep application-controller   # Running
  ```
- **A default StorageClass with RWO volumes.** The reference cluster uses
  `ocs-external-storagecluster-ceph-rbd`. The install provisions two PVCs
  (Artifactory 20Gi + the bundled PostgreSQL data volume). If you have no default
  SC, set `storageClassName` under `artifactory.artifactory.persistence` in
  `application-artifactory.yaml` first.
- **Egress to** `https://charts.jfrog.io` (chart pull) and
  `https://packages.redhat.com` (what the proxies fetch), plus the image registry
  the chart pulls from (`releases-docker.jfrog.io`).
- `openssl` available locally (for generating keys/passwords).

## 1. Namespace

```sh
oc create namespace artifactory --dry-run=client -o yaml | oc apply -f -
```

## 2. Apply the OpenShift extras (SCC, Route, repo-bootstrap ConfigMap, secret stubs)

```sh
oc apply -f openshift-extras.yaml
```

This creates: the custom SCC `artifactory-scc`, the edge Route `artifactory`, the
`artifactory-repo-bootstrap` ConfigMap, **and REPLACE_ME stubs** for the three
secrets. The stubs only document the shape — you overwrite them with real values
in the next step. (Do NOT re-apply this file later without care: it would clobber
the real secrets back to REPLACE_ME.)

## 3. Create the three real secrets  ← the manual step

Run these *after* §2 (so they overwrite the stubs) and *before* §4 (so pods never
start with placeholders). Keep the generated values somewhere safe — you cannot
recover the Postgres password after the DB initializes.

```sh
# a) Admin bootstrap credential. MUST be bootstrap.creds format: admin@*=<PASSWORD>
oc -n artifactory create secret generic artifactory-admin \
  --from-literal=password='admin@*=<CHOOSE-A-STRONG-PASSWORD>' \
  --dry-run=client -o yaml | oc apply -f -

# b) Mandatory master + join keys (must be hex)
oc -n artifactory create secret generic artifactory-keys \
  --from-literal=master-key="$(openssl rand -hex 32)" \
  --from-literal=join-key="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | oc apply -f -

# c) PINNED PostgreSQL credentials. CRITICAL: must exist before the first sync,
#    and must be a PLAIN secret (no Helm/Argo CD ownership) so the chart's
#    existingSecret pin suppresses its own secret template and Argo CD won't
#    regenerate it. `oc create secret` produces exactly that.
oc -n artifactory create secret generic artifactory-postgresql \
  --from-literal=postgres-password="$(openssl rand -hex 16)" \
  --from-literal=password="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | oc apply -f -
```

Verify none still say REPLACE_ME:

```sh
for s in artifactory-admin artifactory-keys artifactory-postgresql; do
  echo "== $s =="; oc -n artifactory get secret $s -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'
done
```

## 4. Deploy the Argo CD Application

```sh
oc apply -f application-artifactory.yaml
```

Argo CD (auto-sync) now renders the chart and creates the StatefulSets. First
boot: PostgreSQL initializes against the pinned secret, Artifactory connects, and
the bootstrap importer reads the ConfigMap-delivered
`artifactory.repository.config.import.json` to create the three repos.

## 5. Wait for readiness (~3–5 min)

```sh
oc -n artifactory get pods -w
# Expect eventually:
#   artifactory-0                8/8  Running
#   artifactory-postgresql-0     1/1  Running
#   artifactory-frontend-...     3/3  Running
#   artifactory-jfbus-...        3/3  Running

oc -n openshift-gitops get application artifactory \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
# Expect: sync=Synced health=Healthy
```

## 6. Verify

```sh
ROUTE="https://$(oc -n artifactory get route artifactory -o jsonpath='{.spec.host}')"
ADMIN=$(oc -n artifactory get secret artifactory-admin -o jsonpath='{.data.password}' \
        | base64 -d | sed 's/^admin@\*=//')

curl -sk "$ROUTE/artifactory/api/system/ping"; echo          # -> OK
curl -sk -u "admin:$ADMIN" "$ROUTE/artifactory/api/repositories" | \
  python3 -c 'import sys,json; [print("  {:22} {:8} {}".format(r["key"],r["type"],r.get("url",""))) for r in json.load(sys.stdin)]'
# -> lightwell-validated REMOTE ...validated/
#    lightwell-remediated REMOTE ...remediated/
#    lightwell            VIRTUAL <route>/artifactory/lightwell
```

- Web UI: open `$ROUTE`, log in as `admin` with the password from §3a.
- Point Maven at the virtual repo: `$ROUTE/artifactory/lightwell`.

## Troubleshooting

- **`topology` container crashloops with "password authentication failed for user
  artifactory"** — the `artifactory-postgresql` secret was missing/regenerated at
  first boot. On a *fresh* install just make sure §3c ran before §4. If the DB
  already initialized against a since-changed password, it's a destructive fix:
  delete both StatefulSets and both PVCs (`data-artifactory-postgresql-0`,
  `artifactory-volume-artifactory-0`), confirm the plain pinned secret exists,
  then re-sync — Postgres reinitializes and the repos re-bootstrap.
- **`topology` crashloops with "Corrupted MasterKey ... must be hex encoded"** —
  `artifactory-keys` still holds REPLACE_ME; redo §3b.
- **Pods stuck `Pending` / SCC errors** — confirm `oc get scc artifactory-scc`
  exists and lists the three service accounts, and that you applied §2 before §4.
- **StatefulSet shows `OutOfSync` but pods are healthy** — expected and harmless;
  it's suppressed by `ignoreDifferences` in the Application. See README.md.

## What each file provides

| File                          | Contents                                                        |
| ----------------------------- | --------------------------------------------------------------- |
| `openshift-extras.yaml`       | SCC, Route, repo-bootstrap ConfigMap, REPLACE_ME secret stubs   |
| `application-artifactory.yaml`| Argo CD Application (chart source, values, existingSecret pin, ignoreDifferences) |
| `README.md`                   | Design rationale (why bootstrap-import, why pin Postgres, etc.) |
