# Fresh-cluster runbook — the whole ssc-demo environment

Every step, in order, to stand the demo up on a cluster that has nothing on it
but OpenShift GitOps. You run all of it; nothing here assumes anything was done
for you.

`README.md` next to this file explains *why* each component is shaped the way it
is. This file is the ordered list of commands.

**Read §0 and §2 before you start.** Two decisions (the AI backend and which
fork Argo CD pulls from) are git edits, and making them after the install means
re-syncing rather than installing.

## What you end up with

| | Hostname | Signed in as |
|---|---|---|
| Keycloak | `https://sso.<domain>` | `keycloak-initial-admin` Secret (operator-generated) |
| GitLab | `https://gitlab-gitlab.<domain>` | `root` / `gitlabRootPassword` |
| Quay | `https://quay.<domain>` | `quayadmin` / `quayAdminPassword` |
| Artifactory | `https://artifactory-artifactory.<domain>` | `admin` / §1 password |
| RHTPA | `https://server-trusted-profile-analyzer.<domain>` | OIDC via Keycloak |
| RHTAS | — (Fulcio/Rekor/TUF Services, no UI) | — |
| Tekton | namespace `tssc-app-ci` | — |

Plus: the `development/spring-boot-example-application` repository imported into
GitLab with the CVE issue board, the `/remediate` and `/generate-tests` webhook,
23 Tasks, 5 Pipelines, and every credential the pipelines need.

Budget **2–3 hours of wall clock**, most of it unattended. RHTPA's first full
ingest of the CVE/OSV/CSAF feeds runs for several hours *after* that, in the
background — you do not have to wait for it before §9.

## 0. Preflight

```sh
oc whoami                                      # must be cluster-admin
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}{"\n"}'
oc -n openshift-gitops get pods | grep application-controller      # Running
oc get storageclass                            # one must be (default)
oc get storagecluster -A                       # ODF — see below
```

**ODF is a hard requirement** for two components: RHTPA's default `s3` storage
and Quay's managed object storage both raise an `ObjectBucketClaim` against
NooBaa in `openshift-storage`. If `oc get storagecluster -A` is empty, install
ODF first, or read *Storage* in `README.md` for RHTPA's filesystem fallback and
turn Quay off (`components.quay.enabled: false`).

Egress needed: `charts.openshift.io`, `charts.jfrog.io`, `registry.redhat.io`,
`quay.io`, `releases-docker.jfrog.io`, `github.com`, `redhat.com`,
`packages.redhat.com`, and whatever endpoint your AI backend lives behind.

Set this once; every later step uses it:

```sh
export DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export NS=tssc-app-ci
```

## 1. Artifactory

Artifactory is **not** part of the app-of-apps — it has its own Application,
its own secrets and its own ordering. Do it first: the `maven-settings` Secret
in §8 needs its admin password, and every build resolves dependencies through
it.

Follow `artifactory/INSTALL.md` end to end (§1–§6). It is four `oc apply`s and
three `oc create secret`s. Keep the admin password.

```sh
oc -n artifactory get pods            # artifactory-0 8/8 Running
curl -sk "https://$(oc -n artifactory get route artifactory -o jsonpath='{.spec.host}')/artifactory/api/system/ping"
```

## 2. Point Argo CD at a repository you can push to

`bootstrap-infra/values.yaml` ships:

```yaml
gitops:
  repoUrl: "https://github.com/lzspangler/ssc-demo.git"
  revision: "ssc-demo"
```

Argo CD pulls the charts **and the Tekton YAML** from there, not from your
working copy. Anything you change locally has no effect until it is pushed to
the branch Argo is watching. If you are going to edit the pipelines — and §3
says you probably are — fork or push a branch now and override both values in
the file you create in §4.

## 3. Choose the AI backend  ← decide before installing

The pipelines read their backend from the `ai-agent-config` ConfigMap, which
`ssc-tekton-config` syncs **as plain YAML from `pipelines/config/` with
`selfHeal: true`**. There is no Helm value for it. An `oc edit` on the live
ConfigMap is reverted within minutes, so this choice is a commit.

