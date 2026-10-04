# AI vulnerability remediation

This repo splits the agentic security flow into **four focused pipelines** that
share the same tasks and images. Each has a single, distinct responsibility and
can be run on its own:

1. **`agentic-cve-selection`** — *decide what to fix (one).* Builds the image,
   uploads the SBOM to RHTPA, scans it, applies the policy **must-fix** gate, and
   asks the AI to select **exactly one** CVE. Ends at `ai-select-cve` and exposes
   that decision as pipeline results.
2. **`agentic-cve-analysis`** — *decide what to fix (all) → issues.* Same
   build → scan → must-fix chain, but asks the AI for a decision **per fixable
   CVE** and opens **one GitLab/GitHub issue per vulnerability**. Each issue
   carries the same six fields so commenting `/remediate` on it starts pipeline 3.
3. **`agentic-cve-remediation`** — *apply a fix.* Takes a CVE decision **as
   params**, has the AI bump the vulnerable Maven dependency to its fixed
   version, re-runs `mvn verify`, and opens a **PR/MR**. Does no discovery or
   scanning of its own.
4. **`agentic-test-generation`** — *raise test coverage.* Runs just the AI
   **test-generation** flow (clone → build → generate tests → `mvn verify` →
   tests-only PR/MR). No image build, SBOM/scan, or CVE remediation.

