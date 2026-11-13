# Automation Orchestrator (orchestration/)

Runs Red Hat's **Automation Orchestrator** (2026.8) on the demo cluster and
imports the **Remediate Next Gitlab** workflow — the human-in-the-loop front
door of the CVE remediation loop. The workflow lists the open CVE issues in
GitLab, has an LLM pick the next most important one, requires a human to
approve the choice, and posts a `/remediate` comment on the chosen issue —
which the GitLab issue-comment webhook translates into an
`agentic-cve-remediation` PipelineRun.

Nothing here is wired into the gitops app-of-apps; these files are applied
by hand (see the order below).

## Files

| File | What it is |
| ---- | ---------- |
| `00-automation-orchestrator-operator.yaml` | Namespace + OperatorGroup + Subscription for the `automation-orchestrator-operator` (Red Hat Operators catalog, `stable` channel, Manual install-plan approval) |
| `postgres-orch-backend.yaml` | BYO PostgreSQL 15 for the platform: PVC (5Gi, RBD), init ConfigMap, Deployment, Service |
| `backend-secret.yaml` / `temporal-secret.yaml` | Connection secrets the CR's `backendDatabase` / `temporalDatabase` refs point at |
| `automation-orchestrator.yaml` | The `AutomationOrchestrator` CR — deploys the actual platform |
| `remediate_next_gitlab.json` | Export of the "Remediate Next Gitlab" workflow, imported through the orchestrator's UI/API |
| `remediate_and_promote_gitlab.json` | Export of the "Remediate Test Promote Gitlab" workflow — the full remediation→test→promotion chain (see below) |
| `orchestrator-worker-k8s-access.yaml` | Long-lived service-account token Secret for the worker (the operator mounts no token in the worker pods and resets manual `automountServiceAccountToken` changes) |
| `orchestrator-tekton-rbac.yaml` | Roles + RoleBindings letting the workflow's script pods (SA `automationorchestrator-demo-worker`) drive PipelineRuns and read `scm-auth-secret` in `tssc-app-ci` |

## Apply order (cluster-b7zgr.dyn.redhatworkshops.io)

```bash
# 1. Operator (namespace + operatorgroup + subscription):
oc apply -f 00-automation-orchestrator-operator.yaml

# 2. Approve the InstallPlan (Manual on purpose -- the stable channel ships
#    continuous builds and would otherwise upgrade under a live demo):
oc -n automation-orchestrator-operator-system patch installplan \
  $(oc -n automation-orchestrator-operator-system get installplan -o name | cut -d/ -f2) \
  --type merge -p '{"spec":{"approved":true}}'

# 3. Wait for the operator to be ready:
oc -n automation-orchestrator-operator-system wait --for=condition=Succeeded \
  csv/automation-orchestrator-operator.v2026.8.1793830765 --timeout=600s

# 4. PostgreSQL + connection secrets (edit the placeholder passwords first --
#    they must match between the secret and postgres's POSTGRESQL_PASSWORD):
oc apply -f postgres-orch-backend.yaml -f backend-secret.yaml -f temporal-secret.yaml

# 5. Wait for postgres to be answering before the CR's migrations run:
oc -n automation-orchestrator-operator-system wait --for=condition=Available \
  deployment/postgres-backend --timeout=300s

# 6. The platform itself:
oc apply -f automation-orchestrator.yaml

# 7. Wait for it to come up:
oc -n automation-orchestrator-operator-system wait --for=condition=Ready \
  automationorchestrator/automationorchestrator-demo --timeout=900s
```

The UI is served on the Route the operator creates:

```bash
oc -n automation-orchestrator-operator-system get route
```

## Importing the workflow

`remediate_next_gitlab.json` is an *export* from another orchestrator
instance, so after importing it through the UI two node settings must be
re-pointed at THIS instance:

1. **Credentials** — both HTTP nodes (`GET Open Issues from Gitlab`,
   `Comment /remediate on selected Issue`) reference a GitLab credential by
   GUID, which is why their Authentication dropdown comes up empty on a
   fresh instance. Credentials are platform objects, not Kubernetes
   secrets: log into the UI (the Route from
   `oc -n automation-orchestrator-operator-system get route`, username
   `admin`, password in the `automationorchestrator-demo-initial-admin-password`
   Secret), open the **Credentials** page, and create one whose token can
   read issues and post notes on
   `development/spring-boot-example-application` (project ID 1) — then
   select it in both nodes. (The token value would be a copy of
   `scm-auth-secret`'s `token`; the remediate-and-promote workflow below
   deliberately avoids this by reading that secret directly instead.)