**aider + an OpenAI-compatible endpoint** (gpt-oss, Granite, vLLM, Ollama,
OpenShift AI, watsonx) — edit `pipelines/config/ai-agent-config.yaml`:

```yaml
data:
  AI_PROVIDER: "openai"
  AI_AGENT:    "aider"
  AI_MODEL:    "gpt-oss-120b"                            # or your model id
  AI_BASE_URL: "http://vllm-gpt-oss.my-ns.svc:8000/v1"   # the /v1 endpoint
```

`AI_MODEL` may be a bare id (litellm assumes the `openai/` provider) or a full
litellm string such as `ollama_chat/granite3.3:8b`. For a self-hosted HTTPS
endpoint behind a private CA, also set `SSL_VERIFY` to the CA path — aider
honours it, and plain in-cluster `http://…svc` avoids the problem entirely.
`agent-image` already defaults to `ai-agent-maven-aider`, so no pipeline edit is
needed.

**Anthropic + Claude Code** (the committed default) — change nothing here, but
set `agent-image` to an `ai-agent-maven-claude` build on the PipelineRun, or
edit the default in the pipelines.

Either way, commit and push before §5:

```sh
git -C <your clone> commit -am "pick AI backend" && git push
```

## 4. Write an uncommitted overrides file

Five credentials have no default and must not reach git.

```sh
cat > /tmp/ssc-demo-values.yaml <<EOF
deployer:
  domain: ${DOMAIN}
credentials:
  keycloakDbPassword: $(openssl rand -hex 16)
  gitlabRootPassword: $(openssl rand -hex 16)
  tpaDbPassword: $(openssl rand -hex 16)
  tpaCliClientSecret: $(openssl rand -hex 16)
  quayAdminPassword: $(openssl rand -hex 16)
EOF
chmod 600 /tmp/ssc-demo-values.yaml
```

Add your fork from §2 if you made one:

```yaml
gitops:
  repoUrl: "https://github.com/<you>/ssc-demo.git"
  revision: "<your branch>"
```

**Keep this file.** `tpaCliClientSecret` is needed again in §8, and the other
three are the only copies of the GitLab, Quay and database passwords.

## 5. Create the Applications

```sh
helm template ssc automation/gitops/bootstrap-infra \
  -f /tmp/ssc-demo-values.yaml | oc apply -f -
```

Eleven Applications land at once; the sync waves serialise them.

```
 0  pipelines            OpenShift Pipelines operator
 3  tekton-tasks, tekton-config
 4  tekton-pipelines
 5  keycloak, tekton-triggers
 8  gitlab               (imports the app repo from GitHub — slow)
10  quay, rhtas, rhtpa-prerequisites
15  rhtpa
```

A wave does not start until the previous one is Healthy, so one Application
stuck in `Progressing` blocks everything behind it.

## 6. Watch it converge

```sh
watch "oc -n openshift-gitops get applications -l app.kubernetes.io/part-of=ssc-demo \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'"
```

Expected behaviour while you wait:

* **The Tekton Applications fail their first sync or two.** Wave 3 is reached
  before the operator has finished installing its CRDs. The 30-attempt retry and
  `SkipDryRunOnMissingResource` exist for exactly this; leave them alone.
* **GitLab sits in `Progressing` for 10–20 minutes.** The seeding job is doing a
  server-side clone of a GitHub repository.
* **Quay takes ~15 minutes** and its `quay-noobaa` Job runs first, patching
  ODF's default BackingStore from 256Mi to 1Gi. Below ~400Mi the NooBaa agent
  pod is rejected and no bucket is ever provisioned.

If something is stuck, the Application's `.status.operationState.message` and
then the Job logs are where the answer is:

```sh
oc -n gitlab        logs job/initialize-gitlab
oc -n quay-registry logs job/quay-noobaa
oc -n quay-registry logs job/quay-config
```

## 7. Check what the seeding jobs wrote

Three credentials that used to be manual are now minted for you. Confirm them
before going further — every later failure looks like something else.

```sh
oc -n $NS get secret scm-auth-secret gitlab-webhook-secret quay-push
oc -n $NS get sa pipeline -o jsonpath='{.secrets[*].name}{"\n"}'
```