The CVE pipelines share one six-field decision contract
(`SELECTED`/`CVE_ID`/`PACKAGE`/`CURRENT_VERSION`/`FIXED_VERSION`/`JUSTIFICATION`):
`agentic-cve-selection` emits it as results (hand off by **params + manual
start** — see [Hand-off](#hand-off-selection--remediation)), while
`agentic-cve-analysis` embeds it in each issue so the
[`/remediate` trigger](#triggering-pipelines-from-a-gitlab-issue-comment) can feed it to
`agentic-cve-remediation` automatically. See the [Overview](#overview) for
per-step detail.

## Overview

This repo defines **four** pipelines that share the same tasks and images:

- **`pipelines/agentic-cve-selection.yaml`** — self-contained CVE discovery,
  prioritization, and selection (build → SBOM → RHTPA scan → must-fix gate → AI
  select). Outputs the selection decision as pipeline results; changes nothing in
  the repo.
- **`pipelines/agentic-cve-analysis.yaml`** — same build → scan → must-fix chain,
  but fans out: the AI produces a decision **per fixable CVE** and the pipeline
  opens **one issue per vulnerability** (each issue carries the six-field
  decision). Changes nothing in the repo beyond creating issues.
- **`pipelines/agentic-cve-remediation.yaml`** — applies a decision (passed in as
  params) to the git project: clone → AI bump the dependency → `mvn verify` →
  PR/MR. The remediation tail runs only when `SELECTED="1"`.
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
| `rhtpa-vulnerability-analysis` (`rhtpa-vulnerability-analysis`) | always | Analyzes the uploaded SBOM against RHTPA's vuln data, then suppresses findings an advisory explicitly marks fixed/not_affected for the exact PURL; writes the authoritative `VULNERABILITY_REPORT` (CVE + severity + affected PURL, plus `.suppressed`). See [why the suppression pass exists](#why-the-pipeline-needs-a-vex-suppression-pass). | **RHTPA / Trustify** — `POST /vulnerability/analyze`, `GET /purl/{purl}`. |
| `rhtpa-remediation-report` (`rhtpa-remediation-report`) | always | Resolves a concrete fix version per (PURL, CVE) by re-analyzing every known sibling version of each affected PURL, backports first; writes `REMEDIATION_REPORT` with `.fix_versions` (authoritative) and `.recommendations` (the catalog lookup, usually empty for upstream-only Maven deps). | **RHTPA / Trustify** — `GET /purl/base/{purl}`, `POST /vulnerability/analyze`, `GET /purl/{purl}`, `POST /purl/recommend`. |
| `conforma-policy-check` (`conforma-policy-check`) | always | Turns the vuln report into a policy **must-fix** CVE set (Conforma/EC gate, severity-based fallback); writes `MUST_FIX_PATH`. | **Conforma / EC** — optional policy source fetch (`conforma-policy-configuration`); empty uses the local severity fallback. |
| `ai-select-cve` (`ai-select-cve`) | always | AI selects **exactly one** CVE from the must-fix set, steered by `ai-remediation-policy`; emits structured results (`SELECTED`, `CVE_ID`, `PACKAGE`, `CURRENT_VERSION`, `FIXED_VERSION`, `JUSTIFICATION`) that become this pipeline's results. | **AI model server** — CVE-selection reasoning call (`ai-python-image`). |
| `show-sbom` (`show-sbom-rhdh`) | `finally` | Displays the SBOM for the built image in the PipelineRun output. | **Image registry** — reads the image/SBOM referenced by `IMAGE_URL`. |
| `show-summary` (`summary`) | `finally` | Prints a PipelineRun summary (git URL/commit, image URL, build-task status). | — (internal) |

### `agentic-cve-analysis` steps

Identical to `agentic-cve-selection` from `clone-repository` through
`conforma-policy-check` (and the same `finally` tasks). The tail differs: instead
of selecting one CVE, it analyzes **all** fixable ones and opens an issue for
each.

| Step (`taskRef`) | Runs when | Description | External systems / endpoints |
|------------------|-----------|--------------|------------------------------|
| `clone-repository` … `conforma-policy-check` | as above | Same eight tasks as `agentic-cve-selection` (build → SBOM → RHTPA scan → must-fix gate). | RHTAS / Image registry / RHTPA / Conforma (as above). |
| `ai-analyze-cves` (`ai-analyze-cves`) | always | AI produces a remediation decision for **every** fixable CVE in the must-fix set (concrete fixed version required), steered by `ai-remediation-policy`. Each decision also captures the CVE **severity** and the list of **available fixed versions**. Writes the validated decisions to the workspace and **pre-renders one issue title/body/labels triple per CVE** — the body embeds the six fields in a `<!-- cve-decision -->` marker and also shows severity, the **recommended version** (= `fixed_version`) and the available fixed versions; the `.labels` file carries the severity. Results: `COUNT`, `DECISIONS_PATH`, `ISSUES_DIR`. | **AI model server** — per-CVE reasoning call (`ai-python-image`). |
| `open-cve-issues` (`open-cve-issues`) | if `COUNT != "0"` | Opens one issue per rendered file, applying the base `LABELS` plus the per-CVE **severity** label from the `.labels` sidecar (best-effort dedupe: skips a CVE that already has an open issue). Runs on the **agent image** (bundles glab/gh). `ISSUES_CREATED` result. | **SCM / Git repo** — `glab issue create` / `gh issue create` (creds from `scm-auth-secret`). |
| `show-sbom` / `show-summary` | `finally` | Same as `agentic-cve-selection`. | Image registry / internal. |

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
| `open-pr` (`open-pr`) | if `SELECTED="1"` | Commits the remediation to an `rhtpa/*` branch, pushes it, and opens a PR/MR (carries the CVE/fix context; adds `Related to #N` when `ISSUE_IID` is set by an issue trigger). Runs on the **agent image** (bundles git/glab/gh). `PR_URL` result. | **SCM / Git repo** — `git push` + `glab mr create` / `gh pr create` (creds from `scm-auth-secret`). |

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
| `open-pr` (`open-pr-tests`) | always | Commits **only** the generated tests (`src/test`) to an `ai-tests/*` branch and opens a tests-only PR/MR (no CVE/fix wording; adds `Related to #N` when `ISSUE_IID` is set by an issue trigger); no-ops if nothing changed. Runs on the **agent image** (bundles git/glab/gh). `PR_URL` result. | **SCM / Git repo** — `git push` + `glab mr create` / `gh pr create` (creds from `scm-auth-secret`). |

## Files

| File | Purpose |
|------|---------|
| `pipelines/agentic-cve-selection.yaml` | Self-contained CVE discovery/scan/selection pipeline (build → SBOM → RHTPA scan → must-fix gate → AI select); outputs the selection decision as results |
| `pipelines/agentic-cve-analysis.yaml` | Same scan chain, but analyzes every fixable CVE and opens one issue per vulnerability (each carries the six-field decision) |
| `pipelines/agentic-cve-remediation.yaml` | Applies a selection decision (in via params) to the repo: clone → AI bump dependency → `mvn verify` → PR/MR |
| `pipelines/agentic-test-generation.yaml` | Standalone AI test-generation pipeline (generate tests → `mvn verify` → tests-only PR/MR) |
| `triggers/agentic-issue-triggers.yaml` | Tekton Triggers wiring to start pipelines from a GitLab issue comment — `/remediate` → `agentic-cve-remediation`, `/generate-tests` → `agentic-test-generation` (one EventListener + interceptors + a binding/template pair per command + RBAC + Route) |
| `config/ai-agent-config.yaml` | ConfigMap — the single AI backend switch (provider/model/region/effort) |
| `config/rhtpa-enable-importers-job.yaml` | Job — idempotently enables + forces the RHTPA Red Hat SBOM/CSAF importers |
| `ops/rhtpa-upload-advisory.sh` | Script — uploads/verifies/deletes a **single** advisory document (OSV/CSAF/…) in RHTPA, for records no importer covers |
| `ops/rhtpa-load-lightwell-data.sh` | Script — loads **the whole Lightwell remediation dataset** (`data/osv/` + `data/sbom/`) into RHTPA and verifies it; `--verify` / `--purge` |
| `ops/ai-agent-image-prewarm-daemonset.yaml` | DaemonSet — pre-pulls the large agent image onto every node so steps can't flake on ImagePullBackOff |
| `data/osv/LW-DEMO-001*.json` | OSV advisories — one per CVE, each declaring the Lightwell `.rhlw-00001` backport as the `fixed` version (see [Lightwell remediation data](#lightwell-remediation-data)) |
| `data/sbom/*.cdx.json` | One-component CycloneDX catalog SBOMs — their only job is to make each `.rhlw-00001` build a *known version* of its base PURL, so the fix-version scan can offer it |
| `secrets/ai-agent-secret.example.yaml` | Example Secret — AI provider credentials |
| `secrets/scm-auth-secret.example.yaml` | Example Secret — Git token for opening the PR/MR |
| `secrets/gitlab-webhook-secret.example.yaml` | Example Secret — shared token validating the GitLab issue webhook |
| `tasks/ai-generate-tests.yaml` | AI generates + runs unit tests |
| `tasks/rhtpa-vulnerability-analysis1.yaml` | Scans the SBOM's PURLs against RHTPA, then suppresses findings explicitly marked fixed/not_affected |
| `tasks/rhtpa-remediation-report2.yaml` | Resolves a concrete fix version per (PURL, CVE) — `.fix_versions`, backports first |
| `tasks/conforma-policy-check.yaml` | Conforma gate → must-fix CVE set |
| `tasks/ai-select-cve.yaml` | AI selects one CVE (structured output) |
| `tasks/ai-analyze-cves.yaml` | AI decides per fixable CVE (with severity + available fixed versions); renders one issue title/body/labels triple each |
| `tasks/open-cve-issues.yaml` | Opens one GitLab/GitHub issue per rendered file, applying the base + per-CVE severity label (runs on the **agent image**) |
| `tasks/ai-remediate-dependency.yaml` | AI bumps the dependency + verifies compile |
| `tasks/open-pr.yaml` | Commits to a branch and opens the PR/MR — tests + CVE remediation (runs on the **agent image** — see note below) |
| `tasks/open-pr-tests.yaml` | Tests-only PR/MR (no CVE/fix context) — used by the test-generation pipeline |
| `images/ai-agent-maven-claude/Dockerfile` | Agent runtime, **Claude Code** flavor (ubi-minimal + JDK17 + Maven + Node/Claude Code + git/glab/gh) |
| `images/ai-agent-maven-aider/Dockerfile` | Agent runtime, **aider** flavor (ubi-minimal + JDK17 + Maven + Python/aider + git/glab/gh) |
| `images/ai-python/Dockerfile` | CVE selection/analysis runtime (Anthropic + OpenAI Python SDKs) |

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

### `agentic-cve-analysis`

```
clone-repository → … → conforma-policy-check → ai-analyze-cves → open-cve-issues
                                                                 (only if COUNT != "0")
```

The head (`clone-repository` through `conforma-policy-check`) is identical to
`agentic-cve-selection`. The tail replaces the single-CVE selector with a
fan-out: `ai-analyze-cves` produces a decision for **every** fixable CVE and
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

## Triggering pipelines from a GitLab issue comment

Instead of the manual `tkn pipeline start` above, you can let a reviewer kick off
a pipeline by **commenting a slash-command on a GitLab issue**:

| Comment | Starts | Needs a decision? |
|---|---|---|
| `/remediate` | `agentic-cve-remediation` | yes — reads the six-field decision from the issue |
| `/generate-tests` | `agentic-test-generation` | no — only the repo coordinates |

Both commands share a **single** EventListener, webhook, and Route — the wiring
lives in `triggers/agentic-issue-triggers.yaml` (EventListener with
two triggers + `gitlab`/`cel` interceptors + a TriggerBinding/TriggerTemplate pair
per command + RBAC + Route). Each trigger's `cel` `filter` matches exactly one
command, so a comment only starts the pipeline it names.

### `/remediate`

Kicks off `agentic-cve-remediation`.

**Where the decision comes from.** The six-field decision is read from the
**issue body**, where it sits inside an HTML-comment marker so it stays invisible
in rendered markdown (a natural place to paste the output of
`agentic-cve-selection`):

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

### `/generate-tests`

Kicks off `agentic-test-generation` (add JUnit tests, run them, open a PR). Unlike
`/remediate` it carries **no decision** — the comment is just the command on its
own line:

```
/generate-tests
```

There's nothing to read from the issue body and nothing to override, so this
trigger uses a single `cel` interceptor that only checks the command and derives
`git-host` / `base-branch` from the payload. Only comments whose first characters
are `/generate-tests`, on an **issue** (not an MR), that pass the webhook token
check, start a run.

### Cluster setup for the issue-comment triggers

Everything the cluster needs, in order. Steps 1–2 are usually already true from
the [One-time setup](#one-time-setup); steps 3–5 are trigger-specific. Both
`/remediate` and `/generate-tests` are served by the **same** EventListener and
webhook, so this setup enables both at once — the only extra requirement for
`/generate-tests` is that the `agentic-test-generation` Pipeline and its Tasks are
applied (step 2).

**1. Operators / interceptors (cluster-level).** The Red Hat OpenShift Pipelines
operator must be installed **with** the Tekton Triggers stack, which provides the
`gitlab` and `cel` **ClusterInterceptors** the EventListener calls:
```
oc get clusterinterceptors      # expect at least: cel, gitlab
```

**2. The pipelines + their tasks must already be applied.** Each trigger only
creates a PipelineRun that references its Pipeline (`agentic-cve-remediation` for
`/remediate`, `agentic-test-generation` for `/generate-tests`); those Pipelines and
every Task they use must exist in the namespace (your normal `oc apply` of
`pipelines/` and `tasks/`). Apply only the pipeline(s) whose command you intend to
enable.

**3. Secrets & configs the run mounts** (in the pipeline namespace — the
`TriggerTemplate` wires these in, so the names must match or you override the
`tt.params` defaults):

| Name | Purpose |
|---|---|
| `gitlab-webhook-secret` (key `secretToken`) | Shared token the `gitlab` interceptor checks against GitLab's `X-Gitlab-Token`. |
| `git-auth` (Secret) | **Private repos only** — clone credentials. Not bound by either template by default (see the note at the end of this section); a public app repo needs none. |
| `scm-auth-secret` (Secret) | SCM token to open the MR (`api` scope on GitLab). |
| `maven-settings` (Secret) | Maven `settings.xml` for the build — mirrors all resolution through the Artifactory `maven` virtual repo. A **Secret** (not a ConfigMap) because Artifactory OSS has anonymous access off, so the settings.xml embeds a `<server>` credential. See `secrets/maven-settings-secret.example.yaml`. |
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
`maven-settings` with an **`emptyDir`** (override `workspace-size` / `scm-secret-name`
if your names differ). `maven-settings` is an *optional* workspace on the `maven`
task — its generate step writes a default `settings.xml` when none is supplied — so
an `emptyDir` suffices and matches how the manual runs are launched. It is
deliberately **not** a ConfigMap: a configMap-backed workspace whose ConfigMap
doesn't exist leaves the `package`/`re-run-tests` pod stuck in `PodInitializing`
forever (never an error, just hangs — the same trap as a missing `git-auth` Secret,
below). To route the build through the **Artifactory `maven` virtual repo**, create
the `maven-settings` **Secret** (`secrets/maven-settings-secret.example.yaml` — a
`settings.xml` with a `<mirror>`/`<server>` pair) and bind it as
`secret: {secretName: maven-settings}` (or, on a manual run,
`-w name=maven-settings,secret=maven-settings`). It must be a Secret rather than a
ConfigMap because Artifactory OSS has anonymous access off, so `settings.xml` carries
credentials; the same missing-backing `PodInitializing` hang applies, so create the
Secret before binding it. Neither binds `git-auth`: it's an
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
| `scm-auth-secret` | Secret | analysis (issues) + remediation + test-gen (PR step) | `username` + `token` with push + PR/MR-create scope, and issue-create for analysis (see below). From `secrets/scm-auth-secret.example.yaml`. (Name overridable via `scm-secret-name`.) |

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
   oc -n tssc-app-ci apply -f pipelines/agentic-cve-analysis.yaml
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
