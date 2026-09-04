# AI vulnerability remediation

This repo splits the agentic security flow into **three focused pipelines** that
share the same tasks and images. Each has a single, distinct responsibility and
can be run on its own:

1. **`agentic-cve-selection`** — *decide what to fix.* Builds the image, uploads
   the SBOM to RHTPA, scans it, applies the policy **must-fix** gate, and asks the
   AI to select **exactly one** CVE. Ends at `ai-select-cve` and exposes that
   decision as pipeline results.
2. **`agentic-cve-remediation`** — *apply a fix.* Takes a CVE-selection decision
   **as params**, has the AI bump the vulnerable Maven dependency to its fixed
   version, re-runs `mvn verify`, and opens a **PR/MR**. Does no discovery or
   scanning of its own.
3. **`agentic-test-generation`** — *raise test coverage.* Runs just the AI
   **test-generation** flow (clone → build → generate tests → `mvn verify` →
   tests-only PR/MR). No image build, SBOM/scan, or CVE remediation.

`agentic-cve-selection` and `agentic-cve-remediation` are two halves of one
workflow: selection produces a six-field decision
(`SELECTED`/`CVE_ID`/`PACKAGE`/`CURRENT_VERSION`/`FIXED_VERSION`/`JUSTIFICATION`)
and remediation consumes it. The hand-off is by **params + manual start** — see
[Hand-off: selection → remediation](#hand-off-selection--remediation). See the
[Overview](#overview) for per-step detail.

## Overview

This repo defines **three** pipelines that share the same tasks and images:

- **`pipelines/agentic-cve-selection.yaml`** — self-contained CVE discovery,
  prioritization, and selection (build → SBOM → RHTPA scan → must-fix gate → AI
  select). Outputs the selection decision as pipeline results; changes nothing in
  the repo.
- **`pipelines/agentic-cve-remediation.yaml`** — applies a selection decision
  (passed in as params) to the git project: clone → AI bump the dependency →
  `mvn verify` → PR/MR. The remediation tail runs only when `SELECTED="1"`.
- **`pipelines/agentic-test-generation.yaml`** — a standalone AI
  **test-generation** flow (clone → build → generate tests → `mvn verify` →
  tests-only PR/MR). No image build, SBOM/scan, or CVE remediation.

### `agentic-cve-selection` steps

The table below lists each pipeline task (in DAG order, then the two `finally`
tasks) with description and the **external systems** it talks to.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|--------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `verify-commit` (`verify-commit`) | only if `verify-commit="true"` | Verifies the cloned commit's signature against the signing infrastructure. | **RHTAS** — Rekor (`rekor-url`), TUF (`tuf-mirror`), Fulcio/OIDC issuer (`oidc-issuer`). |
| `package` (`maven`) | always | Runs the Maven build in `<workspace>/<subdirectory>`, producing `target/`. | **Artifact repository** — Maven repo/mirror for dependency resolution (`maven-settings` workspace). |
| `build-container` (`buildah-rhtap`) | always | Builds the container image from `dockerfile`/`path-context` and pushes it; emits `IMAGE_URL`/`IMAGE_DIGEST` and the SBOM. | **Image registry** — pushes the built image (`output-image`). |
| `upload-sbom-to-rhtpa` (`upload-sbom-to-rhtpa`) | always | Uploads the generated SBOM(s) to RHTPA/Trustify for the component. | **RHTPA / Trustify** — SBOM ingest (auth via `tpa-secret` OIDC). |
| `rhtpa-vulnerability-analysis` (`rhtpa-vulnerability-analysis`) | always | Analyzes the uploaded SBOM against RHTPA's vuln data; writes the authoritative `VULNERABILITY_REPORT` (CVE + severity + affected PURL). | **RHTPA / Trustify** — `POST /vulnerability/analyze`. |
| `rhtpa-remediation-report` (`rhtpa-remediation-report`) | always | Looks up vendor fixed-version recommendations; writes the supplemental `REMEDIATION_REPORT` (usually empty for upstream-only Maven deps). | **RHTPA / Trustify** — `POST /purl/recommend`. |
| `conforma-policy-check` (`conforma-policy-check`) | always | Turns the vuln report into a policy **must-fix** CVE set (Conforma/EC gate, severity-based fallback); writes `MUST_FIX_PATH`. | **Conforma / EC** — optional policy source fetch (`conforma-policy-configuration`); empty uses the local severity fallback. |
| `ai-select-cve` (`ai-select-cve`) | always | AI selects **exactly one** CVE from the must-fix set, steered by `ai-remediation-policy`; emits structured results (`SELECTED`, `CVE_ID`, `PACKAGE`, `CURRENT_VERSION`, `FIXED_VERSION`, `JUSTIFICATION`) that become this pipeline's results. | **AI model server** — CVE-selection reasoning call (`ai-python-image`). |
| `show-sbom` (`show-sbom-rhdh`) | `finally` | Displays the SBOM for the built image in the PipelineRun output. | **Image registry** — reads the image/SBOM referenced by `IMAGE_URL`. |
| `show-summary` (`summary`) | `finally` | Prints a PipelineRun summary (git URL/commit, image URL, build-task status). | — (internal) |

### `agentic-cve-remediation` steps

Every task runs unconditionally except **`verify-commit`** (optional) and the
remediation tail, which is gated on `SELECTED="1"`. No discovery, scan, or
selection — those live in `agentic-cve-selection`.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|-------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `verify-commit` (`verify-commit`) | only if `verify-commit="true"` | Verifies the cloned commit's signature against the signing infrastructure. | **RHTAS** — Rekor (`rekor-url`), TUF (`tuf-mirror`), Fulcio/OIDC issuer (`oidc-issuer`). |
| `ai-remediate-dependency` (`ai-remediate-dependency`) | if `SELECTED="1"` | AI edits `pom.xml` to bump only the vulnerable dependency (`PACKAGE`) to `FIXED_VERSION` and confirms it still compiles (scratch build); leaves the change on the workspace. `CHANGED` result. | **AI model server** (reasoning + edits); **Artifact repository** (Maven deps for the verify-compile). |
| `re-run-tests` (`maven`) | if `SELECTED="1"` | Runs `mvn verify` against the remediated tree. | **Artifact repository** — Maven repo/mirror (`maven-settings`). |
| `open-pr` (`open-pr`) | if `SELECTED="1"` | Commits the remediation to an `rhtpa/*` branch, pushes it, and opens a PR/MR (carries the CVE/fix context). Runs on the **agent image** (bundles git/glab/gh). `PR_URL` result. | **SCM / Git repo** — `git push` + `glab mr create` / `gh pr create` (creds from `scm-auth-secret`). |

### `agentic-test-generation` steps

Every task runs unconditionally except **`verify-commit`** (optional). No `init`,
image build, SBOM upload, or RHTPA scan.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|-------------|------------------------------|
| `clone-repository` (`git-clone`) | always | Clones the source repo at `revision` into the shared `workspace`; exposes `url`/`commit` results. | **SCM / Git repo** — `git clone` over HTTPS (creds from `git-auth` workspace). |
| `verify-commit` (`verify-commit`) | only if `verify-commit="true"` | Verifies the cloned commit's signature against the signing infrastructure. | **RHTAS** — Rekor (`rekor-url`), TUF (`tuf-mirror`), Fulcio/OIDC issuer (`oidc-issuer`). |
| `package` (`maven`) | always | Runs the Maven build in `<workspace>/<subdirectory>`, producing `target/`. | **Artifact repository** — Maven repo/mirror for dependency resolution (`maven-settings` workspace). |
| `ai-generate-tests` (`ai-generate-tests`) | always | AI coding agent generates JUnit tests under `src/test/**` and runs them (in a pod-local scratch copy); leaves the new tests on the workspace. `TESTS_ADDED` result. | **AI model server** (reasoning + edits); **Artifact repository** (Maven deps for compiling/running tests). |
| `re-run-tests` (`maven`) | always | Runs `mvn verify` (existing + generated tests) against the tree. | **Artifact repository** — Maven repo/mirror (`maven-settings`). |
| `open-pr` (`open-pr-tests`) | always | Commits **only** the generated tests (`src/test`) to an `ai-tests/*` branch and opens a tests-only PR/MR (no CVE/fix wording); no-ops if nothing changed. Runs on the **agent image** (bundles git/glab/gh). `PR_URL` result. | **SCM / Git repo** — `git push` + `glab mr create` / `gh pr create` (creds from `scm-auth-secret`). |

## Files

| File | Purpose |
|------|---------|
| `pipelines/agentic-cve-selection.yaml` | Self-contained CVE discovery/scan/selection pipeline (build → SBOM → RHTPA scan → must-fix gate → AI select); outputs the selection decision as results |
| `pipelines/agentic-cve-remediation.yaml` | Applies a selection decision (in via params) to the repo: clone → AI bump dependency → `mvn verify` → PR/MR |
| `pipelines/agentic-test-generation.yaml` | Standalone AI test-generation pipeline (generate tests → `mvn verify` → tests-only PR/MR) |
| `config/ai-agent-config.yaml` | ConfigMap — the single AI backend switch (provider/model/region/effort) |
| `config/rhtpa-enable-importers-job.yaml` | Job — idempotently enables + forces the RHTPA Red Hat SBOM/CSAF importers |
| `secrets/ai-agent-secret.example.yaml` | Example Secret — AI provider credentials |
| `secrets/scm-auth-secret.example.yaml` | Example Secret — Git token for opening the PR/MR |
| `tasks/ai-generate-tests.yaml` | AI generates + runs unit tests |
| `tasks/conforma-policy-check.yaml` | Conforma gate → must-fix CVE set |
| `tasks/ai-select-cve.yaml` | AI selects one CVE (structured output) |
| `tasks/ai-remediate-dependency.yaml` | AI bumps the dependency + verifies compile |
| `tasks/open-pr.yaml` | Commits to a branch and opens the PR/MR — tests + CVE remediation (runs on the **agent image** — see note below) |
| `tasks/open-pr-tests.yaml` | Tests-only PR/MR (no CVE/fix context) — used by the test-generation pipeline |
| `images/ai-agent-maven-claude/Dockerfile` | Agent runtime, **Claude Code** flavor (ubi-minimal + JDK17 + Maven + Node/Claude Code + git/glab/gh) |
| `images/ai-agent-maven-aider/Dockerfile` | Agent runtime, **aider** flavor (ubi-minimal + JDK17 + Maven + Python/aider + git/glab/gh) |
| `images/ai-python/Dockerfile` | CVE-selector runtime (Anthropic + OpenAI Python SDKs) |

## DAG

### `agentic-cve-selection`

```
clone-repository → verify-commit → package → build-container → upload-sbom-to-rhtpa → rhtpa-vulnerability-analysis → rhtpa-remediation-report
                                                                                                                                 │
                                                                                                                  conforma-policy-check
                                                                                                                                 │
                                                                                                                       ai-select-cve
```

A single linear chain that ends at `ai-select-cve`. The scan/select tasks run
after the build (not forked off `clone-repository`) so nothing runs concurrently
with the build/scan tasks that write `target/` on the shared workspace — a
concurrent writer there bumps the workdir mtime mid-read and breaks the agents'
`tar` of the source, so serializing avoids that race and is simpler to reason
about. The pipeline **changes nothing in the repo**; its whole output is the
selection decision, exposed as results
(`SELECTED`/`CVE_ID`/`PACKAGE`/`CURRENT_VERSION`/`FIXED_VERSION`/`JUSTIFICATION`,
plus `IMAGE_URL`/`IMAGE_DIGEST`/`CHAINS-GIT_*`). `verify-commit` is optional.

### `agentic-cve-remediation`

```
clone-repository → verify-commit → ai-remediate-dependency → re-run-tests (mvn verify) → open-pr
                                                        (whole tail only if SELECTED == "1")
```

This pipeline is now **param-driven**: it takes the selection decision in as
params rather than computing it. There is no build, SBOM upload, or RHTPA scan —
it clones the repo, has the AI bump the one dependency, re-verifies, and opens the
PR. `ai-remediate-dependency`, `re-run-tests`, and `open-pr` are each gated on
`SELECTED == "1"`, so passing `SELECTED="0"` (or omitting it — it defaults to
`"0"`) makes the pipeline a clean no-op after the clone. The guard is repeated on
all three tasks because Tekton's "skipped-parent still runs the successor"
semantics don't short-circuit a `runAfter` successor unless the successor's own
`when` also fails. `verify-commit` is optional. Like the other pipelines the
agent and `mvn verify` run in a pod-local scratch copy to avoid the
shared-`target/` race.

### `agentic-test-generation`

```
clone-repository → verify-commit → package → ai-generate-tests → re-run-tests (mvn verify) → open-pr
                                                          (re-run-tests + open-pr only if TESTS_ADDED != "0")
```

The standalone test-generation pipeline (`pipelines/agentic-test-generation.yaml`)
is the `ai-generate-tests` flow split out on its own. It has no `init`, image
build, SBOM upload, or RHTPA scan; every task runs unconditionally except
**`verify-commit`** (optional) and the `re-run-tests`/`open-pr` tail, which is
gated on `ai-generate-tests` actually producing new/changed tests
(`TESTS_ADDED != "0"`) — a run that generates nothing ends cleanly after
`ai-generate-tests`. The final `open-pr` step uses the **`open-pr-tests`** task —
a tests-only variant that commits just the generated tests (`src/test`) to an
`ai-tests/*` branch with no CVE/fix wording, and no-ops if nothing changed. Like
the CVE pipelines the agent and `mvn verify` run in a pod-local scratch copy to
avoid the shared-`target/` race. It needs the `ai-agent-config`/`ai-agent-secret`
and `scm-auth-secret` objects (and the agent image), but not `tpa-secret`, RHTPA,
or TAS.

## Hand-off: selection → remediation

`agentic-cve-selection` and `agentic-cve-remediation` are deliberately decoupled:
selection emits a six-field decision as **PipelineRun results**, and remediation
reads that decision from **params**. The two are joined by a manual start (the
transport is "params + manual start" — no shared workspace or event wiring), so a
human reviews the selected CVE before any repo change happens.

The contract is these six results/params (identical names on both sides):

| Field | Meaning |
|-------|---------|
| `SELECTED` | `"1"` if a CVE was selected, `"0"` otherwise. Remediation's tail runs only on `"1"`. |
| `CVE_ID` | The selected CVE identifier. |
| `PACKAGE` | Maven coordinates (`groupId:artifactId`) of the dependency to bump. |
| `CURRENT_VERSION` | The currently-resolved (vulnerable) version. |
| `FIXED_VERSION` | The concrete version to bump to. |
| `JUSTIFICATION` | Why this CVE was chosen (goes into the PR body). |

**1. Run selection and read its results** (PipelineRuns are ephemeral/pruned, so
capture them promptly):

```bash
# start selection (component/image/git params as appropriate)
tkn -n tssc-app-ci pipeline start agentic-cve-selection \
  -p component-name=my-app -p git-url=https://… -p output-image=quay.io/… \
  -w name=workspace,… -w name=maven-settings,… --showlog

# once it finishes, read the decision from the PipelineRun results
PR=<selection-pipelinerun-name>
oc -n tssc-app-ci get pipelinerun "$PR" \
  -o jsonpath='{range .status.results[*]}{.name}={.value}{"\n"}{end}'
```

**2. If `SELECTED=1`, review the decision, then start remediation** with those
values as params:

```bash
tkn -n tssc-app-ci pipeline start agentic-cve-remediation \
  -p git-url=https://…            -p subdirectory=source \
  -p SELECTED=1 \
  -p CVE_ID="CVE-2024-…"          -p PACKAGE="com.example:widget" \
  -p CURRENT_VERSION="1.2.3"      -p FIXED_VERSION="1.2.4" \
  -p JUSTIFICATION="…"            \
  -p git-host=gitlab.example.com  -p scm-provider=gitlab -p base-branch=main \
  -w name=workspace,…  -w name=maven-settings,…  -w name=git-auth,… --showlog
```

> **Result-size note:** long free-text `JUSTIFICATION` can be truncated by
> Tekton's result-size limit (results ride the step's termination message). Keep
> the selector's justification concise, or trim it before passing it on.

## Prerequisites

Everything below is assumed to be in place **before** the `## One-time setup`
commands. Items marked _(scan chain)_ are needed by **`agentic-cve-selection`**
(the build → SBOM → RHTPA scan half); the AI/SCM items are needed by whichever
pipelines you run (`agentic-cve-selection` uses the AI model server;
`agentic-cve-remediation` and `agentic-test-generation` additionally push a
PR/MR). `agentic-cve-remediation` and `agentic-test-generation` do **not** need
RHTPA or `tpa-secret`. The examples use the namespace `tssc-app-ci` — substitute
your own.

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
| `tpa-secret` | Secret | `agentic-cve-selection` only | `bombastic_api_url`, `oidc_issuer_url`, `oidc_client_id`, `oidc_client_secret`. Consumed by the RHTPA tasks **and** the importer Job. (Name overridable via `trustification-secret-name`.) |
| `ai-agent-config` | ConfigMap | all pipelines | The single backend switch. Apply `config/ai-agent-config.yaml`; pick `AI_PROVIDER`/`AI_AGENT`/`AI_MODEL` (+ `AI_BASE_URL` for gateway/openai). |
| `ai-agent-secret` | Secret | all pipelines | Provider credential(s) for the chosen `AI_PROVIDER` (e.g. `ANTHROPIC_API_KEY`). From `secrets/ai-agent-secret.example.yaml`. |
| `scm-auth-secret` | Secret | remediation + test-gen (PR step) | `username` + `token` with push + PR/MR-create scope (see below). From `secrets/scm-auth-secret.example.yaml`. (Name overridable via `scm-secret-name`.) |

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
branch) and **Pull requests: read & write** (open the PR), scoped to the target
repo. A classic token needs the `repo` scope.

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
matches `AI_AGENT`; build+push the CVE-selector `ai-python-image` as well. Images
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