2. **LLM model** — the agentic node (`Select Next Gitlab Issue to
   Remediate`) references a model by GUID; pick one configured in this
   instance (the demo's AI backend works).

The workflow's GitLab URL already points at cluster-b7zgr and project 1
(verified to be `development/spring-boot-example-application` there).

## The "Remediate Test Promote Gitlab" workflow

`remediate_and_promote_gitlab.json` is the full promotion chain: a human
starts it with an issue number, and the workflow drives everything from the
`/remediate` comment through prod promotion:

1. **Manual trigger** — the runner inputs the issue number (iid).
2. **Build issue notes URL → comment `/remediate`** — same mechanism as the
   other workflow: the `agentic-issue-commands` EventListener picks the
   comment up and starts `agentic-cve-remediation` for the issue.
3. **Wait for remediation, merge and image build** — polls the Kubernetes
   API in-cluster for the issue's remediation run to succeed, then for the
   merge-triggered `ci-build-publish` run (the `ci-build-push`
   EventListener starts it when the remediation MR merges), and takes its
   `IMAGE_URL` / `CHAINS-GIT_COMMIT` / `CHAINS-GIT_URL` results as the new
   image.
4. **Run functional and integration test pipelines** — creates
   `test-image-functional` and `test-image-integration` PipelineRuns against
   the new image (same shape as the hand-run versions: pipeline SA, fresh
   2Gi workspace, `maven-settings`, tests pinned to the built commit,
   evidence comments on the issue). Both must succeed — the first failure
   fails the workflow and blocks promotion.
5. **Promote to prod** — creates a `gitops-cd-prod` PipelineRun with the new
   image and `auto-merge: "true"`, waits for it, and reports the promotion
   MR URL and merge status.

### Setup beyond the platform install

- **Enable script nodes (required — the run fails without this)** — the
  platform ships with script-node execution disabled by default. Every node
  of this workflow after the trigger is a script node, so the first run fails
  at "Build issue notes URL" with `ScriptNodeDisabled: Script node execution
  is not enabled.` (the scripts never execute; the worker refuses the
  activity before running anything). The switch is a platform setting
  (`script_nodes_enabled`, default `false`, Developer Preview) that is read
  from the worker's environment only — there is no CR field or UI toggle for
  it (the `AutomationOrchestrator` CRD has no env passthrough). Enable it on
  the worker deployment (script activities execute in the
  `automationorchestrator-demo-worker` pods):
  ```bash
  oc -n automation-orchestrator-operator-system set env \
    deployment/automationorchestrator-demo-worker APP_SCRIPT_NODES_ENABLED=true
  ```
  The rollout restarts the workers; the setting is cached per process, so the
  restart is what applies it. Manually added env entries survive the
  operator's reconcile (verified in practice), but fields the operator
  itself owns — like `automountServiceAccountToken` — are reset within
  seconds, which is why the token step below also uses an env entry. Security
  note from the setting's own docs: script nodes run arbitrary user code in
  the worker process without extra sandboxing, so this is fine for the demo
  cluster but explicitly "not recommended for production deployments".
- **Give the worker a Kubernetes token (required)** — getting credentials
  into workflow scripts is a three-way closed door, each verified on this
  cluster: the operator sets `automountServiceAccountToken: false` on the
  worker and **resets any manual flip within seconds** (patching to `true`
  looks like it works, then reverts); script subprocesses get only an
  **allowlisted environment** (locale/PATH vars — the platform's
  `SAFE_ENV_ALLOWLIST` — so env vars added to the worker deployment never
  reach the scripts); and script nodes have no `credential_id` (only
  `http_request` nodes do). What DOES survive the operator's reconcile is a
  manually added **volume/mount** (list fields merge by name/mountPath, like
  extra env entries do). So the token comes from a Secret mounted into the
  worker:
  ```bash
  # 1. long-lived token Secret for the worker SA (the cluster's token
  #    controller fills in token/ca.crt; it does not expire):
  oc apply -f orchestrator-worker-k8s-access.yaml

  # 2. mount it into the worker (run ONCE -- the JSON patch appends, so a
  #    second run would duplicate the entries):
  oc -n automation-orchestrator-operator-system patch deployment \
    automationorchestrator-demo-worker --type json -p '[
    {"op":"add","path":"/spec/template/spec/volumes/-",
     "value":{"name":"ao-k8s-access","secret":
       {"secretName":"orchestrator-worker-k8s-access"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-",
     "value":{"name":"ao-k8s-access","mountPath":"/var/run/ao-k8s",
              "readOnly":true}}]'

  # 3. verify it survived the next reconcile (~1 min):
  oc -n automation-orchestrator-operator-system get deployment \
    automationorchestrator-demo-worker -o yaml | grep -A2 ao-k8s-access
  ```
  The workflow scripts read `/var/run/ao-k8s/token` and
  `/var/run/ao-k8s/ca.crt` (falling back to the projected token paths for
  deployments that do mount them); without the mount the "Comment
  /remediate" node dies with the guard message `found no service-account
  token/CA`. It is the same SA the RBAC below scopes, so the credential can
  only create/read PipelineRuns and read one named secret in `tssc-app-ci`.
  Note the mounted files are readable by anything in the worker container —
  on a multi-tenant orchestrator that would expose the token to every
  workflow author; fine here, where the platform has a single author.
- **No platform credential needed** — the `/remediate` comment node is a
  script that reads the GitLab token from the `scm-auth-secret` Secret in
  `tssc-app-ci` (the same single source of truth the pipelines use) through
  the Kubernetes API and posts with a `PRIVATE-TOKEN` header. Nothing to
  copy, nothing to rotate in two places.
- **RBAC** — the script nodes talk to `https://kubernetes.default.svc` with
  their pod's service account. Workflow activities execute in the
  `automationorchestrator-demo-worker` pods (they poll the
  `orchestrator-workflow-queue` Temporal task queue; the background-worker
  handles only internal scheduled jobs), so
  `orchestrator-tekton-rbac.yaml` binds that SA and grants exactly:
  `pipelineruns get/list/watch/create` in `tssc-app-ci`, plus `get` on the
  single named secret `scm-auth-secret` (for the comment node — no list, no
  other secrets, no other verbs). Apply it before running the workflow.
  Verify from the cluster:
  ```bash
  oc -n tssc-app-ci auth can-i get secret/scm-auth-secret \
    --as=system:serviceaccount:automation-orchestrator-operator-system:automationorchestrator-demo-worker
  ```
- **Trigger parameter wiring** (verified against the platform): manual
  trigger inputs are declared as a JSON Schema under
  `parameters.input_schema` (the only key `parameters` accepts) and
  referenced downstream as `${trigger.<property>}` — the workflow uses
  `${trigger.issue_iid}`. Two things the publish verifier taught us the
  hard way: every `${...}` sequence anywhere in a script — including in
  *comments* — is resolved and must name an existing node, trigger, or
  property; and references must point at upstream steps only. The first
  script still carries an `isdigit()`-guarded `FALLBACK_ISSUE_IID`
  constant: if the engine ever leaves the trigger expression unsubstituted
  in a script body at runtime, the run uses the constant instead of
  failing.

### Assumptions worth knowing

- **Build↔issue correlation**: the workflow takes the first
  `ci-build-publish` run that succeeds *after* the issue's remediation run
  finished as the image to test. With one issue in flight (how the demo
  runs) that is exactly the merge-triggered build of that issue's MR; with
  several issues merging concurrently, correlating a build to a specific
  issue would need GitLab API access from the polling script (which has no
  credential injection) — the workflow would need an extra authenticated
  node if that ever matters.
- **In-cluster script execution**: the design assumes workflow script pods
  run on this cluster and can reach `kubernetes.default.svc` with a
  projected SA token. If the orchestrator executes scripts elsewhere, move
  the pipeline-starting steps to `http_request` nodes with an API-token
  credential against `https://api.cluster-b7zgr.dyn.redhatworkshops.io:6443`.
- **Timeouts** (constants at the top of each script): remediation+merge 4 h
  (a human merges the MR), build 60 min, tests 90 min, prod promotion 30 min.
- The `agentic` LLM node is deliberately absent — no LLM decisions in this
  chain; the human at the trigger is the judgment.

## Notes

- The CR deliberately omits `spec.imagePullSecrets` (registry.redhat.io
  pulls are covered by the cluster's global pull secret; a dangling ref
  would break pod creation) and `spec.secrets` (the operator auto-generates
  the admin password and encryption key when refs are omitted).
- `secrets examples ship with placeholder passwords` — replace
  `secure-password` in `backend-secret.yaml`, `temporal-secret.yaml` and
  `postgres-orch-backend.yaml` (it appears in the init SQL, the Deployment
  env, and both secrets) before applying for real. Never commit real values.
- Cleanup, if you ever want the whole thing gone: delete the Subscription +
  CR first, then the namespace (deleting the namespace alone leaves the
  ClusterServiceVersion orphaned in it):
  ```bash
  oc -n automation-orchestrator-operator-system delete subscription automation-orchestrator-operator
  oc -n automation-orchestrator-operator-system delete automationorchestrator automationorchestrator-demo
  oc delete namespace automation-orchestrator-operator-system
  ```
