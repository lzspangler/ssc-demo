# AI vulnerability remediation

This repo defines **eleven** pipelines under `pipelines/` that share the same
tasks and images. Each has a single, distinct responsibility and can be run on
its own:

1. **`agentic-cve-analysis`** — *decide what to fix (all) → issues.* Build →
   SBOM → RHTPA scan → must-fix chain, then asks the AI for a decision **per
   fixable CVE** and opens **one GitLab/GitHub issue per vulnerability**. Each
   issue carries the same six fields so commenting `/remediate` on it starts
   `agentic-cve-remediation`.
2. **`agentic-test-generation-unit`** — *raise unit-test coverage.* Runs just
   the AI **test-generation** flow (clone → build → generate unit tests →
   `mvn test` → tests-only PR/MR). No image build, SBOM/scan, or CVE
   remediation. Triggered with `/generate-tests-unit`.
3. **`agentic-test-generation-functional`** — same flow, but the agent
   generates **functional tests** (`*FT.java`, per the
   `test-generation-functional` skill: black-box REST Assured against the
   application deployed as **ephemeral namespaced resources** in the pipeline
   namespace). Triggered with `/generate-tests-functional`.
4. **`agentic-test-generation-integration`** — same flow, but the agent
   generates **integration tests** (`*IT.java`, per the
   `test-generation-integration` skill: test-managed embedded H2/WireMock
   doubles, no Testcontainers) and the MR also carries any test-scoped
   `pom.xml` additions. Triggered with `/generate-tests-integration`.
5. **`agentic-cve-remediation`** — *apply a fix.* Takes a CVE decision **as
   params**, has the AI bump the vulnerable Maven dependency to its fixed
   version, re-runs `mvn package` (unit tests only), and opens a **PR/MR**.
   Does no discovery or scanning of its own.
6. **`ci-build-publish`** — *continuous integration for the application
   repository.* Every merge to the default branch builds the source, builds
   and publishes the container image to the in-cluster Quay, attaches its
   SBOM, and uploads that SBOM to RHTPA. A `finally` task then starts
   `gitops-cd-dev` to promote the fresh image tag into dev.
7. **`gitops-cd-dev`** — *dev image promotion.* Opens and auto-merges an MR
   bumping `image.tag` in the gitops repo's dev values file. Started
   automatically by `ci-build-publish`.
8. **`gitops-cd-prod`** — *prod image promotion (human-gated).* Same promotion
   into the prod values file; started by a human, the MR stays open for review.
9. **`gitops-cd-qa`** — *qa image promotion (human-gated).* Same promotion
   into the qa values file; started by a human, the MR stays open for review.
10. **`test-image-functional`** — *image-level functional test evidence.* Deploys
    a published container image into a **per-run ephemeral namespace**, runs the
    project's functional suite (`*FT.java`) against it, comments a test-summary
    on the given GitLab/GitHub issue on success, and deletes the namespace
    (win or lose).
11. **`test-image-integration`** — same shape for the integration suite
    (`*IT.java`/`*IntegrationTest.java`, in-JVM doubles); the deployment acts
    as a boot smoke-gate on the image rather than the test target.