## One-time setup

1. **Build & push the images**, then set the pipeline params (or edit the
   defaults) `agent-image` and `ai-python-image`. Build the agent flavor matching
   your `AI_AGENT` (or both):
   ```
   # Claude Code flavor (AI_AGENT=claude-code, the default):
   podman build --platform linux/amd64 -t quay.io/<org>/ai-agent-maven-claude:v1.0.0 images/ai-agent-maven-claude && podman push quay.io/<org>/ai-agent-maven-claude:v1.0.0
   # aider flavor (AI_AGENT=aider):
   podman build --platform linux/amd64 -t quay.io/<org>/ai-agent-maven-aider:v1.0.0  images/ai-agent-maven-aider  && podman push quay.io/<org>/ai-agent-maven-aider:v1.0.0
   # CVE-selector runtime:
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

5. **Apply the tasks + pipelines** (apply all three, or just the ones you use):
   ```
   oc -n tssc-app-ci apply -f tasks/
   oc -n tssc-app-ci apply -f pipelines/agentic-cve-selection.yaml
   oc -n tssc-app-ci apply -f pipelines/agentic-cve-remediation.yaml
   oc -n tssc-app-ci apply -f pipelines/agentic-test-generation.yaml
   ```

6. **Egress:** the cluster must allow the selected provider's endpoint
   (`api.anthropic.com:443` for the default `anthropic` provider; your gateway /
   Bedrock / Vertex endpoint otherwise) plus `gitlab.com`/`github.com` release
   downloads at image-build time.

## Turning it on

There is no single on/off gate anymore — you **start whichever pipeline** does the
job. A typical CVE run is two steps: `agentic-cve-selection` to decide, then
`agentic-cve-remediation` with that decision as params (see
[Hand-off](#hand-off-selection--remediation)). `agentic-test-generation` runs
independently.

The pipelines that open a PR/MR (`agentic-cve-remediation`,
`agentic-test-generation`) need the SCM params set on the PipelineRun (or in the
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

Optional (on `agentic-cve-selection`): override `ai-remediation-policy` (free-form
CVE-prioritization policy for the AI) and/or `conforma-policy-configuration` (an
EC policy source; empty
uses the severity fallback keeping analyze findings at/above `high`). The fallback
does **not** require a structured fixed version — analyze exposes the fix only as
free text in the CVE title/description, so `ai-select-cve` resolves the concrete
fixed version from that prose (with `fixed_version_hints` as candidates).

## Swapping the AI backend (pluggable)

The backend is abstracted so different AI implementations plug in **without
touching task YAML**. Two layers:

### 1. Provider/model/creds — ConfigMap + Secret

`config/ai-agent-config.yaml` is the single switch, with two independent knobs.

**`AI_PROVIDER`** — the wire protocol for the reasoning call (`ai-select-cve`)
and Claude Code auth:

| `AI_PROVIDER` | Extra ConfigMap keys | Secret keys | Notes |
|---------------|----------------------|-------------|-------|
| `anthropic` (default) | — | `ANTHROPIC_API_KEY` | Direct api.anthropic.com |
| `gateway` | `AI_BASE_URL` | `ANTHROPIC_AUTH_TOKEN` (or key) | Any Anthropic-compatible gateway/proxy |
| `bedrock` | `AWS_REGION` | AWS creds | Model auto-prefixed `anthropic.` |
| `vertex` | `VERTEX_PROJECT_ID`, `VERTEX_REGION` | GCP creds | |
| `openai` | `AI_BASE_URL` | `OPENAI_API_KEY` | Any OpenAI-compatible endpoint — **gpt-oss, IBM Granite** via vLLM / RHOAI / Ollama / watsonx |

**`AI_AGENT`** — which coding-agent CLI drives the file-editing tasks
(`ai-generate-tests`, `ai-remediate-dependency`):

| `AI_AGENT` | Use with | Runtime |
|------------|----------|---------|
| `claude-code` (default) | `AI_PROVIDER` anthropic/gateway/bedrock/vertex | Claude Code headless (Anthropic protocol only) |
| `aider` | `AI_PROVIDER=openai` | aider (litellm) — drives gpt-oss / Granite / any OpenAI-compatible model |

`AI_MODEL` (default `claude-opus-5`) and `AI_EFFORT` (default `high`) are honored
across tasks. Each task reads these via `envFrom` and translates them to the
correct client/env: Claude Code → `CLAUDE_CODE_USE_BEDROCK`/`_USE_VERTEX`/
`ANTHROPIC_BASE_URL`/`ANTHROPIC_MODEL`; aider → `--model` (`openai/<AI_MODEL>` if
unprefixed) + `OPENAI_API_BASE`/`OPENAI_API_KEY`; Python selector →
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
(Node + Claude Code) — set `agent-image` accordingly. The CVE-selector Python
image bundles both the Anthropic and `openai` SDKs, so it needs no change to
switch models.

### 2. Runtime — swappable images with a documented contract

To plug in a *different agent implementation entirely* (not just a different
Claude backend), replace the images via `agent-image` / `ai-python-image`. Any
replacement must honor these task contracts:

**`ai-generate-tests`** — workspace `source`, working dir
`<source>/<SUBDIRECTORY>`. Must generate JUnit tests under `src/test/**`, run
them, and leave changes in the working tree. Result `TESTS_ADDED` = count of
added/changed test files. Env available via `envFrom` (provider/model/creds).

**`ai-select-cve`** — inputs via env: `VULNERABILITY_REPORT_PATH` (authoritative;
`.findings` + `.details` carry severity, affected PURLs, and the fix version in
the CVE prose), `REMEDIATION_REPORT_PATH` (supplemental), `MUST_FIX_PATH` (JSON
array; empty ⇒ must emit `SELECTED=0`), `POLICY_CONTEXT`. Must write these
results: `SELECTED` (`0`/`1`), `CVE_ID`, `PACKAGE` (`groupId:artifactId`),
`CURRENT_VERSION`, `FIXED_VERSION`, `JUSTIFICATION`. Must pick from the must-fix
set only, deriving `PACKAGE`/`CURRENT_VERSION` from the affected PURL and the
concrete `FIXED_VERSION` from the analyze findings/prose.

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
