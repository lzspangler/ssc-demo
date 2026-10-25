# OpenShift Data Foundation

Optional. Installs ODF in internal mode so the cluster can serve
`ObjectBucketClaim`s, which is the one thing ssc-demo actually needs from it.

**Enable it only when `oc get storagecluster -A` is empty.** Most Red Hat
workshop clusters — including the reference cluster, `cluster-6jnws` — already
have ODF, and a second StorageCluster is not something you back out of cleanly.
That is why `components.odf.enabled` defaults to `false`.

## What depends on it

| Consumer | How |
|---|---|
| RHTPA (`components.rhtpa.storage.type: s3`) | `tpa-prerequisites` raises an `ObjectBucketClaim` against `openshift-storage.noobaa.io` |
| Quay (`components.quay.objectStorageManaged: true`) | the Quay operator raises its own, from the managed `objectstorage` component |

Both have fallbacks — filesystem RHTPA, Quay off — described under *Storage* in
`../../README.md`. S3 is the path the reference cluster uses and the one to
prefer; the filesystem fallback mounts one RWO PVC into two Deployments and
only works when they co-schedule.

Note that **only the Multicloud Object Gateway matters here**. Ceph RBD and
CephFS come along with it and nothing in the demo consumes them.

## Shape

```
odf/
  odf-operator/        Namespace + OperatorGroup + Subscription
  odf-storagecluster/  RBAC, node labelling, the StorageCluster, readiness gate
```

Four things are worth knowing before editing either subchart.

**The channel must match the cluster's OpenShift minor.** ODF is only supported
on the matching release and OLM will not resolve `stable-4.20` on a 4.21
cluster. Check, don't assume:

```sh
oc -n openshift-marketplace get packagemanifest odf-operator \
  -o jsonpath='{.status.defaultChannel}{"\n"}'
```

**ODF ships its own OperatorGroup where the Quay component deliberately does
not.** Its CSV supports only `OwnNamespace` and `SingleNamespace`, so an
AllNamespaces install into `openshift-operators` is rejected outright —
`openshift-storage` is a fresh namespace with no OperatorGroup of its own, and
one has to exist. `odf-operator` is a meta-package: OLM resolves it into
`ocs-operator`, `mcg-operator`, `rook-ceph-operator`, `cephcsi-operator` and
several more. Subscribe to the pieces individually and you get a version skew.

**The node labelling Job is not optional scaffolding.** ODF places OSDs only on
nodes carrying `cluster.ocs.openshift.io/openshift-storage`. The web console
applies that label for you; a CR applied by GitOps has nobody to do it, and the
failure is silent — the StorageCluster sits in `Progressing` with OSD pods
`Pending` and no event saying "no labelled nodes". The Job prefers nodes that
are workers and *not* control-plane, so a cluster with dedicated workers keeps
Ceph off the masters, and falls back to master-workers on a compact cluster.
Pin exact nodes with `nodeLabeller.nodes` if you would rather choose.

**The readiness gate is what makes the sync wave mean anything.** Argo CD has
no health check for `StorageCluster`, so without the PostSync hook the
Application reports Healthy the moment the CR is accepted — and wave 10 starts
building Quay and RHTPA against a Ceph with no OSDs. The hook polls three
separate conditions, because each lags the others and only the third is what
the consumers need:

1. `StorageCluster` phase `Ready`
2. `NooBaa` phase `Ready`
3. the `openshift-storage.noobaa.io` StorageClass exists

Both Jobs are pure-stdlib Python against the in-cluster API on
`ubi9/python-39` — no `oc` in the image, and no `microdnf install` at runtime,
which under the restricted SCC's arbitrary UID always fails.

## Expect one transient error

On a first install the StorageCluster goes to `Error` within the first minute:

```
ReconcileFailed: Error while reconciling: no rook-ceph-operator CSV found in Succeeded phase
```

That is ordering, not a fault. `ocs-operator` reconciles before OLM has
finished installing its sibling CSVs, and it clears on the next reconcile once
`rook-ceph-operator` reports `Succeeded`. Do not delete and recreate the CR —
wait. Total time to `Ready` is 15–25 minutes on three fresh cloud volumes.

## Installing without Argo CD

The Application applies everything at once and relies on retries to survive the
CRD not existing yet. By hand you have to stage it, because `oc apply` of a
`StorageCluster` fails outright when `storageclusters.ocs.openshift.io` has not
been created:

```sh
cd automation/gitops/components/odf
helm dependency build
helm template odf . > /tmp/odf.yaml

# 1. operator (sync-wave -5)
python3 -c "import yaml,sys;yaml.safe_dump_all([d for d in yaml.safe_load_all(open('/tmp/odf.yaml')) if d and (d['metadata'].get('annotations') or {}).get('argocd.argoproj.io/sync-wave')=='-5'],sys.stdout)" | oc apply -f -

oc get crd storageclusters.ocs.openshift.io   # wait for this

# 2. RBAC + node labelling (-4, -3), then 3. the StorageCluster (-2)
```

`helm dependency build` writes `charts/*.tgz`, which is **not** committed —
Argo CD builds local `file://` dependencies itself. Delete the directory when
you are done so it does not show up as untracked, the same as the `quay`
umbrella chart.

## Verifying

```sh
oc -n openshift-storage get storagecluster      # PHASE Ready
oc -n openshift-storage get noobaa              # PHASE Ready
oc get storageclass | grep noobaa               # openshift-storage.noobaa.io
oc -n openshift-storage get pods | grep osd     # 3 Running
```

## Tearing it down

Removing ODF is genuinely destructive — every PVC on a Ceph class goes with it.
Delete the consumers first (RHTPA's `ObjectBucketClaim`, Quay's registry), then
the StorageCluster, and only then the Subscription and CSVs. The namespace will
not terminate while `cephcluster` finalizers remain.
