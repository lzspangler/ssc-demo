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
| `chains-job.yaml` / `chains-rbac.yaml` | post-install Job: generates the cosign keypair into `signing-secrets` (if still empty) and merge-patches `TektonConfig .spec.chain` for image signing + SLSA provenance |
| `platform-config-job.yaml` | post-install Job: merge-patches operator-owned cluster CRs the demo needs — see below |
| `cluster-defaults-job.yaml` | post-install Job: rewrites the Tekton layer's cluster-specific param defaults (`image-registry`, `gitops-url`, `git-host`) from `deployer.domain` — see below |

No OperatorGroup: `openshift-operators` ships with one, and a second in the
same namespace puts every operator in it into an error state.

## Post-install platform defaults (`platform-config-job.yaml`)

Two settings the demo needs that no operator sets on its own, applied by an
idempotent Job (runs on every Argo sync, waits for the operator's TektonConfig
to appear, merge-patches only the fields it owns — Argo cannot own these CRs
wholesale without fighting the operators that curate them):

1. **`TektonConfig .spec.pipeline.default-timeout-minutes: 180`** — Tekton's
   default PipelineRun timeout. The API server materializes it into
   `spec.timeouts.pipeline` of every run created *without* an explicit one —
   trigger- and CLI-created runs. Two caveats verified with server-side
   dry-runs: the **web console submits an explicit `1h0m0s`** on every run it
   starts, so console-started agentic runs keep the 1h wall regardless of
   this default (start long runs via their trigger or `oc` instead); and the
   admission defaulting **overwrites the legacy `spec.timeout` field**, so a
   pin must use `spec.timeouts.pipeline`. The stock 60m times out
   `agentic-cve-analysis`: ~40 min of upstream RHTPA tasks (the remediation
   report grows with the advisory corpus) plus ~45–90 min of model-gated
   analysis. Runs that pin `spec.timeouts.pipeline` are unaffected.
2. **`console.operator/cluster .spec.plugins += pipelines-console-plugin`** —
   on OCP 4.15+ the web console only shows the Pipelines nav when the plugin
   is listed there; installing the operator alone never adds it.

Both are gated from `values.yaml` (`platformDefaults.defaultTimeoutMinutes`,
`platformDefaults.consolePlugin.enabled`).

## Cluster-specific Tekton defaults (`cluster-defaults-job.yaml`)

The Tekton layer at the repo root is synced as plain YAML, so its
cluster-specific param defaults are committed with the reference cluster's
hostnames and go stale on every cluster move — most recently
`ci-build-publish-5rxcw`, where `buildah push` timed out against the previous
cluster's dead Quay and read as a credential problem. The Job rewrites those
defaults on the live objects from `deployer.domain` on every sync:

| Object | Param | Becomes |
|---|---|---|
| `TriggerTemplate/ci-build-push-template` | `image-registry` | `quay.apps.<domain>` |
| `Pipeline/gitops-cd-{dev,qa,prod}` | `git-host` | `gitlab-gitlab.apps.<domain>` |
| `Pipeline/gitops-cd-{dev,qa,prod}` | `gitops-url` | same URL with the host swapped |

`gitops-url` keeps its group/repo path from the committed value — only the
host is swapped, so the repo stays authoritative for everything but the
domain. The Job waits for the Tekton-layer Applications (root-app waves 3–5)
to produce the objects, then merge-patches the full `spec.params` array (a
merge-patch replaces arrays wholesale). Patching is generic — any
Pipeline/TriggerTemplate in the namespace carrying one of those params gets
fixed — but the four expected targets must exist, or the Job fails rather
than silently skipping a rename.

`bootstrap-infra` also adds `ignoreDifferences` for exactly these fields to
the `ssc-tekton-pipelines` / `ssc-tekton-triggers` Applications, so Argo's
`selfHeal` does not revert the patch. The consequence: **repo-side edits to
those defaults no longer reach a gitops-installed cluster** — change
`deployer.domain`, or edit the files and the ignore lists together.

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
| `chains.enabled` | the signing bootstrap Job + RBAC |
| `chains.jobImage` | the stdlib-Python image both bootstrap Jobs run on |
| `platformDefaults.defaultTimeoutMinutes` | TektonConfig default PipelineRun timeout (180; 0 = leave the operator default) |
| `platformDefaults.consolePlugin.enabled` | patch the Pipelines nav plugin into `console.operator/cluster` |
| `clusterDefaults.enabled` | the cluster-defaults patch Job (turned on by `bootstrap-infra`; off in a standalone render) |
| `clusterDefaults.timeoutSeconds` | how long that Job waits for the Tekton layer to appear (1800) |
| `pipelineNamespace` | where the Tekton layer lives and the Job patches; set by `bootstrap-infra` |