The last command must list `quay-push` alongside the operator's
`pipeline-dockercfg-xxxxx`. That link is what lets a PipelineRun set
`output-image` and have `buildah-rhtap` push without naming a credential.

`scm-auth-secret` holds a GitLab **project** access token scoped to the one
application repository, not the root PAT.

## 8. Create the three remaining secrets by hand

### a. `tpa-secret` — RHTPA credentials for the Tekton tasks

The same `tpa-cli` client secret from §4, in the shape
`upload-sbom-to-trustification` requires. All four keys are mandatory.

```sh
oc -n $NS create secret generic tpa-secret \
  --from-literal=bombastic_api_url="https://server-trusted-profile-analyzer.${DOMAIN}" \
  --from-literal=oidc_issuer_url="https://sso.${DOMAIN}/realms/backstage" \
  --from-literal=oidc_client_id=tpa-cli \
  --from-literal=oidc_client_secret='<tpaCliClientSecret from §4>' \
  --dry-run=client -o yaml | oc apply -f -
```

A wrong secret here is invisible until a build reaches the upload step and the
token request comes back 401.

### b. `ai-agent-secret` — the AI backend key

Match the key name to the `AI_PROVIDER` you chose in §3:

```sh
# AI_PROVIDER=openai
oc -n $NS create secret generic ai-agent-secret \
  --from-literal=OPENAI_API_KEY='<key, or any placeholder for a server that ignores it>' \
  --dry-run=client -o yaml | oc apply -f -

# AI_PROVIDER=anthropic
oc -n $NS create secret generic ai-agent-secret \
  --from-literal=ANTHROPIC_API_KEY='<key>' \
  --dry-run=client -o yaml | oc apply -f -
```

### c. `maven-settings` — the Artifactory credential

Artifactory OSS has anonymous access off, so `settings.xml` carries a
credential and therefore has to be a Secret. Point the mirror at the in-cluster
Service, not the Route — that also sidesteps the router's 30 s timeout.

```sh
AF="http://artifactory.artifactory.svc.cluster.local:8082/artifactory"
ADMIN=$(oc -n artifactory get secret artifactory-admin \
        -o jsonpath='{.data.password}' | base64 -d | sed 's/^admin@\*=//')
python3 - "$AF" "$ADMIN" <<'PY' > /tmp/settings.xml
import sys; af, pw = sys.argv[1], sys.argv[2]
print(f'''<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers><server><id>artifactory</id><username>admin</username><password>{pw}</password></server></servers>
  <mirrors><mirror><id>artifactory</id><name>Artifactory maven virtual</name>
    <url>{af}/maven</url><mirrorOf>*</mirrorOf></mirror></mirrors>
</settings>''')
PY
oc -n $NS create secret generic maven-settings \
  --from-file=settings.xml=/tmp/settings.xml --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/settings.xml
```

Create it **before** the first run. A secret-backed workspace whose Secret is
missing leaves the pod in `PodInitializing` forever — it never errors, it just
hangs.

## 9. Load the Lightwell remediation data into RHTPA

Without this the demo still runs, but there is no backport for the AI to
recommend — the two seeded CVEs have no fix version and the remediation step has
nothing to do.

```sh
pipelines/ops/rhtpa-load-lightwell-data.sh            # load, then verify
pipelines/ops/rhtpa-load-lightwell-data.sh --verify   # verify only
```

It loads the one-component CycloneDX catalogs (which make
`3.14.0.rhlw-00001` / `6.0.3.rhlw-00001` *known versions* of their base PURLs)
and the OSV records that declare them `fixed`. `--verify` exits non-zero on any
`[FAIL]`.

The script authenticates by reading `tpa-secret` out of `tssc-app-ci`, so §8a
has to be done first. RHTPA must be Healthy; its feed importers do **not** have
to have finished.

## 10. Verify

