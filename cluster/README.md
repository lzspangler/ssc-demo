# SSC Demo Cluster Preparation

`ssc-demo` assumes a functioning OpenShift GitOps installation and does not install the platform operators through its application app-of-apps. This directory contains cluster-side preparation utilities only; it does not modify the `ssc-demo` checkout.

## Current Target

- OpenShift 4.20.x.
- Three or more Ready worker nodes.
- ODF StorageCluster Ready with Ceph health `HEALTH_OK`.
- NooBaa Ready for RHTPA/Quay object storage claims.
- `ocs-storagecluster-cephfs` as the default filesystem StorageClass.
- `ocs-storagecluster-ceph-rbd` available for databases where explicitly requested.
- Required operator packages available from `redhat-operators`.

## Usage

Run after cluster login:

```bash
bash cluster/ssc-demo-cluster.sh --preflight
```

Cluster-specific checks and resource names are overrideable without editing the
script. For example:

```bash
SSC_DOMAIN="apps.example.com" \
SSC_EXPECTED_OCP_VERSION="4.21." \
SSC_MIN_READY_WORKERS=4 \
SSC_CEPH_STORAGE_CLASS="ocs-external-storagecluster-cephfs" \
  bash cluster/ssc-demo-cluster.sh --preflight
```

The preflight is read-only. The following actions mutate only cluster resources:

```bash
bash cluster/ssc-demo-cluster.sh --ensure-storage
bash cluster/ssc-demo-cluster.sh --bootstrap-gitops
bash cluster/ssc-demo-cluster.sh --bootstrap-platform-argocd
bash cluster/ssc-demo-cluster.sh --bootstrap-pipelines
bash cluster/ssc-demo-cluster.sh --ensure-platform-argocd-admin
bash cluster/ssc-demo-cluster.sh --ensure-keycloak-route
bash cluster/ssc-demo-cluster.sh --ensure-rhtpa-router-ca
bash cluster/ssc-demo-cluster.sh --ensure-rhtpa-server-ca
bash cluster/ssc-demo-cluster.sh --ensure-rhtpa-hook-tls
bash cluster/ssc-demo-cluster.sh --ensure-quay-noobaa-rbac
```

The bootstrap actions are deliberately separate so operator installation can be verified before the SSC app-of-apps is rendered. They read existing manifests from `ssc-demo`; they do not edit or commit that repository.

Platform ArgoCD bootstrap creates only the `platform-gitops` namespace, RBAC, and ArgoCD instance. It intentionally does not apply the SSC component Applications; that remains the later app-of-apps deployment step.

The Quay hook in the current SSC chart reads ODF `NooBaa` and `BackingStore` resources from `openshift-storage`, and patches the default `BackingStore` resource request. `--ensure-quay-noobaa-rbac` applies the minimal cross-namespace Role/RoleBinding needed for those operations; it grants only `get/list/watch` on `NooBaa`, and `get/list/watch/patch` on `BackingStore`, with no bucket or create/delete permissions.

The SSC app-of-apps contains broad RoleBindings that the checked-in platform Argo ClusterRole cannot reconcile. `--ensure-platform-argocd-admin` grants `cluster-admin` only to the platform Argo application controller for this isolated demo cluster. This is a development-cluster workaround and must be replaced by a least-privilege role before production use.

The Keycloak CR advertises `sso.<apps-domain>`, while the chart's generated Route uses `keycloak-keycloak.<apps-domain>`. `--ensure-keycloak-route` creates the expected `sso` edge-terminated alias for RHTPA/RHTAS OIDC callbacks.

The durable fork-side fix is to set `oidc.caConfigMap: ssc-router-ca` in the RHTPA prerequisite values. `--ensure-rhtpa-router-ca` creates that ConfigMap from the cluster ingress CA; the forked hook mounts it and uses `curl --cacert`.

The RHTPA server also calls the OIDC issuer. `--ensure-rhtpa-server-ca` creates the combined router/service CA bundle, mounts it into the server, sets `SSL_CERT_FILE`, adds an Argo ignore rule for the intentional deployment override, and uses `maxSurge: 0`/`maxUnavailable: 1` so the six-node development cluster can roll the server under CPU pressure.

## AI Endpoint Status

The live demo uses the ENMAAS OpenAI-compatible endpoint:

- Base URL: `https://api.enmaas.devshift.net/v1`
- Model: `rits/zai-org/glm-5-3`
- Provider: `openai`
- TLS verification: enabled
- Secret: `tssc-app-ci/ai-agent-secret`, key `OPENAI_API_KEY`