The CVE pipelines share one six-field decision contract
(`SELECTED`/`CVE_ID`/`PACKAGE`/`CURRENT_VERSION`/`FIXED_VERSION`/`JUSTIFICATION`):
`agentic-cve-analysis` embeds it in each issue it opens so the
[`/remediate` trigger](#triggering-pipelines-from-a-gitlab-issue-comment) can feed it to
`agentic-cve-remediation` automatically. See the [Overview](#overview) for
per-step detail.

## Overview

This repo defines **eleven** pipelines that share the same tasks and images:

- **`pipelines/agentic-cve-analysis.yaml`** — self-contained CVE discovery,
  prioritization, and fan-out (build → SBOM → RHTPA scan → must-fix gate → AI
  decision per fixable CVE → one issue per vulnerability, each carrying the
  six-field decision). Changes nothing in the repo beyond creating issues.
- **`pipelines/agentic-test-generation-unit.yaml`** — a standalone AI
  **test-generation** flow (clone → build → generate unit tests → `mvn test` →
  tests-only PR/MR). No image build, SBOM/scan, or CVE remediation.
- **`pipelines/agentic-test-generation-functional.yaml`** — the same flow
  generating functional tests (`*FT.java`, black-box REST Assured). The
  pipeline deploys the application under test as **ephemeral namespaced
  resources** (image from the packaged jar → integrated registry → Deployment
  + Service, health-gated) in `tssc-app-ci`, the generation task drives that
  Deployment (state reset before every verification run, server-log tail in
  failure feedback), and a `finally` task removes the resources whether the
  run succeeded or failed.
- **`pipelines/agentic-test-generation-integration.yaml`** — the same flow
  generating integration tests (`*IT.java`, embedded/WireMock doubles only);
  re-runs direct failsafe invocation of the integration suite (scoped
  `-Dit.test=*IT,*IntegrationTest`); the MR stages `pom.xml` test-scoped
  additions alongside `src/test`.
- **`pipelines/agentic-cve-remediation.yaml`** — applies a decision (passed in as
  params) to the git project: clone → AI bump the dependency → `mvn package`
  (unit tests only) → PR/MR. The remediation tail runs only when `SELECTED="1"`.
- **`pipelines/ci-build-publish.yaml`** — continuous integration for the
  application repository: clone → `mvn package` (unit tests only) → buildah
  build + push to the in-cluster Quay → SBOM attach + upload to RHTPA. The
  `finally` tasks print the SBOM and a summary and start `gitops-cd-dev` after
  a successful build. Deliberately nothing else downstream of the SBOM — no
  vulnerability analysis, no Conforma gate, no AI, no issues; those belong to
  the agentic pipelines, which run on their own cadence against the same
  image. CI stays fast and either produces a published image or fails.
- **`pipelines/gitops-cd-dev.yaml`** — dev GitOps CD: promote the image
  `ci-build-publish` just published into the gitops repo's dev values file
  (MR + auto-merge).
- **`pipelines/gitops-cd-prod.yaml`** — prod GitOps CD: same promotion, into
  the prod values file, started by a human; the MR stays open for review
  (`auto-merge="false"`).
- **`pipelines/gitops-cd-qa.yaml`** — qa GitOps CD: same promotion, into the qa
  values file, started by a human; the MR stays open for review
  (`auto-merge="false"`).
- **`pipelines/test-image-functional.yaml`** — image-level functional test
  evidence: deploy a published image into a per-run ephemeral namespace
  (health-gated), run the `*FT.java` suite against it, post a test-summary
  comment on the given issue on success; the namespace is deleted in `finally`
  whether the run passed or failed.
- **`pipelines/test-image-integration.yaml`** — same flow for the `*IT.java` /
  `*IntegrationTest.java` suite (in-JVM doubles; the deployment is a boot
  smoke-gate on the image, not the test target).

### `agentic-cve-analysis` steps

The table below lists each pipeline task (in DAG order, then the two `finally`
tasks) with description and the **external systems** it talks to. Everything
from `clone-repository` through `conforma-policy-check` runs unconditionally
(except the optional `verify-commit`); the issue-opening tail is gated on
`COUNT != "0"`.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|--------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `verify-commit` (`verify-commit`) | only if `verify-commit="true"` | Verifies the cloned commit's signature against the signing infrastructure. | **RHTAS** — Rekor (`rekor-url`), TUF (`tuf-mirror`), Fulcio/OIDC issuer (`oidc-issuer`). |
| `package` (`maven`) | always | Runs the Maven build in `<workspace>/<subdirectory>`, producing `target/`. | **Artifact repository** — Maven repo/mirror for dependency resolution (`maven-settings` workspace). |
| `build-container` (`buildah-rhtap`) | always | Builds the container image from `dockerfile`/`path-context` and pushes it; emits `IMAGE_URL`/`IMAGE_DIGEST` and the SBOM. | **Image registry** — pushes the built image (`output-image`). |
| `upload-sbom-to-rhtpa` (`upload-sbom-to-rhtpa`) | always | Uploads the generated SBOM(s) to RHTPA/Trustify for the component. | **RHTPA / Trustify** — SBOM ingest (auth via `tpa-secret` OIDC). |
| `rhtpa-vulnerability-analysis` (`rhtpa-vulnerability-analysis`) | always | Analyzes the uploaded SBOM against RHTPA's vuln data, then suppresses findings an advisory explicitly marks fixed/not_affected for the exact PURL; writes the authoritative `VULNERABILITY_REPORT` (CVE + severity + affected PURL, plus `.suppressed`). See [why the suppression pass exists](#why-the-pipeline-needs-a-vex-suppression-pass). | **RHTPA / Trustify** — `POST /vulnerability/analyze`, `GET /purl/{purl}`. |
| `rhtpa-remediation-report` (`rhtpa-remediation-report`) | always | Resolves a concrete fix version per (PURL, CVE) by re-analyzing every known sibling version of each affected PURL, backports first; writes `REMEDIATION_REPORT` with `.fix_versions` (authoritative) and `.recommendations` (the catalog lookup, usually empty for upstream-only Maven deps). | **RHTPA / Trustify** — `GET /purl/base/{purl}`, `POST /vulnerability/analyze`, `GET /purl/{purl}`, `POST /purl/recommend`. |
| `conforma-policy-check` (`conforma-policy-check`) | always | Turns the vuln report into a policy **must-fix** CVE set (Conforma/EC gate, severity-based fallback); writes `MUST_FIX_PATH`. | **Conforma / EC** — optional policy source fetch (`conforma-policy-configuration`); empty uses the local severity fallback. |
| `ai-analyze-cves` (`ai-analyze-cves`) | always | AI produces a remediation decision for **every** fixable CVE in the must-fix set (concrete fixed version required), steered by `ai-remediation-policy`. Each decision also captures the CVE **severity** and the list of **available fixed versions**. Writes the validated decisions to the workspace and **pre-renders one issue title/body/labels triple per CVE** — the body embeds the six fields in a `<!-- cve-decision -->` marker and also shows severity, the **recommended version** (= `fixed_version`) and the available fixed versions; the `.labels` file carries the severity. Results: `COUNT`, `DECISIONS_PATH`, `ISSUES_DIR`. | **AI model server** — per-CVE reasoning call (`ai-python-image`). |
| `open-cve-issues` (`open-cve-issues`) | if `COUNT != "0"` | Opens one issue per rendered file, applying the base `LABELS` plus the per-CVE **severity** label from the `.labels` sidecar (best-effort dedupe: skips a CVE that already has an open issue). Runs on the **agent image** (bundles glab/gh). `ISSUES_CREATED` result. | **SCM / Git repo** — `glab issue create` / `gh issue create` (creds from `scm-auth-secret`). |
| `show-sbom` (`show-sbom-rhdh`) | `finally` | Displays the SBOM for the built image in the PipelineRun output. | **Image registry** — reads the image/SBOM referenced by `IMAGE_URL`. |
| `show-summary` (`summary`) | `finally` | Prints a PipelineRun summary (git URL/commit, image URL, build-task status). | — (internal) |

### `agentic-test-generation-unit` steps

Every task runs unconditionally except **`verify-commit`** (optional). No `init`,
image build, SBOM upload, or RHTPA scan. The two sibling pipelines
(`-integration`, `-functional`) have the identical shape — see the next section
for what differs.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|-------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `verify-commit` (`verify-commit`) | only if `verify-commit="true"` | Verifies the cloned commit's signature against the signing infrastructure. | **RHTAS** — Rekor (`rekor-url`), TUF (`tuf-mirror`), Fulcio/OIDC issuer (`oidc-issuer`). |
| `package` (`maven`) | always | Runs the Maven build in `<workspace>/<subdirectory>`, producing `target/`. | **Artifact repository** — Maven repo/mirror for dependency resolution (`maven-settings` workspace). |
| `ai-generate-tests-unit` (`ai-generate-tests-unit`) | always | AI coding agent generates JUnit tests under `src/test/**` and runs them (in a pod-local scratch copy); leaves the new tests on the workspace. `TESTS_ADDED` result. | **AI model server** (reasoning + edits); **Artifact repository** — Maven repo/mirror (`maven-settings`), installed as `~/.m2/settings.xml` so both the scratch verification build and the agent's own `mvn test` calls resolve through it. Once a remediation PR has merged, the tree carries a Lightwell `.rhlw` pin that does not exist on Central. |
| `re-run-tests` (`maven`) | always | Runs `mvn test` (existing + generated unit tests; surefire only — never the failsafe `*FT`/`*IT` classes) against the tree. | **Artifact repository** — Maven repo/mirror (`maven-settings`). |
| `open-pr` (`open-pr-tests`) | always | Commits **only** the generated tests (`src/test`) to an `ai-tests/*` branch and opens a tests-only PR/MR (no CVE/fix wording; adds `Related to #N` when `ISSUE_IID` is set by an issue trigger); no-ops if nothing changed. Runs on the **agent image** (bundles git/glab/gh). `PR_URL` result. | **SCM / Git repo** — `git push` + `glab mr create` / `gh pr create` (creds from `scm-auth-secret`). |

### `agentic-test-generation-functional` / `agentic-test-generation-integration` steps

Same chain as `agentic-test-generation-unit` (clone → verify-commit → package → … →
re-run → open-pr), with the differences below. Each generation task follows its
own agent skill — `test-generation-functional` / `test-generation-integration`
— which defines the category's execution contract and tool stack; the task
prompt carries only the run contract.

| | `agentic-test-generation-functional` | `agentic-test-generation-integration` |
|---|---|---|
| Generation task | `ai-generate-tests-functional` | `ai-generate-tests-integration` |
| Test category / naming | functional — `*FT.java` | integration — `*IT.java` |
| What the agent generates | black-box REST Assured tests of the **deployed application** through its service interface (OpenAPI spec as read-only context); no DB/actuator/log assertions, data self-arranged via the API with **unique identifiers** (the app's state persists across runs) | interactions between components and their dependencies, every dependency a **test-managed double** (embedded H2, WireMock stub; **no Testcontainers** — CI runners are dockerless) |
| App under test | `deploy-app-under-test` builds an image from the packaged boot jar, pushes it to the **integrated registry**, and creates a Deployment + Service in `tssc-app-ci` (named after the PipelineRun, so concurrent runs never collide); its readiness probe is the app's health endpoint, so the task only succeeds once the app genuinely serves. The generation task then drives that Deployment through the Kubernetes API with its own service-account token: **state reset** (delete the app's pods → fresh in-memory database) before every verification run, and the app's **server log tail** appended to the agent's failure feedback (the stack traces behind HTTP 5xx responses live there, not in the Maven output) | none — doubles run inside the test JVM |
| `re-run-tests` goals | `test-compile` → direct failsafe (scoped `-Dit.test=*FT`) → `failsafe:verify`, against the deployed app's Service URL (`-DAPP_BASE_URL` + credentials; no `spring-boot:start`/`stop` — the app is a Deployment, not a forked JVM in the pod). Preceded by `reset-app-under-test`, which deletes the app's pods so the re-run sees the same fresh state the generation task verified against | `test-compile` + direct `failsafe:integration-test` + `failsafe:verify`, scoped `-Dit.test=*IT,*IntegrationTest` (runs the integration suite even without a pom failsafe binding; both patterns because the agent imitates the repo's existing `*IntegrationTest` naming as often as the skill's `*IT` — see `jbvhv`) |
| MR contents | `src/test` + `pom.xml` (test-scoped additions such as REST Assured) | `src/test` + `pom.xml` (test-scoped additions such as WireMock/Awaitility) |
| Why direct failsafe, not `mvn verify` | the pom may declare no failsafe binding (the agent is only *permitted* test-scoped changes), and without a binding `mvn verify` silently runs **zero** `*IT.java`/`*FT.java` tests — the re-run would go green while testing nothing. The `-Dit.test` scope is not optional: the CLI failsafe goal otherwise inherits the pom's failsafe includes, which on this app are `**/*FT.java` — the functional tests against a deployed app (`agentic-test-generation-integration-issue-hdrhp`) | same |
| Ephemeral resources / cleanup | Deployment + Service + ImageStream labeled `app.kubernetes.io/part-of=ephemeral-test-resources` and carrying an ownerReference to the PipelineRun; `cleanup-app-under-test` runs as a **`finally` task** (success *or* failure) and never fails the run. Hard-timeout caveat: a PipelineRun **timeout** cancels finally tasks too, so on that path the resources linger until the PipelineRun object is deleted (ownerReference GC) — or sweep manually: `oc -n tssc-app-ci delete deployment,service,imagestream -l app.kubernetes.io/part-of=ephemeral-test-resources` | none |
| RBAC | `pipeline` SA gets the `app-under-test-lifecycle` Role (deployments/services/pods, pods/log, imagestreams — all in `tasks/deploy-app-under-test.yaml`) plus `system:image-builder` for the integrated registry push; the pipeline pins the ephemeral-resource tasks to that SA via `taskRunSpecs` | none beyond the standard pipeline SA |
| SCC | the generated app Deployment is **restricted-v3-clean by construction**: `hostUsers: false` (restricted-v3 mandates a user namespace), `runAsNonRoot` with an admission-assigned uid (the restricted SCCs enforce MustRunAsRange 1000–65534 — don't pin the image's nominal user 185, it's below the minimum), all capabilities dropped, seccomp `runtime/default`; no special SCC needed. The deploy task's buildah step adds `SETFCAP` and runs under the operator's `pipelines-scc` — **spell it all-caps**: SCC capability matching is case-sensitive and the Tekton-catalog spelling `SETFCap` is rejected by every SCC on the cluster | none |

### `test-image-functional` / `test-image-integration` steps

Image-level test evidence: run a project's existing test suite against a
**published container image** (the exact artifact CI built — not a rebuild),
in a **per-run ephemeral namespace** that is deleted when the run ends. The
two pipelines share one shape; both take the `image`, the project repo
(`git-url`/`revision`), and an optional `issue-iid` to comment evidence on.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|--------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. Runs **in parallel** with `create-test-namespace` (only the clone touches the workspace PVC). | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `create-test-namespace` (`create-test-namespace`) | always | Creates a namespace **named after the PipelineRun** (unique per run, so concurrent runs never collide), labeled `app.kubernetes.io/part-of=ephemeral-test-namespace` for manual sweeps. `NAMESPACE` result. | **Kubernetes API** — namespace create (RBAC: the `ephemeral-test-namespace-lifecycle` ClusterRole in the task file). |
| `deploy-app-image` (`deploy-app-image`) | always | Deploys `image` into the ephemeral namespace as a health-gated Deployment + Service (readiness probe = the app's health endpoint, so the task only succeeds once the image is genuinely **serving**). Copies the `quay-push` pull secret into the namespace when the image lives in the private in-cluster Quay (the secret is **mounted** into the task pod and re-created inside the target namespace — never read through the API, so the ClusterRole needs only `secrets:create`). `APP_BASE_URL` result. | **Kubernetes API** — deployment/service create + wait. |
| `run-tests` (`maven`) | always | `test-compile` → direct failsafe → `failsafe:verify` (same invocation contract as the test-generation pipelines' re-runs: a pom without a failsafe binding silently runs zero `*FT`/`*IT` tests on `verify`). Functional: `-Dit.test=*FT` against the deployed app (`-DAPP_BASE_URL` + credentials). Integration: `-Dit.test=*IT,*IntegrationTest`, in-JVM doubles — the deployment is a boot **smoke-gate** on the image, not the test target. | **Artifact repository** — Maven repo/mirror (`maven-settings`). |
| `comment-test-evidence` (`comment-test-evidence`) | only if `run-tests` succeeded (plain DAG ordering — **not** a finally task) | Parses `target/failsafe-reports/*.txt`, aggregates totals + a per-class table, and posts a test-summary evidence comment on the `issue-iid` issue (`glab issue note` / `gh issue comment`, creds from `scm-auth-secret`). Empty `issue-iid` = no comment, evidence stays in the PipelineRun log. **Fails the run** when it cannot post a comment it was asked to post. | **SCM / Git repo** — issue comment (creds from `scm-auth-secret`). |
| `cleanup-test-namespace` (`cleanup-test-namespace`) | `finally` (always) | Deletes the ephemeral namespace — and with it **everything** the run deployed (namespace deletion garbage-collects all contents, which is why these pipelines use a per-run namespace instead of per-resource cleanup). `--wait=false` + a ~2-min bounded poll; never fails the run. | **Kubernetes API** — namespace delete. |

Notes that matter when changing these pipelines:

- **The namespace name comes from `$(context.pipelineRun.name)`** — passed to
  both the create task and the finally cleanup directly from the context, so
  cleanup works even when the create task itself failed partway. A namespace
  **cannot** carry an ownerReference to the PipelineRun (cluster-scoped
  objects need cluster-scoped owners), so the safety nets are the finally
  task and the label sweep:
  `oc delete namespace -l app.kubernetes.io/part-of=ephemeral-test-namespace`.
  As with the test-generation pipelines, a PipelineRun **hard timeout**
  cancels finally tasks too — that sweep is the recovery path.
- **The ClusterRole is deliberately enumerated** (namespaces cluster-scoped;
  deployments/services/pods/pods/log/events namespaced; `secrets` create-only)
  — a `resources: ["*"]` wildcard would also match cluster-scoped resources
  and make the binding a de-facto cluster-admin. `secrets` is create-only so
  the SA never becomes a cluster-wide secret *reader*: the pull secret is
  mounted into the pod and re-created, not fetched. Add a rule when a task
  needs a new resource kind; don't widen existing ones.
- **`deploy-app-image` is a gate, not scaffolding** — an image that cannot
  boot never gets test evidence. If you want the integration suite to run
  regardless of bootability, drop `deploy-app-image` from `run-tests`'
  `runAfter` (documented in the pipeline header too).

### `agentic-cve-remediation` steps

Every task runs unconditionally except **`verify-commit`** (optional) and the
remediation tail, which is gated on `SELECTED="1"`. No discovery, scan, or
analysis — those live in `agentic-cve-analysis`, which opens the issue this
pipeline is triggered from.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|-------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `verify-commit` (`verify-commit`) | only if `verify-commit="true"` | Verifies the cloned commit's signature against the signing infrastructure. | **RHTAS** — Rekor (`rekor-url`), TUF (`tuf-mirror`), Fulcio/OIDC issuer (`oidc-issuer`). |
| `ai-remediate-dependency` (`ai-remediate-dependency`) | if `SELECTED="1"` | AI edits `pom.xml` to bump only the vulnerable dependency (`PACKAGE`) to `FIXED_VERSION` and confirms it still compiles (scratch build); leaves the change on the workspace. `CHANGED` result. | **AI model server** (reasoning + edits); **Artifact repository** — Maven repo/mirror (`maven-settings`), installed as `~/.m2/settings.xml` so both the verify-compile and the agent's own `mvn` calls resolve through it. A pinned Lightwell `.rhlw` backport does not exist on Central, so without this workspace the verify-compile fails on the version the agent just pinned. |
| `re-run-tests` (`maven`) | if `SELECTED="1"` | Runs `mvn package` (surefire unit tests only) against the remediated tree. | **Artifact repository** — Maven repo/mirror (`maven-settings`). |
| `open-pr` (`open-pr`) | if `SELECTED="1"` | Commits the remediation to an `rhtpa/*` branch, pushes it, and opens a PR/MR (carries the CVE/fix context; adds `Related to #N` when `ISSUE_IID` is set by an issue trigger). Runs on the **agent image** (bundles git/glab/gh). `PR_URL` result. | **SCM / Git repo** — `git push` + `glab mr create` / `gh pr create` (creds from `scm-auth-secret`). |

### `ci-build-publish` steps

The plain-CI counterpart of the analysis head: the same clone → package →
build-container → upload-sbom-to-rhtpa chain, with everything agentic stripped
out. Every task runs unconditionally except `verify-commit` (optional) and
`upload-sbom-to-rhtpa` (gated on `upload-sbom="true"`, the default).

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|-------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `verify-commit` (`verify-commit`) | only if `verify-commit="true"` | Verifies the cloned commit's signature against the signing infrastructure. Off by default — the demo's commits are unsigned; see the [pipeline header](pipelines/ci-build-publish.yaml) for the correct issuer/rekor defaults on this cluster. | **RHTAS** — Rekor (`rekor-url`), TUF (`tuf-mirror`), Fulcio/OIDC issuer (`oidc-issuer`). |
| `package` (`maven`) | always | The CI gate: `mvn package` — compiles and runs the surefire **unit tests** before anything is published (`package`, never `verify`: the pom binds failsafe to `**/*FT.java`, deployment-dependent functional tests this pipeline never stands up). GOALS prepend wagon resilience flags against intermittent Artifactory route errors. | **Artifact repository** — Maven repo/mirror for dependency resolution (`maven-settings` workspace), which is also what makes a Lightwell backport coordinate resolvable at all. |
| `build-container` (`buildah-rhtap`) | always | Builds the image from `dockerfile` (`Containerfile` by default — the app repo ships a Containerfile, and buildah-rhtap exits 1 if the named file is missing) and pushes to `output-image`; emits `IMAGE_URL`/`IMAGE_DIGEST`, generates the CycloneDX SBOM and `cosign attach`es it to the pushed image; labels the image with source URL + commit. No `IMAGE_EXPIRES_AFTER` — a published image must not carry an expiry label (unlike the analysis pipeline's throwaway scan image). | **Image registry** — push authenticated by the `quay-push` Secret linked to the `pipeline` SA (no credential named in the pipeline). |
| `upload-sbom-to-rhtpa` (`upload-sbom-to-rhtpa`) | only if `upload-sbom="true"` (default) | Uploads the generated SBOM(s) to RHTPA/Trustify so the agentic pipelines have something to analyze; `fail-if-trustification-not-configured` defaults to `"true"` — CI fails rather than publishing an image RHTPA has no record of. | **RHTPA / Trustify** — SBOM ingest (auth via `tpa-secret` OIDC). |
| `show-sbom` (`show-sbom-rhdh`) | `finally` | Displays the SBOM for the built image in the PipelineRun output. | **Image registry** — reads the image/SBOM referenced by `IMAGE_URL`. |
| `show-summary` (`summary`) | `finally` | Prints a PipelineRun summary (git URL/commit, image URL, build-task status). | — (internal) |
| `start-gitops-cd-dev` (`start-gitops-cd-dev`) | `finally`, if `deploy-dev-gitops="true"` (default) **and** `build-container` succeeded | Creates the `gitops-cd-dev` PipelineRun through the Kubernetes API (see the [`gitops-cd-dev` DAG](#gitops-cd-dev-dev-image-promotion)), passing the exact `output-image` just published. Runs as `tekton-triggers-sa`, pinned via `taskRunSpecs` on the PipelineRun — `taskRunSpecs` is PipelineRun-only, so the API server prunes it from the Pipeline CRD; the live pinning lives in `triggers/ci-build-triggers.yaml`. | **Kubernetes API** — `curl` POST of the PipelineRun, authenticated by the pod's service-account token. |

## Files

| File | Purpose |
|------|---------|
| `pipelines/agentic-cve-analysis.yaml` | Self-contained CVE discovery/scan/fan-out pipeline (build → SBOM → RHTPA scan → must-fix gate → AI decision per fixable CVE → one issue per vulnerability, each carrying the six-field decision) |
| `pipelines/agentic-test-generation-unit.yaml` | Standalone AI test-generation pipeline (generate unit tests → `mvn test` → tests-only PR/MR) |
| `pipelines/agentic-test-generation-functional.yaml` | Same flow generating functional tests (`*FT.java`, black-box REST Assured) against the app deployed as ephemeral namespaced resources; `finally` task guarantees cleanup; `taskRunSpecs` pin the ephemeral-resource tasks to the `pipeline` SA |
| `pipelines/agentic-test-generation-integration.yaml` | Same flow generating integration tests (`*IT.java`, embedded/WireMock doubles); re-run uses direct failsafe; MR stages test-scoped pom additions |
| `pipelines/agentic-cve-remediation.yaml` | Applies a remediation decision (in via params) to the repo: clone → AI bump dependency → `mvn package` (unit tests only) → PR/MR |
| `pipelines/ci-build-publish.yaml` | CI for the application repository — clone → `mvn package` (unit tests only) → buildah build + push to the in-cluster Quay → SBOM attach + RHTPA upload; `finally` task starts `gitops-cd-dev` after a successful build |
| `pipelines/gitops-cd-dev.yaml` | Dev GitOps CD — promote the image `ci-build-publish` just published into the gitops repo's dev values file (MR + auto-merge) |
| `pipelines/gitops-cd-prod.yaml` | Prod GitOps CD — same promotion, into the prod values file, started by a human; the MR stays open for review (`auto-merge="false"`) |
| `pipelines/gitops-cd-qa.yaml` | QA GitOps CD — same promotion, into the qa values file, started by a human; the MR stays open for review (`auto-merge="false"`) |
| `pipelines/test-image-functional.yaml` | Image-level functional test evidence — deploy a published image in a per-run ephemeral namespace, run the `*FT.java` suite against it, comment the summary on the given issue on success |
| `pipelines/test-image-integration.yaml` | Same for the `*IT.java`/`*IntegrationTest.java` suite; the deployment is a boot smoke-gate, the tests run against in-JVM doubles |
| `triggers/agentic-issue-triggers.yaml` | Tekton Triggers wiring to start pipelines from a GitLab issue comment — `/remediate` → `agentic-cve-remediation`, `/generate-tests-unit` → `agentic-test-generation-unit`, `/generate-tests-functional` → `agentic-test-generation-functional`, `/generate-tests-integration` → `agentic-test-generation-integration` (one EventListener + interceptors + a binding/template per command + RBAC + Route; the three `/generate-tests*` commands share one TriggerBinding) |
| `triggers/ci-build-triggers.yaml` | Tekton Triggers wiring for `ci-build-publish` — the push EventListener + `ci-build-push-template` (resolves `output-image` from the commit SHA and the cluster's Quay); also carries the PipelineRun `taskRunSpecs` that pin the `start-gitops-cd-dev` finally task to `tekton-triggers-sa` |
| `config/ai-agent-config.yaml` | ConfigMap — the single AI backend switch (provider/model/region/effort) |
| `config/rhtpa-enable-importers-job.yaml` | Job — idempotently enables + forces the RHTPA Red Hat SBOM/CSAF importers |
| `ops/rhtpa-upload-advisory.sh` | Script — uploads/verifies/deletes a **single** advisory document (OSV/CSAF/…) in RHTPA, for records no importer covers |
| `ops/rhtpa-load-lightwell-data.sh` | Script — loads **the whole Lightwell remediation dataset** (`data/osv/` + `data/sbom/`) into RHTPA and verifies it; `--verify` / `--purge` |
| `ops/ai-agent-image-prewarm-daemonset.yaml` | DaemonSet — pre-pulls the large agent image onto every node so steps can't flake on ImagePullBackOff |
| `data/osv/LW-DEMO-001*.json` | OSV advisories — one per CVE, each declaring the Lightwell `.rhlw-00001` backport as the `fixed` version (see [Lightwell remediation data](#lightwell-remediation-data)) |
| `data/sbom/*.cdx.json` | One-component CycloneDX catalog SBOMs — their only job is to make each `.rhlw-00001` build a *known version* of its base PURL, so the fix-version scan can offer it |
| `secrets/ai-agent-secret.example.yaml` | Example Secret — AI provider credentials |
| `secrets/scm-auth-secret.example.yaml` | Example Secret — Git token for opening the PR/MR |
| `secrets/scm-auth-gitops-secret.example.yaml` | Example Secret — the gitops repository's own token for the gitops CD pipelines (a GitLab project bot cannot be shared across projects, so it is separate from `scm-auth-secret`) |
| `secrets/gitlab-webhook-secret.example.yaml` | Example Secret — shared token validating the GitLab issue webhook |
| `tasks/ai-generate-tests-unit.yaml` | AI generates + runs unit tests |
| `tasks/ai-generate-tests-integration.yaml` | AI generates + runs integration tests (`*IT.java`) per the `test-generation-integration` skill |
| `tasks/ai-generate-tests-functional.yaml` | AI generates + runs functional tests (`*FT.java`) per the `test-generation-functional` skill, against the app **deployed** by `deploy-app-under-test`; health-checks it, resets its state (pod deletion) before every verification run, and feeds its server log tail back to the agent on failures |
| `tasks/deploy-app-under-test.yaml` | Deploys the app under test as ephemeral namespaced resources (jar → image → integrated registry → health-gated Deployment + Service, owner-referenced to the PipelineRun); the generated Deployment is restricted-v3-clean (user namespace, non-root, no capabilities); **also carries the RBAC** — Role `app-under-test-lifecycle` + `system:image-builder` RoleBinding for the `pipeline` SA (namespace hardcoded to `tssc-app-ci`; change it if the pipeline namespace moves) |
| `tasks/reset-app-under-test.yaml` | Resets the deployed app to a clean state (delete its pods; the Deployment recreates them with a fresh in-memory database) and waits for readiness |
| `tasks/cleanup-app-under-test.yaml` | `finally` task — deletes the run's ephemeral Deployment/Service/ImageStream whether the run succeeded or failed; never fails the run itself |
| `tasks/create-test-namespace.yaml` | Creates the per-run ephemeral test namespace (named after the PipelineRun, labeled for sweeps); **carries the `ephemeral-test-namespace-lifecycle` ClusterRole + ClusterRoleBinding** that let the `pipeline` SA create/delete namespaces and deploy inside them |
| `tasks/deploy-app-image.yaml` | Deploys a given published image into a given namespace as a health-gated Deployment + Service; copies the pull secret in-namespace when the registry is private |
| `tasks/comment-test-evidence.yaml` | Parses the failsafe reports and posts the test-summary evidence comment on a GitLab/GitHub issue (success tail of the test-image pipelines) |
| `tasks/cleanup-test-namespace.yaml` | `finally` task — deletes the ephemeral test namespace (and everything in it) whether the run succeeded or failed; never fails the run |
| `tasks/rhtpa-vulnerability-analysis1.yaml` | Scans the SBOM's PURLs against RHTPA, then suppresses findings explicitly marked fixed/not_affected |
| `tasks/rhtpa-remediation-report2.yaml` | Resolves a concrete fix version per (PURL, CVE) — `.fix_versions`, backports first |
| `tasks/conforma-policy-check.yaml` | Conforma gate → must-fix CVE set |
| `tasks/ai-analyze-cves.yaml` | AI decides per fixable CVE (with severity + available fixed versions); renders one issue title/body/labels triple each |
| `tasks/open-cve-issues.yaml` | Opens one GitLab/GitHub issue per rendered file, applying the base + per-CVE severity label (runs on the **agent image**) |
| `tasks/ai-remediate-dependency.yaml` | AI bumps the dependency + verifies compile |
| `tasks/open-pr-cve.yaml` | Task `open-pr` — commits to a branch and opens the PR/MR for CVE remediation (runs on the **agent image** — see note below) |
| `tasks/open-pr-tests.yaml` | Tests-only PR/MR (no CVE/fix context) — used by the test-generation pipelines; `TEST_CATEGORY` param (unit/integration/functional) controls whether the MR also stages test-scoped `pom.xml` additions |
| `tasks/gitops-bump-image.yaml` | Bumps `image.tag` in a gitops values file and lands it as an (auto-merged) MR — used by the dev CD pipeline |
| `tasks/start-gitops-cd-dev.yaml` | Creates a `gitops-cd-dev` PipelineRun through the Kubernetes API — run as a `finally` task of `ci-build-publish` |
| `images/ai-agent-maven-claude/Dockerfile` | Agent runtime, **Claude Code** flavor (ubi-minimal + JDK17 + Maven + Node/Claude Code + git/glab/gh) |
| `images/ai-agent-maven-aider/Dockerfile` | Agent runtime, **aider** flavor (ubi-minimal + JDK17 + Maven + Python/aider + git/glab/gh) |
| `images/ai-python/Dockerfile` | CVE analysis runtime (Anthropic + OpenAI Python SDKs) |

## DAG

### `agentic-cve-analysis`

```
clone-repository → verify-commit → package → build-container → upload-sbom-to-rhtpa → rhtpa-vulnerability-analysis → rhtpa-remediation-report
                                                                                                                                 │
                                                                                                                  conforma-policy-check
                                                                                                                                 │
                                                                                                                       ai-analyze-cves → open-cve-issues
```

A single linear chain — build → SBOM → RHTPA scan → must-fix gate — ending in a
fan-out to issues. The scan tasks run after the build (not forked off
`clone-repository`) so nothing runs concurrently with the build/scan tasks that
write `target/` on the shared workspace — a concurrent writer there bumps the
workdir mtime mid-read and breaks the agents' `tar` of the source, so
serializing avoids that race and is simpler to reason about. The pipeline
**changes nothing in the repo** beyond the issues it opens; `verify-commit` is
optional. The tail is a fan-out: `ai-analyze-cves` produces a decision for **every** fixable CVE and
pre-renders one issue **title/body/labels** triple per CVE onto the workspace. The
body embeds the six fields in a `<!-- cve-decision -->` marker (values JSON-encoded
so the block is valid for the `/remediate` trigger's parser) and, above it, a
human-readable summary showing the CVE **severity**, the **recommended version**
(the model's single pick — still `fixed_version` in the marker, just relabelled for
readers) and the list of **available fixed versions**. The `.labels` sidecar holds
the severity so it can become an issue label. `open-cve-issues` then submits them,
applying the base `LABELS` plus each CVE's severity label, gated on `COUNT != "0"`
so a clean scan opens nothing. Splitting the two lets the AI parsing stay in the
Python image while the issue creation runs on the agent image (which has
`glab`/`gh`); the git task does **no** JSON parsing. Best-effort dedupe skips a CVE
that already has an open issue, so re-runs don't pile up duplicates.

`ai-analyze-cves` processes the must-fix set in **batches** rather than one giant
prompt — a large list (e.g. 77 CVEs) otherwise blows the model's combined
thinking+output token budget and comes back empty. It splits the CVEs into chunks,
trims the vuln report per-batch to what each chunk needs, retries a failed batch
once, and accumulates the decisions. Two params on the `ai-analyze-cves` task tune
this (both have working defaults; wire them through a pipeline param to override
per run):

| Param | Default | Effect |
|-------|---------|--------|
| `BATCH_SIZE` | `12` | CVEs per model call. Lower it if batches still return truncated/empty on a verbose report; raise it to cut the number of calls. |
| `MAX_TOKENS` | `8000` | Combined thinking+output budget per call (Anthropic counts both against `max_tokens`). Raise it if a batch's output is cut off mid-JSON. |

### `agentic-test-generation-unit`

```
clone-repository → verify-commit → package → ai-generate-tests-unit → re-run-tests (mvn test) → open-pr
                                                          (re-run-tests + open-pr only if TESTS_ADDED != "0")
```

The standalone test-generation pipeline (`pipelines/agentic-test-generation-unit.yaml`)
is the `ai-generate-tests-unit` flow split out on its own. It has no `init`, image
build, SBOM upload, or RHTPA scan; every task runs unconditionally except
**`verify-commit`** (optional) and the `re-run-tests`/`open-pr` tail, which is
gated on `ai-generate-tests-unit` actually producing new/changed tests
(`TESTS_ADDED != "0"`) — a run that generates nothing ends cleanly after
`ai-generate-tests-unit`. The re-run stops at `mvn test`: surefire unit tests only —
the pom's main build binds failsafe to `**/*FT.java`, so `verify` would run the
deployment-dependent functional tests this pipeline never stands up. The final
`open-pr` step uses the **`open-pr-tests`** task —
a tests-only variant that commits just the generated tests (`src/test`) to an
`ai-tests/*` branch with no CVE/fix wording, and no-ops if nothing changed. Like
the CVE pipelines the agent and `mvn test` run in a pod-local scratch copy to
avoid the shared-`target/` race. It needs the `ai-agent-config`/`ai-agent-secret`
and `scm-auth-secret` objects (and the agent image), but not `tpa-secret`, RHTPA,
or TAS.

### `agentic-test-generation-functional` / `agentic-test-generation-integration`

```
functional:
clone-repository → verify-commit → package → deploy-app-under-test → ai-generate-tests-functional → reset-app-under-test → re-run-tests → open-pr
                                                                        (reset + re-run-tests + open-pr only if TESTS_ADDED != "0")
  finally (always, success or failure): cleanup-app-under-test

integration:
clone-repository → verify-commit → package → ai-generate-tests-integration → re-run-tests → open-pr
                                                       (re-run-tests + open-pr only if TESTS_ADDED != "0")
```

Identical gating to `agentic-test-generation-unit` above; the task-level differences
(skill, verification goals, app lifecycle, MR contents, ephemeral resources and
their cleanup) are in the steps table in the [Overview](#overview). Three
things worth restating:

- the agent's pom edits are **test-scoped only** (dependencies and test-only
  build config), enforced by the skill's constraints and the prompt, and those
  changes ride along in the MR via `open-pr-tests`' `TEST_CATEGORY` staging;
- both re-runs invoke Failsafe **directly** rather than plain `mvn verify`,
  because a pom without a failsafe binding silently runs zero `*IT.java` /
  `*FT.java` tests on `verify` — the re-run would pass while testing nothing;
- the functional pipeline's app under test is **ephemeral**: it lives only for
  the run (deploy after `package`, `cleanup-app-under-test` in `finally`), is
  named after the PipelineRun so concurrent runs never collide, and is
  owner-referenced to the PipelineRun so Kubernetes GC removes it even if the
  run dies without running finally tasks. The one hole: a PipelineRun **hard
  timeout** cancels finally tasks too, so on that path the resources linger
  until the PipelineRun object is deleted — or sweep manually with
  `oc -n tssc-app-ci delete deployment,service,imagestream -l app.kubernetes.io/part-of=ephemeral-test-resources`.

### `agentic-cve-remediation`

```
clone-repository → verify-commit → ai-remediate-dependency → re-run-tests (mvn package) → open-pr
                                                        (whole tail only if SELECTED == "1")
```

This pipeline is **param-driven**: it takes the remediation decision in as
params rather than computing it. There is no build, SBOM upload, or RHTPA scan —
it clones the repo, has the AI bump the one dependency, re-verifies, and opens the
PR. `ai-remediate-dependency`, `re-run-tests`, and `open-pr` are each gated on
`SELECTED == "1"`, so passing `SELECTED="0"` (or omitting it — it defaults to
`"0"`) makes the pipeline a clean no-op after the clone. The guard is repeated on
all three tasks because Tekton's "skipped-parent still runs the successor"
semantics don't short-circuit a `runAfter` successor unless the successor's own
`when` also fails. `verify-commit` is optional. The re-run stops at `mvn package`:
surefire unit tests only — the pom's main build binds failsafe to `**/*FT.java`,
so `verify` would run the deployment-dependent functional tests (see
`agentic-cve-remediation-issue-mhm88`). Like the other pipelines the
agent and `mvn package` run in a pod-local scratch copy to avoid the
shared-`target/` race.

### `ci-build-publish`

```
clone-repository → verify-commit → package → build-container → upload-sbom-to-rhtpa
                                     (optional)                             (only if upload-sbom="true")

finally (always):                              show-sbom, show-summary
finally (deploy-dev-gitops="true" AND          start-gitops-cd-dev → gitops-cd-dev
        build-container succeeded):
```

The plain-CI chain: the same head as `agentic-cve-analysis` (clone → `mvn
package` → buildah build + push → SBOM attach + RHTPA upload) with everything
agentic stripped out — no vulnerability analysis, no Conforma gate, no AI, no
issues. `package` is the CI gate: surefire unit tests run before anything is
published, and a failing build must not produce an image. `upload-sbom-to-rhtpa`
is gated on `upload-sbom` (default `"true"`) and fails the run when it cannot
authenticate (`fail-if-trustification-not-configured` default `"true"`) — CI
fails rather than publishing an image RHTPA has no record of.

The `finally` tasks: `show-sbom` and `show-summary` always run;
`start-gitops-cd-dev` runs only when `build-container` succeeded **and**
`deploy-dev-gitops="true"` (the default), creating the `gitops-cd-dev`
PipelineRun — see the [next section](#gitops-cd-dev-dev-image-promotion). It is
pinned to `tekton-triggers-sa` via `taskRunSpecs` on the PipelineRun in
`triggers/ci-build-triggers.yaml`, because `taskRunSpecs` is a PipelineRun-only
field the API server prunes from Pipeline CRDs (a pin written into the Pipeline
syncs "clean" but silently does nothing). Note the guard's `values: ["Succeeded"]`
carries a **capital S** — Tekton task statuses are Kubernetes conditions, and the
lowercase spelling silently never matches (`ci-build-publish-83b6f93` skipped dev
promotion this way; the only trace is `.status.skippedTasks`).

Two defaults differ from the agentic pipelines because this image is meant to
survive: `dockerfile` defaults to `Containerfile` (the app repo ships one, and
buildah-rhtap exits 1 when the file it was told to use is missing), and there is
no `IMAGE_EXPIRES_AFTER` — a published image must not carry an expiry label.
Started by the push trigger in `triggers/ci-build-triggers.yaml`
(`ci-build-push-template`) on merges to the application repo, or manually with
the same params.

### `gitops-cd-dev` (dev image promotion)

```
ci-build-publish (finally: start-gitops-cd-dev) → gitops-cd-dev → gitops-bump-image → MR (auto-merged)
```

`ci-build-publish` ends with a `finally` task that starts `gitops-cd-dev`
whenever `build-container` succeeded and `deploy-dev-gitops` is `"true"` (the
default). Tekton has no native pipeline-to-pipeline chaining, so the finally
task (`tasks/start-gitops-cd-dev.yaml`) creates the CD PipelineRun itself with
a `curl` POST against the Kubernetes API, authenticated by the pod's service
account token (it runs as `tekton-triggers-sa`, which already holds `create
pipelineruns` from the trigger RBAC). It passes the exact `output-image` CI
just published — the tag is the commit SHA, an immutable pointer to the source,
SBOM and signatures, so the values file only ever references an image that
exists and was just built.

The CD pipeline is one task (`gitops-bump-image`): clone the **gitops** repo
(`development/spring-boot-example-gitops` on the cluster's GitLab), rewrite
`image.tag` in `app/spring-boot-example/environments/dev/values.yaml`, push a
`gitops/dev-image-<sha>` branch, open an MR, and merge it immediately
(`AUTO_MERGE="true"`). The bot in `scm-auth-gitops-secret` cannot push the
protected default branch directly, but can push a branch and open + accept an
MR, so main only ever moves through GitLab and every promotion is a merge
record. That secret is the gitops repository's **own** project access token,
not the application repository's `scm-auth-secret`: a GitLab project-bot user
is a member of exactly one project and cannot be added to another, so the
gitops repo needs a separate token (both are minted by the GitLab seeding job
on a GitOps install). Argo CD
then picks up the values change and rolls dev. No-op safe: if the tag is
already current the run exits cleanly with no MR. **Auto-merge is scoped to
dev** — promoting to qa/prod stays a human decision, made through the
pipelines below. The pipeline has no workspaces: the task clones the tiny
gitops repo into a pod-local temp dir, so a bare PipelineRun needs no PVC
plumbing.

Run it manually the same way the finally task does:

```bash
tkn -n tssc-app-ci pipeline start gitops-cd-dev \
  -p image=quay.apps.<domain>/tssc/spring-boot-example-application:<sha> \
  -p app-repo-url=https://… -p app-commit=<sha> --showlog
```

### `gitops-cd-prod` / `gitops-cd-qa` (human-gated promotion)

```
gitops-cd-dev (auto) → gitops-cd-prod (human start) → MR (open for review) → human merges → Argo CD rolls prod
                                        └────────── gitops-cd-qa (human start) → MR (open for review) → human merges → Argo CD rolls qa
```

The prod and qa pipelines are the same one-task `gitops-bump-image` flow as
dev, with two deliberate differences:

- **Started by a human, not chained off CI.** Nothing triggers them
  automatically — promoting past dev is a decision, not a side effect of a
  build. You start one with the image reference that has earned the promotion
  (usually the tag dev just rolled, and for prod, the one that survived qa).
- **`auto-merge` defaults to `"false"`.** The run opens the promotion MR
  (branch `gitops/prod-image-<sha>` / `gitops/qa-image-<sha>`) and leaves it
  open; merging it in GitLab **is** the promotion. Override with
  `-p auto-merge=true` only when you want dev-style automatic merge.

They share everything else with dev: the gitops repo
(`scm-auth-gitops-secret`), no workspaces, and the no-op-if-tag-current
behavior. Environment and values file are baked in as defaults
(`environments/prod/values.yaml` / `environments/qa/values.yaml`), so a run
needs nothing but the image:

```bash
tkn -n tssc-app-ci pipeline start gitops-cd-prod \
  -p image=quay.apps.<domain>/tssc/spring-boot-example-application:<sha> --showlog
# read the MR URL from the results, review it, merge it in GitLab
```

The run's `MR_URL` result points at the open MR; after you merge it, the
`spring-boot-example-prod` (or `-qa`) Argo CD Application picks up the values
change and rolls the deployment.

### `test-image-functional` / `test-image-integration` (image-level test evidence)

```
clone-repository ─┐
                  ├─> run-tests (failsafe: *FT against the app | *IT in-JVM) -> comment-test-evidence
create-test-namespace -> deploy-app-image ─┘

finally (always): cleanup-test-namespace   (deletes the namespace = everything in it)
```

Both pipelines take the **published image** as a param — the exact artifact
`ci-build-publish` pushed (`quay.apps.<domain>/tssc/<component>:<sha>`), not a
rebuild — plus the project repo and an optional `issue-iid`. `run-tests` gates
on both the clone and the deployment: the deployment's readiness probe is the
app's health endpoint, so the suite only runs once the image is **genuinely
serving** (in the integration pipeline that deployment is a boot smoke-gate
rather than the test target — the suite runs against in-JVM doubles). On
success `comment-test-evidence` parses `target/failsafe-reports/*.txt` and
posts the totals + per-class table on the issue; a run with no `issue-iid`
records its evidence only in the PipelineRun log. The `finally` task deletes
the ephemeral namespace whatever happened.

Run one manually:

```bash
tkn -n tssc-app-ci pipeline start test-image-functional \
  -p image=quay.apps.<domain>/tssc/spring-boot-example-application:<sha> \
  -p git-url=https://gitlab-gitlab.apps.<domain>/development/spring-boot-example-application \
  -p issue-iid=42 \
  -w name=workspace,claimName=pvc --showlog    # bind workspace + maven-settings
```

The `pipeline` SA needs the `ephemeral-test-namespace-lifecycle` ClusterRole
(shipped in `tasks/create-test-namespace.yaml`) before the first run — it
grants namespace create/delete plus the in-namespace deploy rights; see the
RBAC notes in the steps section above for why it is enumerated rather than
wildcarded.

## Triggering pipelines from a GitLab issue comment

Beyond the manual `tkn pipeline start` path shown in the DAG sections, you can
let a reviewer kick off a pipeline by **commenting a slash-command on a GitLab
issue**:

| Comment | Starts | Needs a decision? |
|---|---|---|
| `/remediate` | `agentic-cve-remediation` | yes — reads the six-field decision from the issue |
| `/generate-tests-unit` | `agentic-test-generation-unit` | no — only the repo coordinates |
| `/generate-tests-functional` | `agentic-test-generation-functional` | no — only the repo coordinates |
| `/generate-tests-integration` | `agentic-test-generation-integration` | no — only the repo coordinates |

All commands share a **single** EventListener, webhook, and Route — the wiring
lives in `triggers/agentic-issue-triggers.yaml` (EventListener with four
triggers + `gitlab`/`cel` interceptors + a TriggerBinding/TriggerTemplate
per command + RBAC + Route; the three `/generate-tests*` commands share one
TriggerBinding, since nothing in it is command-specific). Each trigger's `cel`
`filter` matches exactly one command, so a comment only starts the pipeline it
names — each `/generate-tests-*` filter is a plain `startsWith` on the full
command name, so the three can never match each other's comments.

### `/remediate`

Kicks off `agentic-cve-remediation`.

**Where the decision comes from.** The six-field decision is read from the
**issue body**, where it sits inside an HTML-comment marker so it stays invisible
in rendered markdown. `agentic-cve-analysis` embeds the marker in every issue it
opens; on a hand-written issue, paste it in yourself:

```
<!-- cve-decision
SELECTED: "1"
CVE_ID: CVE-2024-12345
PACKAGE: com.example:widget
CURRENT_VERSION: 1.2.3
FIXED_VERSION: 1.2.4
JUSTIFICATION: High-severity RCE with a clean single-dependency bump.
-->
```

The six fields (identical names on the `agentic-cve-remediation` params):

| Field | Meaning |
|-------|---------|
| `SELECTED` | `"1"` if a CVE is to be remediated, `"0"` otherwise. Remediation's tail runs only on `"1"`. |
| `CVE_ID` | The CVE identifier to remediate. |
| `PACKAGE` | Maven coordinates (`groupId:artifactId`) of the dependency to bump. |
| `CURRENT_VERSION` | The currently-resolved (vulnerable) version. |
| `FIXED_VERSION` | The concrete version to bump to. |
| `JUSTIFICATION` | Why this CVE is being fixed (goes into the PR body). |

Issues opened by `agentic-cve-analysis` already embed this marker, so the whole
comment body is just the command on its own line:

```
/remediate
```

**Overriding from the comment.** A commenter can override **any** of the six
fields by putting YAML **or** JSON (no code fences) right after the command:

```
/remediate
FIXED_VERSION: 1.2.5
JUSTIFICATION: bump to the latest patch instead
```

```
/remediate {"FIXED_VERSION": "1.2.5"}
```

The `cel` interceptor parses both the issue marker and the comment, then merges
**comment > issue > default** field-by-field. Anything absent from both falls back
to a default; `SELECTED` defaults to `"1"` because a human explicitly asked to
remediate. If the merged `SELECTED` is `"0"`, the pipeline clones and then no-ops
(its tail is gated on `SELECTED == "1"`). Only comments whose first characters are
`/remediate`, on an **issue** (not an MR), and that pass the webhook token check
start a run.

### `/generate-tests-unit`

Kicks off `agentic-test-generation-unit` (add JUnit unit tests, run them, open a
PR). Unlike
`/remediate` it carries **no decision** — the comment is just the command on its
own line:

```
/generate-tests-unit
```

There's nothing to read from the issue body and nothing to override, so this
trigger uses a single `cel` interceptor that only checks the command and derives
`git-host` / `base-branch` from the payload. Only comments whose first characters
are `/generate-tests-unit`, on an **issue** (not an MR), that pass the webhook
token check, start a run.

### `/generate-tests-functional` and `/generate-tests-integration`

Same wiring as `/generate-tests-unit` (same EventListener, same shared
TriggerBinding; their own TriggerTemplates and cel filters). They kick off
`agentic-test-generation-functional` / `agentic-test-generation-integration`:
the agent evaluates whether new functional / integration tests are needed and
generates them per the matching agent skill (`test-generation-functional` /
`test-generation-integration`), the pipeline re-verifies, and the MR carries the
new tests plus any test-scoped `pom.xml` additions.

### Cluster setup for the issue-comment triggers

Everything the cluster needs, in order. Steps 1–2 are usually already true from
the [One-time setup](#one-time-setup); steps 3–5 are trigger-specific. All four
commands are served by the **same** EventListener and webhook, so this setup
enables them all at once — the only extra requirement for a given command is
that the Pipeline and Tasks it names are applied (step 2).

**1. Operators / interceptors (cluster-level).** The Red Hat OpenShift Pipelines
operator must be installed **with** the Tekton Triggers stack, which provides the
`gitlab` and `cel` **ClusterInterceptors** the EventListener calls:
```
oc get clusterinterceptors      # expect at least: cel, gitlab
```

**2. The pipelines + their tasks must already be applied.** Each trigger only
creates a PipelineRun that references its Pipeline (`agentic-cve-remediation` for
`/remediate`, `agentic-test-generation-unit` for `/generate-tests-unit`,
`agentic-test-generation-functional` for `/generate-tests-functional`,
`agentic-test-generation-integration` for `/generate-tests-integration`); those
Pipelines and every Task they use must exist in the namespace (your normal
`oc apply` of `pipelines/` and `tasks/`). The test-generation tasks also need
their **agent-skill ConfigMaps** (`pipelines/config/agent-skills-test-generation-*.yaml`)
— a missing one fails the generation step loudly rather than letting the agent
run without its methodology. Apply only the pipeline(s) whose command you intend
to enable.

**3. Secrets & configs the run mounts** (in the pipeline namespace — the
`TriggerTemplate` wires these in, so the names must match or you override the
`tt.params` defaults):

| Name | Purpose |
|---|---|
| `gitlab-webhook-secret` (key `secretToken`) | Shared token the `gitlab` interceptor checks against GitLab's `X-Gitlab-Token`. |
| `git-auth` (Secret) | **Private repos only** — clone credentials. Not bound by either template by default (see the note at the end of this section); a public app repo needs none. |
| `scm-auth-secret` (Secret) | SCM token to open the MR (`api` scope on GitLab). |
| `scm-auth-gitops-secret` (Secret) | The gitops repository's own project token — what the gitops CD pipelines' `gitops-bump-image` pushes and merges with (`scm-secret-name` param). |
| `maven-settings` (Secret) | Maven `settings.xml` for the build — mirrors all resolution through the Artifactory `maven` virtual repo. A **Secret** (not a ConfigMap) because Artifactory OSS has anonymous access off, so the settings.xml embeds a `<server>` credential. The mirror URL is the in-cluster **Service** (`http://artifactory.artifactory.svc.cluster.local:8082/artifactory/maven`), not the public Route — see the route-timeout caveat below. See `secrets/maven-settings-secret.example.yaml`. |
| `ai-agent-config` + `ai-agent-secret` | AI backend config (as for the other pipelines). |

**4. Apply the trigger stack** (one file — ServiceAccount, RBAC, TriggerBinding,
TriggerTemplate, EventListener, Route). ⚠️ First edit the `ClusterRoleBinding`
subject namespace to match yours, and apply into that **same** namespace:
```
oc -n tssc-app-ci create secret generic gitlab-webhook-secret \
  --from-literal=secretToken=$(openssl rand -hex 20)          # or: create -f secrets/gitlab-webhook-secret.example.yaml after editing REPLACE_ME
oc -n tssc-app-ci apply -f triggers/agentic-issue-triggers.yaml
```

**5. Expose + register the webhook in GitLab.** Get the listener URL:
```
oc -n tssc-app-ci get route agentic-issue-commands -o jsonpath='https://{.spec.host}{"\n"}'
```
Then in the GitLab project **Settings → Webhooks → Add**: URL = the Route above,
**Secret token** = the value in `gitlab-webhook-secret`, and enable **Comment
events** (Note Hook). Leave SSL verification on (the Route is edge-terminated TLS).

**Verify before commenting:**
```
oc -n tssc-app-ci get eventlistener agentic-issue-commands          # ADDRESS populated
oc -n tssc-app-ci get pods -l eventlistener=agentic-issue-commands  # el-... pod Running
```
Use GitLab's webhook **Test → Comment events**, then watch the interceptor and the run:
```
oc -n tssc-app-ci logs deploy/el-agentic-issue-commands -f   # accept/reject + reason
oc -n tssc-app-ci get pipelineruns -l trigger=gitlab-issue -w        # a PipelineRun appears
```
Common failures: `interceptor ... not found` → the `ClusterRoleBinding` subject
namespace is wrong (step 4 caveat); a 401 / token mismatch → the GitLab **Secret
token** ≠ `gitlab-webhook-secret`; no run and no reject logged → the comment
didn't start with `/remediate`, or it was on an MR rather than an issue.

> **Debugging silent drops (`started`→`done`, no PipelineRun, no error in the EL
> log).** A `cel` interceptor that rejects or errors logs the reason in the
> **shared** core-interceptors service, *not* in the EventListener pod:
> ```
> oc -n openshift-pipelines logs deploy/tekton-triggers-core-interceptors --since=2m -f
> ```
> Two non-obvious `cel` gotchas cost real debugging time here, both baked into the
> trigger's layout now:
> - **Overlays within a single `cel` interceptor do not chain.** They're all
>   evaluated against the same starting `extensions` (empty), so an overlay can't
>   read one a sibling just set — you get `failed to evaluate: no such key: …`.
>   Extensions only become visible to the **next** interceptor, so a multi-step
>   merge must be split into a **sequence** of `cel` interceptors (this trigger
>   uses three: raw text → parsed maps → merged fields).
> - **The overlay `key` is relative to the extensions root — keep it bare.** Write
>   `key: issueRaw` (stored as `extensions.issueRaw`), **not**
>   `key: extensions.issueRaw`, which double-nests to `extensions.extensions.issueRaw`
>   and the next stage's `extensions.issueRaw` then can't find it. By contrast, the
>   `expression` and the `TriggerBinding` refs *do* use the `extensions.` prefix.

Both `TriggerTemplate`s bind a fresh `workspace` PVC per run and back
`maven-settings` with the **`maven-settings` Secret** (override `workspace-size` /
`scm-secret-name` if your names differ):

```yaml
- name: maven-settings
  secret:
    secretName: maven-settings
```

This routes every Maven invocation in the run through the **Artifactory `maven`
virtual repo**, which aggregates the `lightwell-remediated` / `lightwell-validated`
proxies alongside `maven-central`. That is not optional for these two pipelines:
both agentic flows end up building a tree that pins a Lightwell backport such as
`6.0.3.rhlw-00001`, and that coordinate does **not** exist on Maven Central — an
`emptyDir` lets the `maven` task generate a default `settings.xml` and the build
then fails with `Could not find artifact … in central` on the very version the
remediation just pinned.

It must be a **Secret**, not a ConfigMap, because Artifactory OSS has anonymous
access off, so `settings.xml` carries a `<server>` credential — see
`secrets/maven-settings-secret.example.yaml`. Create it *before* the first trigger
fires: a secret-backed workspace whose Secret is missing leaves the pod stuck in
`PodInitializing` forever (never an error, just hangs — the same trap as a missing
`git-auth` Secret, below).

```
oc -n tssc-app-ci create secret generic maven-settings \
  --from-file=settings.xml=./settings.xml
```

Note that the four AI tasks reach the mirror by a different route than the `maven`
task does. `ai-remediate-dependency` and `ai-generate-tests-unit` copy the workspace's
`settings.xml` to `~/.m2/settings.xml` at the top of their step, because the coding
agent composes its own `mvn` command lines and there is no way to add `-s` to them;
one file covers both the agent's calls and the task's own scratch verification
build. Both declare `maven-settings` *optional*, so a run without it still starts —
it logs a warning and then fails at resolution. Neither template binds `git-auth`: it's an
optional pipeline workspace, and a secret-backed workspace whose Secret is missing
leaves the clone pod stuck in `PodInitializing` forever (never an error, just
hangs), which can't be bound conditionally in a TriggerTemplate. A public app repo
clones fine without it; for a **private** repo, create a basic-auth Secret named
`git-auth` and add the binding back (a commented example sits in both templates).
`git-url`, `git-host`, and `base-branch` are derived from the webhook payload, so
the same triggers serve any project pointed at them.

### Linking the opened MR/PR back to the issue

When a run is started from an issue comment, the trigger also derives the issue's
project-scoped number (`body.issue.iid`, via an `issue_iid` cel overlay) and threads
it through to the PR task as `issue-iid` → `ISSUE_IID`. The `open-pr` / `open-pr-tests`
task then appends a `Related to #N` line to the MR/PR description. GitLab (and GitHub)
turn that `#N` into a **cross-reference**, so the opened MR shows up as a system note
**in the issue** — you can jump from the issue to its remediation/test MR and back.
`Related to` links **without** auto-closing the issue on merge; to auto-close instead,
change the line to `Closes #N` in the two PR tasks.

`ISSUE_IID` / `issue-iid` is **optional and defaults to empty**. It is populated
*only* by the issue-comment triggers — a run started manually (`tkn`/CLI) or by any
other means leaves it empty and the PR body carries no issue reference. So a PR is
tied to an issue **only** when the pipeline was triggered by that issue's comment.

> **Note on comment format:** put the override YAML/JSON **directly** after
> `/remediate` — don't wrap it in ```` ``` ```` code fences (the parser reads the
> raw text after the command). JSON works because it is valid YAML.

## Prerequisites

Everything below is assumed to be in place **before** the `## One-time setup`
commands. Items marked _(scan chain)_ are needed by **`agentic-cve-analysis`**
and **`ci-build-publish`** (the build → SBOM → RHTPA half); the AI/SCM items are
needed by whichever pipelines you run (`agentic-cve-analysis` uses the AI model
server; `agentic-cve-remediation` and the `agentic-test-generation-*` pipelines
additionally push a PR/MR). `agentic-cve-remediation` and the
`agentic-test-generation-*` pipelines do **not** need RHTPA or `tpa-secret`
(though `ci-build-publish`'s SBOM upload does — disable it with
`upload-sbom="false"` if RHTPA is down). The examples use the namespace
`tssc-app-ci` — substitute your own.

### Platform

| Requirement | Notes |
|-------------|-------|
| OpenShift 4.x _(scan chain)_ | Target cluster. |
| **OpenShift Pipelines** (Tekton) operator _(scan chain)_ | Provides `Task`/`Pipeline`/`PipelineRun` CRDs and the referenced cluster tasks (`git-clone`, `maven`, `build-container`/buildah, `verify-commit`). |
| **RHTPA 2.2.6** (Red Hat Trusted Profile Analyzer / Trustify) _(scan chain)_ | Reachable from the cluster, with its OIDC issuer. Its vulnerability data must be **populated** — see [RHTPA importers](#rhtpa-importers-populate-the-vulnerability-data). |
| **Trusted Artifact Signer** (TAS) — _optional_ | Only if you run with `verify-commit="true"`. Supplies Rekor/TUF/Fulcio; drives the `oidc-issuer`, `rekor-url`, `tuf-mirror`, `certificate-identity` params. Left `"false"` by default. |
| Egress | RHTPA importers reach `access.redhat.com` (Red Hat SBOM/CSAF/OSV data); the AI provider endpoint (`api.anthropic.com:443` by default, or your gateway/Bedrock/Vertex/OpenAI-compatible host); the SCM host (`gitlab.com`/`github.com` or your on-prem SCM); and the image registry. Image **builds** additionally pull from `archive.apache.org`, `rpm.nodesource.com`, `gitlab.com`, `github.com`. |

### Secrets & ConfigMaps (in the pipeline namespace)

| Object | Kind | Required when | Keys / contents |
|--------|------|---------------|-----------------|
| `tpa-secret` | Secret | `agentic-cve-analysis` and `ci-build-publish` (SBOM upload) | `bombastic_api_url`, `oidc_issuer_url`, `oidc_client_id`, `oidc_client_secret`. Consumed by the RHTPA tasks **and** the importer Job. (Name overridable via `trustification-secret-name`.) |
| `ai-agent-config` | ConfigMap | all pipelines | The single backend switch. Apply `config/ai-agent-config.yaml`; pick `AI_PROVIDER`/`AI_AGENT`/`AI_MODEL` (+ `AI_BASE_URL` for gateway/openai). |
| `ai-agent-secret` | Secret | all pipelines | Provider credential(s) for the chosen `AI_PROVIDER` (e.g. `ANTHROPIC_API_KEY`). From `secrets/ai-agent-secret.example.yaml`. |
| `scm-auth-secret` | Secret | analysis (issues) + remediation + test-gen (PR step) | `username` + `token` with push + PR/MR-create scope, and issue-create for analysis (see below). From `secrets/scm-auth-secret.example.yaml`. (Name overridable via `scm-secret-name`.) |
| `scm-auth-gitops-secret` | Secret | dev/qa/gitops-cd-prod | The gitops repository's own project access token — the `scm-secret-name` default of all three gitops CD pipelines. Separate from `scm-auth-secret` because a GitLab project bot cannot be shared across projects. From `secrets/scm-auth-gitops-secret.example.yaml`. |

#### SCM token scopes (`scm-auth-secret`)

The `open-pr` / `open-pr-tests` tasks use this token for exactly two privileged
operations: a `git push` of the branch (`rhtpa/*` for remediation, `ai-tests/*`
for test-gen) over HTTPS, and a `glab mr create` /
`gh pr create` API call. (The initial repo **clone** uses a *different* secret —
the `git-auth` workspace — so this token does not need clone/read access to the
whole instance.)

**GitLab** — grant the minimum:

| Scope | Why |
|-------|-----|
| `api` | Required for `glab mr create` — MR creation is a write-API call and GitLab has no narrower per-feature scope. |
| `write_repository` | Required to `git push` the branch over HTTPS. (`api` often permits push too, but include this to avoid version-specific edge cases.) |

- **Role:** the token identity needs at least **Developer** on the target
  project (enough to push a non-protected `rhtpa/*` or `ai-tests/*` branch and
  open an MR). Use **Maintainer** only if that branch namespace is protected.
- **Token type:** a **Project Access Token** scoped to the one repo (bot identity,
  Developer role, `api` + `write_repository`) is the least-privilege choice and
  auto-expires. A Personal Access Token works but reaches every project the user
  can. Create it on the same GitLab instance as `GIT_HOST`.
- **`username` key:** leave it as `oauth2` — GitLab accepts `oauth2:<token>` for
  HTTPS push, and `glab` authenticates via the token regardless of username.

**GitHub** — a fine-grained token with **Contents: read & write** (push the
branch), **Pull requests: read & write** (open the PR), and — for
`agentic-cve-analysis` — **Issues: read & write** (open issues), scoped to the
target repo. A classic token needs the `repo` scope. (On GitLab the `api` scope
already covers issue creation, so no extra scope is needed there.)

### Workspaces / PVCs

The `PipelineRun` must bind these workspaces (declared on the pipeline):

| Workspace | Backing | Purpose |
|-----------|---------|---------|
| `workspace` | PVC (RWO/RWX) | Source, SBOMs, and the RHTPA reports the AI branch reads. |
| `maven-settings` | ConfigMap/Secret with `settings.xml` | Maven repo/mirror config for `package` + `re-run-tests`. |
| `git-auth` | basic-auth Secret | Clone credentials for `git-clone`. |
| `gitops-auth` | Secret | As required by your base pipeline. |

### Container images (AI branch)

The agent runtime ships in **two flavors**, one per `AI_AGENT` backend — build the
one matching your configured backend (or both, if you switch between them):

| Image | `AI_AGENT` | Contains |
| --- | --- | --- |
| `ai-agent-maven-claude` | `claude-code` (default) | Node.js + Claude Code |
| `ai-agent-maven-aider` | `aider` | Python 3.11 + aider |

Both are built on `ubi9/ubi-minimal` + `java-17-openjdk-devel` (leaner than the
`ubi9/openjdk-17` builder image — the S2I scripts and bundled Maven are dropped)
and both carry JDK17 + Maven + git/glab/gh. Point `agent-image` at whichever
matches `AI_AGENT`; build+push the CVE-analysis `ai-python-image` as well. Images
default to `quay.io/REPLACE_ME/...:v1.0.0`. Commands are in
[One-time setup](#one-time-setup) below.

> **Why the agent image bundles `git`/`glab`/`gh`:** besides the code-editing
> tasks, `open-pr` also runs on the agent image (the pipeline sets its `GIT_IMAGE`
> to `agent-image`). The default git-init image ships `git` **only** — no
> `glab`/`gh` — so `open-pr` would fail its `glab mr create` / `gh pr create` step
> on it. Running it on the agent image gives it all three tools without a separate
> image. (This is why `agent-image` must resolve for a full remediation run even
> though `open-pr` doesn't edit code.)

### RHTPA importers (populate the vulnerability data)

RHTPA ships with an importer set seeded at install, but the two heavyweight Red
Hat importers are **disabled by default** because their first ingest is large and
slow. Until they run, `/purl/recommend` returns nothing (the recommend catalog is
empty), which is why the pipeline treats the **analyze** report as authoritative
and the **recommend** report as supplemental.

| Importer | Default | Provides | Needed for |
|----------|---------|----------|------------|
| `osv-github` | **enabled** | Upstream OSV/GHSA advisories | `analyze` findings (CVE + severity) |
| `cve` | **enabled** | NVD CVE records | `analyze` findings |
| `redhat-csaf` | **disabled** | Red Hat CSAF/VEX (fix status for Red Hat products) | Richer advisory/fix context |
| `redhat-sboms` | **disabled** | Red Hat SBOM rebuild catalog | Populating `/purl/recommend` (the supplemental signal) |
| `quay-redhat-user-workloads` | disabled | — | Not used by this pipeline |

**Enabling is a runtime setting in Trustify's database managed via the
`/api/v2/importer` REST API — RHTPA 2.2.6 does not expose it as an operator CR
field.** So the closest thing to "declarative" is an **idempotent Job** that
applies the API calls; commit it and apply it with the rest of your manifests (or
run it as an Argo CD sync hook / one-off `oc apply`):

```
oc -n tssc-app-ci apply -f config/rhtpa-enable-importers-job.yaml
oc -n tssc-app-ci logs -f job/rhtpa-enable-importers
```

The Job (`config/rhtpa-enable-importers-job.yaml`) reads `tpa-secret`, flips each
importer's nested `disabled` flag to `false`, and forces an immediate run. It is
safe to re-run (re-apply after `oc delete job rhtpa-enable-importers`); set the
`IMPORTERS` env in the manifest to change which importers it targets.

<details>
<summary>Equivalent manual API calls (for debugging)</summary>

```bash
# token helper (client-credentials; tokens are short-lived, re-mint per call)
auth() {
  ep=$(curl -sf "${OIDC_ISSUER_URL%/}/.well-known/openid-configuration" | jq -r .token_endpoint)
  echo "Authorization: Bearer $(curl -sf --user "$OIDC_CLIENT_ID:$OIDC_CLIENT_SECRET" \
        -d grant_type=client_credentials "$ep" | jq -r .access_token)"
}

# 1. list importers + their REAL state (disabled lives under the type key)
curl -sf -H "$(auth)" "$RHTPA_URL/api/v2/importer" \
  | jq -r '.[] | "\(.name)\tdisabled=\(.configuration|to_entries[0].value.disabled)\tlastRun=\(.lastRun)\tlastError=\(.lastError)"'

# 2. enable (flip the NESTED disabled, then PUT the whole configuration back)
name=redhat-sboms
curl -sf -H "$(auth)" "$RHTPA_URL/api/v2/importer/$name" | jq '.configuration' \
 | jq '(to_entries[0].key) as $k | .[$k].disabled=false' \
 | curl -sf -X PUT -H "$(auth)" -H 'Content-Type: application/json' \
        --data @- "$RHTPA_URL/api/v2/importer/$name"

# 3. force an immediate run
curl -sf -X POST -H "$(auth)" "$RHTPA_URL/api/v2/importer/$name/force"

# 4. poll: state while running; the /report .items array fills in on completion
curl -sf -H "$(auth)" "$RHTPA_URL/api/v2/importer/$name" | jq '{state,lastRun,lastSuccess,lastError}'
curl -sf -H "$(auth)" "$RHTPA_URL/api/v2/importer/$name/report" | jq '{total, first: .items[0]}'
```

Gotchas that bite: the importer name is `redhat-sboms` (plural); `disabled` is
nested under the type key (`.configuration.sbom.disabled`), so setting a
top-level `.disabled` silently does nothing and, because `PUT` replaces the whole
config, can even re-disable it; and `force` on a still-disabled importer is a
no-op. Verify `disabled=false` **before** forcing.
</details>

**Timing:** `redhat-sboms` is the long pole — tens of GB, commonly **hours** for
the first run (`numberOfItems` climbs across report entries via `continuation`).
Treat it as done only when the importer shows a non-null `lastSuccess` (a non-null
`lastError` such as `Import aborted` means it failed — usually a transient
network/pod-restart during the large fetch; re-run the Job). Once `redhat-sboms`
succeeds, re-test `/purl/recommend` for a Red Hat-shipped component to confirm the
catalog is populated.

### Loading a single advisory into RHTPA (no importer)

The importers above are bulk feeds bound to remote **sources** — `osv-github`
clones a git repository, `cve` the CVE List repo. None of them will pick up one
hand-written demo record, and a flat HTTP directory of OSV JSON (an Artifactory
generic repo, say) is **not** a valid importer source. For one-off documents use
the ad-hoc upload endpoint instead, via `ops/rhtpa-upload-advisory.sh`:

```sh
ops/rhtpa-upload-advisory.sh -l source=lightwell data/osv/LW-DEMO-0012.json
ops/rhtpa-upload-advisory.sh --verify LW-DEMO-0012     # what's ingested, all versions
ops/rhtpa-upload-advisory.sh --delete <uuid>           # delete + wait for it to land
```

(To load the whole Lightwell dataset rather than one record, use
`ops/rhtpa-load-lightwell-data.sh` — see
[Lightwell remediation data](#lightwell-remediation-data) below.)

It reads `tpa-secret` from `-n/--namespace` (default `tssc-app-ci`), mints the
same client-credentials token the `upload-sbom-to-rhtpa` task uses, and
`POST`s to `/api/v2/advisory?format=osv&labels.<k>=<v>` (`format` also accepts
`csaf`, `cve`, `spdx`, `cyclonedx`, …).

Three RHTPA behaviours the script exists to guard against — all verified against
RHTPA 2.2.6 on cluster-6jnws:

- **An OSV record with no `aliases` ingests but stays inert.** Trustify takes the
  linked vulnerability from the `aliases` (the CVE), *not* from the document's own
  `id`. Without one you get HTTP 201, a downloadable document, and
  `"vulnerabilities": []` — it never appears in `/api/v2/vulnerability/analyze`, so
  `rhtpa-vulnerability-analysis` ignores it. The script refuses such a file unless
  you pass `--allow-inert`. It also warns when a Maven `package.purl` disagrees
  with `package.name` (a mismatched purl matches nothing in any SBOM).
- **Re-uploading the same document id versions, it does not replace.** The copy
  with the latest `modified` is current; older ones are deprecated, and
  `GET /api/v2/advisory` defaults to `deprecated=Ignore`. A corrected re-upload
  that forgets to bump `modified` is therefore invisible to search while still
  fetchable by uuid — "it uploaded but I can't find it". The script warns when the
  version it just pushed did not become current; `--verify` lists every version.
- **`DELETE /api/v2/advisory/{uuid}` returns HTTP 504 but succeeds
  asynchronously** (~1–2 min), because the OpenShift router times out before
  Trustify finishes. Don't retry on the 504 — poll `GET .../{uuid}` for a 404,
  which is what `--delete` does.

### Lightwell remediation data

The demo ships two **backport** builds — dependencies that keep their base
version and add a vendor suffix carrying the patch:

| Vulnerable GAV | Backport | CVEs |
|----------------|----------|------|
| `org.apache.commons:commons-lang3:3.14.0` | `3.14.0.rhlw-00001` | CVE-2025-48924 |
| `com.fasterxml.woodstox:woodstox-core:6.0.3` | `6.0.3.rhlw-00001` | CVE-2022-40152 … -40156 |

For a backport to be *supported* end to end it has to do two separate things,
and each needs its own piece of data:

1. **Be recommended** as the fix for its CVEs. `rhtpa-remediation-report`'s
   fix-version scan walks every *known version* of an affected base PURL, so the
   backport must be a known version — which it only becomes once some ingested
   document mentions it. That is what the one-component CycloneDX files in
   `data/sbom/` are for.
2. **Scan clear** once applied. The OSV records in `data/osv/` each alias one
   real CVE and declare `ranges[].events[].fixed = <X.Y.Z.rhlw-00001>`; Trustify
   turns that event into `status: fixed` for the remediated PURL.

Load and verify both halves with one command:

```sh
ops/rhtpa-load-lightwell-data.sh            # load, then verify
ops/rhtpa-load-lightwell-data.sh --verify   # verify only, change nothing
ops/rhtpa-load-lightwell-data.sh --purge    # delete what a previous load created
```

`--verify` prints, per remediated PURL, the base PURL's known versions (goal 1)
and every CVE that still range-matches it along with the advisory that clears it
(goal 2). It exits non-zero on any `[FAIL]`.

To add another backport: drop an OSV record and a catalog SBOM into `data/`, add
the `"<base purl>|<remediated purl>"` pair to `PAIRS` in the script, and re-run
it. Keep the `LW-DEMO-001x` id range clear of the synthetic workshop seeds in
`automation/gitops/components/lightwell-repo/files/seed/`, which already use
`LW-DEMO-0001` and `-0002`.

#### Why the pipeline needs a VEX suppression pass

`POST /api/v2/vulnerability/analyze` is **pure version-range matching, and it
only ever returns the `affected` bucket** — `fixed` and `not_affected` never
appear in its response, and it ignores purl qualifiers. That is fine for a
straight upgrade (`woodstox-core@6.4.0.redhat-00003` falls outside the upstream
`< 6.4.0` range, so analyze returns `{}` for it) but it is *wrong* for a
backport: `6.0.3.rhlw-00001` still sorts inside `[0, 6.4.0)`, so analyze keeps
reporting all five CVEs against it no matter what remediation data is loaded.
No amount of VEX or CSAF changes this.

`GET /api/v2/purl/<url-encoded purl>` is the only endpoint that exposes
fixed/not_affected. `rhtpa-vulnerability-analysis` therefore makes a second pass
over it for each affected PURL and drops the pairs an advisory explicitly
clears, keeping them in `.suppressed` so the report names *which* advisory
cleared *what* instead of silently losing findings.

The two endpoints are **not** interchangeable, and the trap runs the other way
too: `/purl/{purl}` is scoped to the *exact* purl string, so
`woodstox-core@6.0.3.redhat-00001` unqualified carries no statuses at all (the
real ones hang off its `?repository_url=…&type=jar` variant) and naively reading
"no statuses" as "clean" will recommend a still-vulnerable rebuild. The
fix-version scan in `rhtpa-remediation-report` guards against this by using
batched `analyze` as the authoritative range signal and explicit purl statuses
only as an override. `/purl/recommend` is not relied on at all — its candidate
selection is opaque and it offered neither the backport nor the genuinely clean
`6.4.0.redhat-00003`.

The relevant task knobs:

| Task | Param / result | Purpose |
|------|----------------|---------|
| `rhtpa-vulnerability-analysis` | `SUPPRESS_VEXED` (`"true"`) | Honour fixed/not_affected. Set `"false"` to see raw analyze output. |
| | `MAX_VEX_LOOKUPS` (`"300"`) | Cap on per-PURL status lookups; beyond it the rest are left unsuppressed. |
| | `SUPPRESSED_COUNT` (result) | Number of (PURL, CVE) pairs suppressed. |
| `rhtpa-remediation-report` | `VULNERABILITY_REPORT_PATH` (`""`) | Scope the fix-version scan to the PURLs that actually have findings; defaults to `<workspace>/rhtpa/vulnerabilities.json`. |
| | `FIX_SCAN_EXCLUDE_PURL_TYPES` (`"rpm,deb,apk,oci"`) | Leave OS-level packages out of the fix-version scan. Set to `""` to scan every type. |
| | `MAX_FIX_SCAN_PURLS` (`"60"`), `MAX_VERSIONS_PER_PURL` (`"40"`) | Bound the sibling-version fan-out. |
| | `FIX_SCAN_BATCH_SIZE` (`"50"`) | PURLs per fix-scan `analyze` call. Smaller than `BATCH_SIZE` on purpose — see below. |
| | `FIX_VERSION_COUNT` (result) | Number of (PURL, CVE) pairs a fix version was found for. |
| both | `HTTP_RETRIES` (`"3"`), `HTTP_MAX_TIME` (`"300"` report / `"180"` analysis) | Retry budget and per-request timeout. The report needs the larger budget because `/purl/recommend` alone can take ~167 s. |

`.fix_versions` from that report — ordered backports first, each entry carrying
`version`, `purl`, `cleared_by` and `backport` — is what `ai-analyze-cves`
consumes as its authoritative candidate list, and its default `POLICY_CONTEXT`
tells the model to prefer a backport over any version bump.

#### Keeping the analyze fan-out small, and never trusting a response blindly

`analyze` returns the **full advisory detail for every (PURL, CVE) pair**, so its
responses get large fast. Scanning every sibling version of every affected PURL
on the reference app meant **791 candidates in 7 batches and 72 MB of response**,
with single bodies of 25 MB and 30 s of server time — RHTPA logs
`slow statement: execution time exceeded alert threshold` on the resulting
`UNION ALL` queries. One of those transfers was cut off mid-body; because the
loop appended curl's stdout straight onto an accumulator with `|| true`, the
truncated fragment stayed in the file, the next batch was appended behind it,
and `jq -s` died with a parse error (**exit 5**) that took the whole step down.

Two changes keep that from recurring:

- **`FIX_SCAN_EXCLUDE_PURL_TYPES`** drops `rpm`/`deb`/`apk`/`oci` from the scan.
  Nothing in the application source pins an OS package, so they were never a
  remediation the AI tasks could act on — but they were 698 of those 791
  candidates. The same run is now **109 candidates in 3 batches and 1.2 MB**.
- **Every RHTPA call goes through a `fetch_json` helper** that writes its output
  file only when curl exited 0, the status was 2xx, *and* the body parses as
  JSON and is not a bare `null` (see the `jq empty` note below). Anything else
  warns and returns non-zero, so a caller that skips the
  failure skips one PURL instead of corrupting its input. Note the deliberate
  absence of `--fail-with-body`: that flag writes the server's error document to
  stdout, which is the other way a `{"error": …}` body used to reach jq. Writing
  through `--output` also means a retry *truncates* the file rather than
  appending a second copy of the body behind a half-written one.

`fetch_json` owns its retry loop rather than passing curl `--retry`, because
without `--fail-with-body` curl treats a **504 as a perfectly successful
transfer** and would never retry it. It retries transport failures, 408, 429 and
any 5xx with linear backoff, and re-checks the token on each attempt; other 4xx
are a settled answer and return immediately.

> **Validate with `jq empty`, never `jq -e .`.** RHTPA answers
> `GET /api/v2/purl/{purl}` for a PURL it has never ingested with **HTTP 200 and
> a body of literal `null`** — four bytes, perfectly valid JSON, not a 404. But
> `jq -e` sets **exit 1 when the output is null or false**, so an `-e`-based
> validator reads that as a corrupt body. The fix scan enumerates speculative
> `.redhat-000NN` versions, so *most* of its lookups are misses: every one of
> them burned four attempts with backoff and was then dropped from the scan,
> producing screens of `HTTP 200 with a body that is not valid JSON (4 bytes)`.
>
> | body | `jq -e .` | `jq empty` |
> |---|---|---|
> | `{"a":1}` | 0 | 0 |
> | `null` | **1** | 0 |
> | `{bad` | 5 | 5 |
>
> `fetch_json` now validates with `jq empty` and treats a top-level `null` as a
> quiet miss: no retry, no warning, nothing counted against `FETCH_FAILURES` —
> the same handling as a quiet 404. Callers already read "no answer" as "nothing
> to say about this PURL", which is exactly what a `null` means.

> **Infrastructure caveat — the 30 s route timeout.** The OpenShift route in
> front of RHTPA has no `haproxy.router.openshift.io/timeout` annotation, so the
> router's default `timeout server 30s` applies. When HAProxy fires first the
> client gets a **504 even though RHTPA logs a 200** — runs have died on
> `curl: (22) The requested URL returned error: 504` on the very first recommend
> batch.
>
> For `/vulnerability/analyze` this is a tail problem that retries and smaller
> batches make survivable. For `/purl/recommend` it is fatal and unconditional.
> Measured against a *healthy* server, bypassing the router via
> `https://server.trusted-profile-analyzer.svc.cluster.local`:
>
> | PURLs per recommend call | server time | via route |
> |---|---|---|
> | 25 | 106 s | 504 |
> | 128 | 167 s | 504 |
>
> That is ~4 s per PURL with only mild economy of scale, so **shrinking
> `BATCH_SIZE` makes the total worse, not better** — fewer PURLs per call, but
> more calls, each still over 30 s. Recommend simply cannot complete through a
> 30 s proxy at any batch size.
>
> The fix is to annotate the Ingress — not the Route. Route `server-k9h8n` is
> generated by OpenShift's ingress-to-route controller with an `ownerReference`
> to Ingress `trusted-profile-analyzer/server`; annotating the Route directly is
> **silently stripped within seconds**. Annotate the Ingress and OpenShift
> copies it down:
>
> ```sh
> oc -n trusted-profile-analyzer annotate ingress server \
>   haproxy.router.openshift.io/timeout=300s --overwrite
> ```
>
> Both TPA Argo applications run `syncPolicy.automated.selfHeal: true`, so a
> live `oc annotate` is a stopgap that Argo reverts on its next reconcile. The
> durable change belongs in the GitOps repo, not here. Keep `HTTP_MAX_TIME` at
> or below whatever this is set to — there is no point waiting longer than the
> proxy will.
>
> **Related: the postgres CPU limit.** `tpa-postgresql` is capped at `250m` CPU
> / `1Gi` memory by the `tpa-prerequisites` Helm chart, and sits pinned at
> ~249m. When it saturates, its readiness probe (a `psql -c 'SELECT 1'` with
> `timeoutSeconds: 1`) times out, the pod leaves the Service endpoints, the TPA
> server's `/health/ready` starts returning 500, and the router answers **503 to
> everything**. The node itself is at ~8 % CPU, so this is self-inflicted by the
> limit. It is also the likeliest reason recommend costs 4 s per PURL; raising
> the limit should pull the latencies above down with it.

> **The same 30 s timeout bites Artifactory — with a different signature.** The
> `artifactory` route also ships with no `haproxy.router.openshift.io/timeout`,
> and a cold build is more exposed than it looks: the scratch copy starts from an
> empty local repo and pulls hundreds of artifacts, and every one Artifactory has
> not cached it fetches from Maven Central *while holding the client connection
> open*. Measured through the route, a cold fetch scales with artifact size — 1 MB
> in 1.9 s, 5 MB in 9.4 s, 16 MB in **21.3 s**, already 70 % of the budget. A
> burst crosses 30 s, HAProxy kills the connection, and Maven reports it not as a
> 504 but as
>
> ```
> Could not transfer artifact org.codehaus.plexus:plexus-utils:jar:3.0.24
>   from/to artifactory (https://artifactory-artifactory.apps.<domain>/artifactory/maven):
>   artifactory-artifactory.apps.<domain>:443 failed to respond
> ```
>
> — named after whichever request happened to be in flight, typically some
> innocent 247 KB transitive rather than the slow artifact that actually consumed
> the budget. Re-running "fixes" it only because the first attempt warmed the
> cache, which is what makes this look intermittent.
>
> The fix is to skip the router entirely: `maven-settings` points the mirror at
> the in-cluster Service,
> `http://artifactory.artifactory.svc.cluster.local:8082/artifactory/maven`. No
> proxy in the path, no 30 s cap, no TLS handshake, and no cluster hostname baked
> into the Secret. Use the route only from outside the cluster (a manual run from
> a laptop, the workshop UI), and annotate it first — unlike RHTPA's, this Route
> has **no `ownerReferences`**, so it is not controller-generated and a direct
> annotation sticks:
>
> ```sh
> oc -n artifactory annotate route artifactory \
>   haproxy.router.openshift.io/timeout=300s --overwrite
> ```

The two tasks then diverge on what a failed batch *means*. In
`rhtpa-remediation-report` a dropped batch only shrinks the candidate list, so it
warns and carries on — a fix version is only ever offered on a response that
actually arrived. In `rhtpa-vulnerability-analysis` a dropped batch would report
unchecked PURLs as clean, a silent false negative that would let a vulnerable
build through the Conforma gate, so **it fails the TaskRun instead**.

Tokens are re-minted on a timer, too. RHTPA issues client-credentials tokens with
`expires_in: 300`, and the per-PURL loops run longer than that: one run's VEX pass
lost its last **34 of 85** lookups to 401s that the skip-and-continue logic
swallowed silently. Both tasks now refresh at 200 s, and the VEX pass reports how
many lookups failed so a degraded run is visible rather than merely quieter.

## One-time setup

1. **Build & push the images**, then set the pipeline params (or edit the
   defaults) `agent-image` and `ai-python-image`. Build the agent flavor matching
   your `AI_AGENT` (or both):
   ```
   # Claude Code flavor (AI_AGENT=claude-code, the default):
   podman build --platform linux/amd64 -t quay.io/<org>/ai-agent-maven-claude:v1.0.0 images/ai-agent-maven-claude && podman push quay.io/<org>/ai-agent-maven-claude:v1.0.0
   # aider flavor (AI_AGENT=aider):
   podman build --platform linux/amd64 -t quay.io/<org>/ai-agent-maven-aider:v1.0.0  images/ai-agent-maven-aider  && podman push quay.io/<org>/ai-agent-maven-aider:v1.0.0
   # CVE-analysis runtime:
   podman build --platform linux/amd64 -t quay.io/<org>/ai-python:v1.0.0            images/ai-python             && podman push quay.io/<org>/ai-python:v1.0.0
   ```
   Set `agent-image` to the `-claude` or `-aider` reference to match `AI_AGENT`.

2. **Create the AI backend Secret** in `tssc-app-ci` from the example (fill in a
   real key; do not commit it):
   ```
   oc -n tssc-app-ci create -f secrets/ai-agent-secret.example.yaml   # after editing REPLACE_ME
   ```

3. **Apply the ConfigMap** (this is where you pick the provider/model):
   ```
   oc -n tssc-app-ci apply -f config/ai-agent-config.yaml
   ```

4. **Create the SCM Secret** with a token that can push a branch and open a
   PR/MR (GitLab: `api` + `write_repository`; GitHub: Contents + Pull requests
   write):
   ```
   oc -n tssc-app-ci create -f secrets/scm-auth-secret.example.yaml   # after editing REPLACE_ME
   ```

5. **Apply the tasks + agent-skill ConfigMaps + pipelines** (apply everything,
   or just the ones you use):
   ```
   oc -n tssc-app-ci apply -f tasks/
   oc -n tssc-app-ci apply -f config/agent-skills-test-generation-unit.yaml
   oc -n tssc-app-ci apply -f config/agent-skills-test-generation-integration.yaml
   oc -n tssc-app-ci apply -f config/agent-skills-test-generation-functional.yaml
   oc -n tssc-app-ci apply -f pipelines/agentic-cve-analysis.yaml
   oc -n tssc-app-ci apply -f pipelines/agentic-test-generation-unit.yaml
   oc -n tssc-app-ci apply -f pipelines/agentic-test-generation-functional.yaml
   oc -n tssc-app-ci apply -f pipelines/agentic-test-generation-integration.yaml
   oc -n tssc-app-ci apply -f pipelines/agentic-cve-remediation.yaml
   oc -n tssc-app-ci apply -f pipelines/ci-build-publish.yaml
   oc -n tssc-app-ci apply -f pipelines/gitops-cd-dev.yaml
   oc -n tssc-app-ci apply -f pipelines/gitops-cd-prod.yaml
   oc -n tssc-app-ci apply -f pipelines/gitops-cd-qa.yaml
   oc -n tssc-app-ci apply -f pipelines/test-image-functional.yaml
   oc -n tssc-app-ci apply -f pipelines/test-image-integration.yaml
   ```

   > The `test-image-*` pipelines additionally need the
   > `ephemeral-test-namespace-lifecycle` ClusterRole/ClusterRoleBinding —
   > it ships inside `tasks/create-test-namespace.yaml`, so the
   > `oc apply -f tasks/` above already created it.

6. **Egress:** the cluster must allow the selected provider's endpoint
   (`api.anthropic.com:443` for the default `anthropic` provider; your gateway /
   Bedrock / Vertex endpoint otherwise) plus `gitlab.com`/`github.com` release
   downloads at image-build time.

## Turning it on

There is no single on/off gate anymore — you **start whichever pipeline** does the
job. A typical CVE run is two steps: `agentic-cve-analysis` scans and opens one
issue per fixable CVE, then you comment
[`/remediate`](#triggering-pipelines-from-a-gitlab-issue-comment) on the issue
worth fixing (or review the issues and let them sit). `ci-build-publish` runs on
every merge to the application repository and promotes to dev on its own;
`gitops-cd-prod`/`gitops-cd-qa` are human-started. The
`agentic-test-generation-*` pipelines run independently, from their own issue
comments. The `test-image-*` pipelines are started with the image that earned
the evidence (usually the tag dev just rolled) and an issue to comment on.

The pipelines that open a PR/MR (`agentic-cve-remediation`,
`agentic-test-generation-*`) need the SCM params set on the PipelineRun (or in the
PaC template):

```yaml
params:
  - name: git-host
    value: gitlab-gitlab.apps.cluster.example.com
  - name: scm-provider
    value: gitlab            # or github
  - name: base-branch
    value: main
```

Optional (on `agentic-cve-analysis`): override `ai-remediation-policy` (free-form
CVE-prioritization policy for the AI) and/or `conforma-policy-configuration` (an
EC policy source; empty
uses the severity fallback keeping analyze findings at/above `high`). The fallback
does **not** require a structured fixed version — analyze exposes the fix only as
free text in the CVE title/description, so `ai-analyze-cves` resolves the concrete
fixed version from that prose (with `fixed_version_hints` as candidates).

## Swapping the AI backend (pluggable)

The backend is abstracted so different AI implementations plug in **without
touching task YAML**. Two layers:

### 1. Provider/model/creds — ConfigMap + Secret

`config/ai-agent-config.yaml` is the single switch, with two independent knobs.

**`AI_PROVIDER`** — the wire protocol for the reasoning call (`ai-analyze-cves`)
and Claude Code auth:

| `AI_PROVIDER` | Extra ConfigMap keys | Secret keys | Notes |
|---------------|----------------------|-------------|-------|
| `anthropic` (default) | — | `ANTHROPIC_API_KEY` | Direct api.anthropic.com |
| `gateway` | `AI_BASE_URL` | `ANTHROPIC_AUTH_TOKEN` (or key) | Any Anthropic-compatible gateway/proxy |
| `bedrock` | `AWS_REGION` | AWS creds | Model auto-prefixed `anthropic.` |
| `vertex` | `VERTEX_PROJECT_ID`, `VERTEX_REGION` | GCP creds | |
| `openai` | `AI_BASE_URL` | `OPENAI_API_KEY` | Any OpenAI-compatible endpoint — **gpt-oss, IBM Granite** via vLLM / RHOAI / Ollama / watsonx |

**`AI_AGENT`** — which coding-agent CLI drives the file-editing tasks
(`ai-generate-tests-unit`, `ai-remediate-dependency`):

| `AI_AGENT` | Use with | Runtime |
|------------|----------|---------|
| `claude-code` (default) | `AI_PROVIDER` anthropic/gateway/bedrock/vertex | Claude Code headless (Anthropic protocol only) |
| `aider` | `AI_PROVIDER=openai` | aider (litellm) — drives gpt-oss / Granite / any OpenAI-compatible model |

`AI_MODEL` (default `claude-opus-5`) and `AI_EFFORT` (default `high`) are honored
across tasks. Each task reads these via `envFrom` and translates them to the
correct client/env: Claude Code → `CLAUDE_CODE_USE_BEDROCK`/`_USE_VERTEX`/
`ANTHROPIC_BASE_URL`/`ANTHROPIC_MODEL`; aider → `--model` (`openai/<AI_MODEL>` if
unprefixed) + `OPENAI_API_BASE`/`OPENAI_API_KEY`; Python analysis task
(`ai-analyze-cves`) →
`AnthropicBedrockMantle`/`AnthropicVertex`/`base_url` or the `openai` SDK's
Chat Completions (strict `json_schema`, falling back to `json_object`).

### Running gpt-oss or IBM Granite

Point `AI_BASE_URL` at your model's OpenAI-compatible `/v1` endpoint (a vLLM or
Red Hat OpenShift AI serving runtime, Ollama, or watsonx), then:

```yaml
# config/ai-agent-config.yaml  — gpt-oss example
data:
  AI_PROVIDER: "openai"
  AI_AGENT:    "aider"
  AI_MODEL:    "gpt-oss-120b"                       # aider uses openai/gpt-oss-120b
  AI_BASE_URL: "http://vllm-gpt-oss.my-ns.svc:8000/v1"
```

```yaml
# config/ai-agent-config.yaml  — IBM Granite example
data:
  AI_PROVIDER: "openai"
  AI_AGENT:    "aider"
  AI_MODEL:    "granite-3.3-8b-instruct"
  AI_BASE_URL: "http://granite.my-ns.svc:8000/v1"
```

Then set `OPENAI_API_KEY` in `ai-agent-secret` (use any placeholder for servers
that don't validate it, e.g. a bare vLLM/Ollama deployment). For Ollama or
watsonx served natively (not openai-compat), set `AI_MODEL` to the full litellm
string (`ollama_chat/granite3.3:8b`, `watsonx/ibm/granite-3-8b-instruct`) and add
that provider's own env key (`OLLAMA_API_BASE`, `WATSONX_URL`, …) to the
ConfigMap — `envFrom` passes any extra keys straight through.

Egress: allow the model endpoint host instead of (or in addition to)
`api.anthropic.com:443`. Switching to `AI_AGENT=aider` means using the
`ai-agent-maven-aider` image (Python + aider) instead of `ai-agent-maven-claude`
(Node + Claude Code) — set `agent-image` accordingly. The CVE-analysis Python
image bundles both the Anthropic and `openai` SDKs, so it needs no change to
switch models.

### 2. Runtime — swappable images with a documented contract

To plug in a *different agent implementation entirely* (not just a different
Claude backend), replace the images via `agent-image` / `ai-python-image`. Any
replacement must honor these task contracts:

**`ai-generate-tests-unit`** — workspace `source`, working dir
`<source>/<SUBDIRECTORY>`. Must generate JUnit tests under `src/test/**`, run
them, and leave changes in the working tree. Result `TESTS_ADDED` = count of
added/changed test files. Env available via `envFrom` (provider/model/creds).

**`ai-analyze-cves`** — inputs via env: `VULNERABILITY_REPORT_PATH` (authoritative;
`.findings` + `.details` carry severity, affected PURLs, and the fix version in
the CVE prose), `REMEDIATION_REPORT_PATH` (supplemental), `MUST_FIX_PATH` (JSON
array; empty ⇒ must emit `COUNT=0`), `POLICY_CONTEXT`, plus `BATCH_SIZE` /
`MAX_TOKENS` (per-call batching). Must write these results: `COUNT`,
`DECISIONS_PATH` (JSON array of decisions, one per must-fix CVE, each validated),
and `ISSUES_DIR` (per-CVE `.title`/`.body`/`.labels` files; each body embeds the
six remediation fields in a `<!-- cve-decision -->` marker so the `/remediate`
trigger can parse it). Must decide on must-fix CVEs only, deriving
`PACKAGE`/`CURRENT_VERSION` from the affected PURL and the concrete
`FIXED_VERSION` from the analyze findings/prose.

**`ai-remediate-dependency`** — inputs via params/env: `CVE_ID`, `PACKAGE`,
`CURRENT_VERSION`, `FIXED_VERSION`, `JUSTIFICATION`. Must edit `pom.xml` to the
fixed version (only that dependency), confirm the project still compiles, and
leave changes in the working tree. Result `CHANGED` = `0`/`1`.

As long as a replacement image provides the same binaries/entrypoints the task
scripts call (or you also swap the task's `taskRef`), the rest of the pipeline is
unaffected.

## Safety notes

- **PRs are never auto-merged** — every change lands on a branch for human review.
- Secrets are mounted (`envFrom`/volume), never baked into images; the examples
  ship with `REPLACE_ME` placeholders and must not be committed with real values.
- User-controlled values flow into the Python task via env (`R_*`,
  `POLICY_CONTEXT`) rather than string-interpolated into source, to avoid script
  injection.
- **Cost/latency:** each AI task makes real model calls. Consider a `timeout` on
  the AI tasks and start with `AI_EFFORT: medium` if cost is a concern.