```sh
# Platform
oc -n openshift-gitops get applications -l app.kubernetes.io/part-of=ssc-demo
oc -n quay-registry get quayregistry quay
oc -n trusted-artifact-signer get securesign securesign
oc -n keycloak get secret keycloak-initial-admin \
  -o go-template='{{index .data "username"|base64decode}}{{"\n"}}'

# Tekton layer
oc -n $NS get tasks | wc -l                                  # 23 + header
oc -n $NS get pipelines                                      # 4 agentic + maven-build-ci
oc -n $NS get eventlistener agentic-issue-commands           # ADDRESS populated
oc get clusterinterceptors                                   # at least cel, gitlab

# Credentials — all five must exist
oc -n $NS get secret scm-auth-secret gitlab-webhook-secret quay-push \
                     tpa-secret ai-agent-secret maven-settings
```

Then log into GitLab at `https://gitlab-gitlab.${DOMAIN}` as `root` and confirm
`development/spring-boot-example-application` is there with the CVE labels and a
project webhook pointing at `agentic-issue-commands-tssc-app-ci.${DOMAIN}`.

## 11. Smoke test

Build and scan, which is what produces the CVE issues the rest of the demo
reacts to. The `workspace` workspace is a per-run PVC, so give `tkn` a claim
template:

```sh
cat > /tmp/ws.yaml <<'EOF'
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOF

tkn -n $NS pipeline start agentic-cve-analysis \
  -p component-name=spring-boot-example-application \
  -p git-url=https://gitlab-gitlab.${DOMAIN}/development/spring-boot-example-application.git \
  -p revision=main \
  -p output-image=quay.${DOMAIN}/tssc/spring-boot-example-application:smoke \
  -p git-host=gitlab-gitlab.${DOMAIN} \
  -w name=workspace,volumeClaimTemplateFile=/tmp/ws.yaml \
  -w name=maven-settings,secret=maven-settings \
  -w name=git-auth,secret=scm-auth-secret \
  --showlog
```

Success looks like: the image appears at `quay.${DOMAIN}/tssc/…` (the `tssc`
repository is created on first push by the robot's `creator` team role), the
SBOM uploads to RHTPA, and GitLab issues are opened with the recommended
Lightwell backport.

Then exercise the webhook: comment **`/remediate`** on one of those issues. The
EventListener starts `agentic-cve-remediation`, which pushes a branch and opens
a merge request. **`/generate-tests`** does the same through
`agentic-test-generation`.

## Known rough edges

* **`base-branch` defaults to `master`**, the TriggerTemplates default to
  `main`, and the imported repository uses `main`. Manual runs of
  `agentic-cve-remediation` / `agentic-test-generation` need
  `-p base-branch=main`; webhook-driven runs are already correct.
* **The RHTAS defaults in the pipelines are stale** — `rekor-url`,
  `tuf-mirror` and `oidc-issuer` name the `tssc-tas` namespace and a
  `trusted-artifact-signer` realm, neither of which this install creates (they
  are `trusted-artifact-signer` and `backstage`). They are inert while
  `verify-commit: 'false'`, which is the default. Fix them in the pipeline files
  before turning commit verification on.
* **`pipelineNamespace` is effectively fixed at `tssc-app-ci`.**
  `pipelines/triggers/agentic-issue-triggers.yaml` hardcodes it as a
  `ClusterRoleBinding` subject and plain-YAML Applications cannot template it.
  `bootstrap-infra` fails the render with an explanation if you change one
  without the other.
* **Everything has `selfHeal: true`.** An `oc edit` against any managed resource
  is reverted on the next reconcile — change the chart, or for the Tekton layer,
  the file in `pipelines/`, and push.
* **`quay-admin-token` cannot be reissued.** Quay's `/api/v1/user/initialize`
  works once, while the user table is empty. Nothing renders that Secret, so
  Argo will not prune it — but if you delete it, the seeding job can no longer
  authenticate and you must mint a replacement token in the Quay UI by hand.

## Tearing it down

```sh
helm template ssc automation/gitops/bootstrap-infra \
  -f /tmp/ssc-demo-values.yaml | oc delete -f - --ignore-not-found
oc delete -f automation/gitops/artifactory/application-artifactory.yaml --ignore-not-found
oc delete ns gitlab keycloak quay-registry trusted-artifact-signer \
             trusted-profile-analyzer artifactory tssc-app-ci --ignore-not-found
```

Deleting the Applications leaves the operator Subscriptions in
`openshift-operators` and the ODF BackingStore patch in place; both are
harmless and both are reapplied by a reinstall.
