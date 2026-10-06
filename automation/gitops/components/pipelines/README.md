# pipelines

The OLM **Subscription** for Red Hat OpenShift Pipelines
(`openshift-pipelines-operator-rh`), plus an informational ConfigMap.

This chart installs the *operator* only. The demo's own Tasks, Pipelines and
Triggers are plain YAML at the repo root under `pipelines/`, synced by four
separate Applications — see *The Tekton layer* in
`automation/gitops/README.md`.

## Why it is wave 0

Everything Tekton in this platform depends on the CRDs this operator installs
(`pipelines.tekton.dev`, `tasks.tekton.dev`, `triggers.tekton.dev`), and
nothing depends on it, so it goes first and gets out of the way. The Tekton
resource Applications sit at waves 3–5 and retry until the CRDs land.

The operator also supplies the `cel` and `gitlab` **ClusterInterceptors** the
issue-comment EventListener calls, and it auto-creates the `pipeline`
ServiceAccount in every namespace — including `tssc-app-ci`, which the Tekton
Applications create with `CreateNamespace=true`.

```sh
oc get crd pipelines.tekton.dev
oc get clusterinterceptors        # expect at least: cel, gitlab
```

## Contents

| Template | Notes |
|---|---|
| `subscription.yaml` | the Subscription, into `openshift-operators` |
| `namespace.yaml` | the `lightwell-tasks` namespace, gated on the three flags below — renders nothing here |
| `userinfo.yaml` | `demo-userinfo-pipelines` ConfigMap — orientation text for workshop UIs, no runtime effect |

No OperatorGroup: `openshift-operators` ships with one, and a second in the
same namespace puts every operator in it into an error state.

## Two fixes worth knowing about

**The `lookup` guard on the Subscription was removed.** It read
`if not (lookup ... "Subscription" ...).metadata`, intending to skip itself
when a Subscription already existed. Under Argo CD that never fired — the repo
server renders with `helm template` and no cluster connection, so `lookup`
returns an empty dict. But anywhere it *did* fire, the Subscription would drop
out of the manifest set and `prune: true` would delete it, uninstalling the
operator along with its CRDs and every running pipeline. Re-applying an
identical Subscription is a no-op, so the guard protected nothing.

**`userinfo.yaml` referenced three values that did not exist.** It reads
`.Values.verifyBaseImage.enabled`, `.Values.conformaPolicy.enabled` and
`.Values.prefetchDependencies.enabled` unconditionally, and none were in
`values.yaml` — the chart failed to render at all with `nil pointer evaluating
interface {}.enabled`. Because this is wave 0, that failed the first
Application and blocked the entire install behind it. The three keys are now
present and `false`.

Their content, and most of `userInfo.instructions`, describes Lightwell
workshop tasks (`verify-base-image`, `conforma-policy`,
`prefetch-dependencies` in a `lightwell-tasks` namespace) that ssc-demo does
not ship. The text is left as-is rather than rewritten, since nothing reads
it; delete the ConfigMap with `userInfo.enabled: false` if it is just noise
on your cluster.

## Values

| Value | Notes |
|---|---|
| `operator.channel` | `latest` |
| `operator.source` | `redhat-operators` |
| `deployer.domain` / `apiUrl` | cosmetic, into the ConfigMap; set by `bootstrap-infra` |
| `userInfo.enabled` | set `false` to skip the ConfigMap entirely |