The key was sourced from the local `ENMAAS_API_KEY` environment variable and was not printed. The live `ai-agent-config` ConfigMap has an Argo ignore rule for its `data` field so this local development override is not immediately reverted by the current remote `ssc-demo` branch. The endpoint was verified with an authenticated `/v1/models` request returning HTTP 200.

A one-shot pod in `tssc-app-ci` verified the same Secret and endpoint from inside the cluster: HTTP 200 and model ID `rits/zai-org/glm-5-3`. The pod was deleted after the check.

The same in-cluster check verified Artifactory `200` and RHTPA readiness `200`. GitLab seeding completed, all required Tekton secrets exist, and both `agentic-test-generation` and `agentic-cve-analysis` Pipelines are installed.

## First Test-Generation Baseline

PipelineRun `agentic-test-generation-jqt8q` completed successfully:

- Clone: approximately 13 seconds.
- Maven package: approximately 58 seconds.
- AI generation: approximately 32 minutes 34 seconds.
- Maven verification: approximately 61 seconds.
- Publication task: approximately 9 seconds.
- Generated tests: `1`.
- Result: one `GlobalExceptionHandlerTest.java` added and verified.

The original publication task pushed the branch but did not create an MR because it masked all `glab mr create` errors and returned an empty `PR_URL`. A local fork change now uses the GitLab v4 API with visible failure handling. The existing branch was manually validated through the API and MR `1` was created.

The first speed investigation should focus on the AI stage: the baseline used `AI_EFFORT=high`, broad repository context, and generic coverage-oriented prompting. The live follow-up profile now uses `AI_EFFORT=medium`; clone, Maven, and publication are not currently the dominant cost.

The temporary OpenAI Enterprise profile uses the provider-qualified LiteLLM model name `openai/gpt-5.6-luna`, corresponding to endpoint model ID `gpt-5.6-luna`. The Enterprise `/v1/models` endpoint advertises both `gpt-5.6-luna` and `gpt-6-luna`.

The first GPT-5.6-Luna run (`agentic-test-generation-mpj7d`) completed successfully in approximately 5m48s: clone 18s, Maven package 60s, AI generation 3m21s, verification 60s, and publication 9s. It generated four Java unit-test files (412 lines), all verification passed, and MR `2` was created through the GitLab API because the remote task still used the old `glab` implementation.

`--ensure-rhtpa-hook-tls` remains a temporary live override using `curl -k` when testing before the forked chart is rendered. It is intentionally development-only; remove the ignore rule after the CA-aware chart is deployed.

Pipelines bootstrap creates `openshift-pipelines` before applying the chart and disables the chart's Tekton Chains bootstrap. Chains depends on the SSC RHTAS/Rekor deployment and is intentionally deferred to the app-of-apps.

The GitOps bootstrap clears the stale `startingCSV` in the demo's subscription manifest after applying it. The checked-in manifest requests `openshift-gitops-operator.v1.20.4`, which is not present in the current 4.20 `gitops-1.21` catalog; the catalog currently resolves `v1.21.6`.

## SSC Installation Boundary

After GitOps and Pipelines are healthy, `ssc-demo` remains responsible for rendering its own application stack, credentials, and Tekton resources. The cluster preparation utility does not create those resources or credentials.

The next deployment step must use an uncommitted SSC values override containing the cluster apps domain and generated credentials. Do not commit that file. The SSC runbook's active ODF values must be overridden for this cluster's `stable-4.20` storage setup if the app-of-apps enables ODF; the cluster already has ODF, so the app-of-apps ODF component should remain disabled unless its duplicate-StorageCluster behavior is explicitly confirmed.

## Decisions Recorded

- HPP is not used as the default storage for this target; auto-toolbox provisioned ODF on three local block devices.
- CephFS is the default general-purpose filesystem class; Ceph RBD is available for explicit database claims.
- No changes are made to `ssc-demo` by these utilities.
- The VPE-to-Test-Generation MVP can be developed after the platform baseline is healthy; SCM/PR integration remains conditional on what the demo flow requires.

## Cluster Preparation Status

Applied on Oct 30, 2026 after the auto-toolbox redeployment:

- OpenShift `4.20.12`, three Ready workers, all cluster operators healthy.
- ODF `4.20.21` StorageCluster Ready, Ceph `HEALTH_OK`, NooBaa Ready.
- Three `100Gi` local block PVs bound to the ODF device set.
- `ocs-storagecluster-cephfs` default filesystem class and `ocs-storagecluster-ceph-rbd` available.
- OpenShift GitOps operator `v1.21.6` installed after clearing the stale `v1.20.4` starting-CSV pin from the existing bootstrap manifest at the live subscription.
- OpenShift Pipelines operator `v1.24.2` installed; Tekton CRDs are available.
- `platform-gitops` ArgoCD instance and RBAC installed and Available.
- No SSC component Applications, application credentials, or `ssc-demo` repository files were applied or changed.

The remaining deployment step is the SSC app-of-apps: prepare an uncommitted values override, verify its credentials and domain, then apply it through the `platform-gitops` ArgoCD instance. The cluster-preparation script intentionally stops before that step.

## SSC Deployment Status

Deployment was started on Nov 2, 2026 using the existing `ssc-demo` manifests and a private `/tmp/ssc-demo-values.yaml` override. The fork now has local, uncommitted RHTPA hook changes for this cluster; nothing has been committed or pushed.

Healthy applications:

- GitLab
- Keycloak
- Quay
- RHTAS
- RHTPA operator
- OpenShift Pipelines/Tekton resources

Current status:

- The RHTPA hook now succeeds when the forked chart is rendered with `oidc.caConfigMap=ssc-router-ca`.
- The trusted-profile-analyzer OBC is `Bound` after removing an accidental duplicate `default/trustify` claim created during earlier local rendering.
- RHTPA PostgreSQL, server, and importer resources are now starting; allow the operator to finish reconciliation.

Development-cluster compatibility adjustments applied:

- SSC Applications are managed in `platform-gitops` because the prepared Argo instance owns that namespace; the initial `openshift-gitops` Application objects were removed.
- The platform Argo application controller has a demo-only `cluster-admin` binding because the checked-in platform ClusterRole cannot reconcile the SSC chart's broad RoleBindings.
- The Quay NooBaa preflight hook is disabled in the live Application because auto-toolbox ODF uses an RGW-backed S3-compatible `BackingStore`, while the hook assumes a PVC-backed `pvPool` and attempts an invalid patch. Quay itself is healthy using managed object storage.
- An `sso.<apps-domain>` Keycloak Route alias exists. The cluster DNS resolves it; local workstation `/etc/hosts` mapping requires interactive sudo if local browser/curl access is needed.
- `ssc-router-ca` in `trusted-profile-analyzer` contains the ingress CA used by the forked hook.

Local fork changes, not yet committed or pushed:

- `automation/gitops/components/rhtpa/tpa-prerequisites/values.yaml` adds `oidc.caConfigMap`.
- `automation/gitops/components/rhtpa/tpa-prerequisites/templates/wait-for-keycloak.yaml` mounts the ConfigMap and uses `curl --cacert` when configured.

The durable next step is to commit/push that fork change only after the RHTPA deployment and full SSC smoke path are verified.

## Demo Actions

The GitLab UI login is `root`; use the `gitlabRootPassword` value saved in `/tmp/ssc-demo-values.yaml`. Tekton uses the generated project token in `scm-auth-secret`, not the root password.

Use the external action helper for a first look at the current state:

```bash
bash cluster/ssc-demo-actions.sh status
bash cluster/ssc-demo-actions.sh gitlab-info
```

The existing runbook's normal action sequence is:

1. Wait for the GitLab seeding Job and confirm `development/spring-boot-example-application` exists.
2. Ensure `ai-agent-secret` and `maven-settings` exist in `tssc-app-ci`; they are currently still outstanding because the RHTPA prerequisite/app setup is incomplete.
3. Run `agentic-cve-analysis` with a per-run workspace PVC and Maven settings.
4. Confirm the scan creates a GitLab CVE issue and the RHTPA/Quay outputs are available.
5. Comment `/remediate` to exercise the existing remediation flow or `/generate-tests` to exercise the current limited generator.

For a manual test-generation PipelineRun after its secrets are ready:

```bash
REPO_URL="https://gitlab-gitlab.${DOMAIN}/development/spring-boot-example-application.git" \
  bash cluster/ssc-demo-actions.sh start-test-generation
```

Set `REVISION`, `BASE_BRANCH`, `SUBDIRECTORY`, `AGENT_IMAGE`, and `VERIFY_COMMIT` as needed. The helper preserves the current demo-compatible pipeline, including `TESTS_ADDED` and optional PR output; it is not the conformant VPE-to-Test-Generation MVP flow.
