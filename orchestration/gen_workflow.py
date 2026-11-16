#!/usr/bin/env python3
"""Generates orchestration/remediate_and_promote_gitlab.json for the ssc-demo
Automation Orchestrator. Building it programmatically guarantees the JSON and
the embedded python are well-formed."""
import json
import os

TRIGGER = "activity_7a1c2d3e_4f5b_4a6c_8d7e_9f0a1b2c3d4e"
URLBUILDER = "activity_11aa22bb_33cc_4dd4_88ee_55ff66aa77bb"
COMMENT = "activity_22bb33cc_44dd_4ee4_99ff_66aa77bb88cc"
WAITBUILD = "activity_33cc44dd_55ee_4ff4_aabb_77bb88cc99dd"
RUNTESTS = "activity_44dd55ee_66ff_4aa4_bbcc_88cc99dd00ee"
PROMOTE = "activity_55ee66ff_77aa_4bb4_ccdd_99dd00ee11ff"

CLUSTER_API_HELPERS = '''
import json, os, ssl, sys, time, urllib.parse, urllib.request, urllib.error

NAMESPACE = "tssc-app-ci"
API = "https://kubernetes.default.svc"

# Credential lookup. The worker deployment mounts no service-account token
# (the operator sets automountServiceAccountToken: false and resets manual
# changes to that field), and script subprocesses get only an allowlisted
# environment (locale/PATH vars -- no custom env vars ever reach them), so
# the credentials come from the orchestrator-worker-k8s-access Secret
# mounted at /var/run/ao-k8s by the orchestrator component's setup Job
# (automation/gitops/components/orchestrator; the patch also lives in that
# chart's README as a manual fallback). The projected token paths remain as
# a fallback for deployments that do mount them.
TOKEN_PATHS = ["/var/run/ao-k8s/token",
               "/var/run/secrets/kubernetes.io/serviceaccount/token"]
CA_PATHS = ["/var/run/ao-k8s/ca.crt",
            "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"]

def _read(path):
    with open(path) as fh:
        return fh.read().strip()

def _first_existing(paths):
    for p in paths:
        if os.path.exists(p):
            return p
    return None

try:
    _token_path = _first_existing(TOKEN_PATHS)
    _ca_path = _first_existing(CA_PATHS)
    if _token_path is None or _ca_path is None:
        raise OSError("no token at %s; no CA at %s"
                      % (", ".join(TOKEN_PATHS), ", ".join(CA_PATHS)))
    TOKEN = _read(_token_path)
    _SSL = ssl.create_default_context(cafile=_ca_path)
except OSError as exc:
    sys.exit("This workflow script needs in-cluster Kubernetes access and found "
             "no service-account token/CA: %s\\n"
             "(the worker deployment needs the orchestrator-worker-k8s-access "
             "Secret mounted at /var/run/ao-k8s, and the worker service "
             "account needs RBAC in tssc-app-ci: both are set up by the "
             "orchestrator component, "
             "automation/gitops/components/orchestrator -- see its README "
             "for the manual fallback)" % exc)

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, context=_SSL, timeout=60) as resp:
        return json.loads(resp.read().decode() or "{}")

def list_runs(pipeline):
    sel = urllib.parse.quote("tekton.dev/pipeline=" + pipeline, safe="")
    path = "/apis/tekton.dev/v1/namespaces/%s/pipelineruns?labelSelector=%s" % (NAMESPACE, sel)
    return api("GET", path).get("items", [])

def get_run(name):
    return api("GET", "/apis/tekton.dev/v1/namespaces/%s/pipelineruns/%s" % (NAMESPACE, name))

def create_run(body):
    created = api("POST", "/apis/tekton.dev/v1/namespaces/%s/pipelineruns" % NAMESPACE, body)
    return created["metadata"]["name"]

def state(run):
    """'True' (succeeded), 'False' (failed) or None (still running)."""
    for cond in run.get("status", {}).get("conditions", []):
        if cond.get("type") == "Succeeded":
            return cond.get("status")
    return None

def param(run, name):
    for p in run.get("spec", {}).get("params", []):
        if p.get("name") == name:
            return p.get("value")
    return None

def result(run, name):
    for r in run.get("status", {}).get("results", []):
        if r.get("name") == name:
            return r.get("value")
    return None

def created(run):
    return run["metadata"]["creationTimestamp"]
'''

build_url_code = '''import sys

# ---------------------------------------------------------------------------
# Configuration -- edit here, not further down.
# ---------------------------------------------------------------------------
GITLAB_HOST = "gitlab-gitlab.apps.cluster-b7zgr.dyn.redhatworkshops.io"
PROJECT_ID = "1"   # development/spring-boot-example-application (verified on this cluster)
# Fallback issue if the trigger expression below does not resolve at runtime.
# The isdigit() guard means an unresolved expression literal falls back to
# this constant instead of breaking the run (edit it if that happens).
FALLBACK_ISSUE_IID = "55"

raw = """${TRIGGER_REF}"""
issue_iid = raw.strip() if raw.strip().isdigit() else FALLBACK_ISSUE_IID

notes_url = "https://%s/api/v4/projects/%s/issues/%s/notes" % (GITLAB_HOST, PROJECT_ID, issue_iid)
print(notes_url)'''.replace("${TRIGGER_REF}", "${trigger.issue_iid}")

wait_code = CLUSTER_API_HELPERS + '''
# ---------------------------------------------------------------------------
# Stage 1: the /remediate comment (posted by the previous node) makes the
# agentic-issue-commands EventListener start agentic-cve-remediation for the
# issue. Wait for that run to finish. A HUMAN then merges the remediation MR,
# so allow hours.
# ---------------------------------------------------------------------------
REMEDIATION_TIMEOUT_MIN = 120
BUILD_TIMEOUT_MIN = 60
POLL_SECONDS = 30

NOTES_URL = """${URLBUILDER_REF}"""
ISSUE_IID = NOTES_URL.rstrip("/").split("/")[-2]
# Progress goes to stderr on purpose: downstream nodes parse this node's
# stdout as a single JSON line, so stdout must contain ONLY the final JSON.
print("Remediating issue %s; waiting for agentic-cve-remediation to finish..." % ISSUE_IID,
      file=sys.stderr)

def _latest_issue_run():
    runs = [r for r in list_runs("agentic-cve-remediation") if param(r, "issue-iid") == ISSUE_IID]
    return max(runs, key=created) if runs else None

# A failure visible in the first moments of this node is usually a STALE run
# from an earlier attempt: the /remediate comment posted seconds ago has not
# spawned its PipelineRun yet (webhook + EventListener take a few seconds).
# Snapshot the newest already-failed run name; the loop below only fails on
# a run OTHER than that snapshot.
_stale = _latest_issue_run()
initial_failed = (_stale["metadata"]["name"] if _stale and state(_stale) == "False" else None)

remediation = None
deadline = time.time() + REMEDIATION_TIMEOUT_MIN * 60
while True:
    latest = _latest_issue_run()
    if latest:
        s = state(latest)
        if s == "True":
            remediation = latest
            break
        if s == "False" and latest["metadata"]["name"] != initial_failed:
            sys.exit("Remediation pipeline run %s FAILED for issue %s -- see the "
                     "PipelineRun log; nothing will be tested or promoted."
                     % (latest["metadata"]["name"], ISSUE_IID))
        if s is None:
            print("  remediation %s still running..." % latest["metadata"]["name"],
                  file=sys.stderr)
        elif initial_failed:
            print("  stale failed run %s; waiting for this attempt's run to appear..."
                  % initial_failed, file=sys.stderr)
    if time.time() > deadline:
        sys.exit("Timed out after %d min waiting for an agentic-cve-remediation run "
                 "for issue %s (was the /remediate comment posted?)"
                 % (REMEDIATION_TIMEOUT_MIN, ISSUE_IID))
    time.sleep(POLL_SECONDS)

finished_at = (remediation.get("status", {}).get("completionTime")
               or created(remediation))
print("Remediation %s succeeded; waiting for the merge-triggered ci-build-publish..."
      % remediation["metadata"]["name"], file=sys.stderr)

# ---------------------------------------------------------------------------
# Stage 2: merging the remediation MR fires the ci-build-push EventListener,
# which starts ci-build-publish. The first ci-build-publish run that succeeds
# AFTER the remediation finished is taken as "the PR merged and CI published a
# new image" (correlating a build to THIS issue would need the GitLab API from
# an authenticated node -- fine while one issue is in flight, which is how the
# demo runs; documented in the README).
# ---------------------------------------------------------------------------
build = None
deadline = time.time() + BUILD_TIMEOUT_MIN * 60
while True:
    candidates = [r for r in list_runs("ci-build-publish")
                  if created(r) > finished_at and state(r) == "True"]
    if candidates:
        build = max(candidates, key=created)
        break
    if time.time() > deadline:
        sys.exit("Timed out after %d min waiting for a successful ci-build-publish "
                 "run after %s (was the remediation MR merged?)" % (BUILD_TIMEOUT_MIN, finished_at))
    print("  waiting for the merge-triggered build...", file=sys.stderr)
    time.sleep(POLL_SECONDS)

image = result(build, "IMAGE_URL")
commit = result(build, "CHAINS-GIT_COMMIT")
git_url = result(build, "CHAINS-GIT_URL")
if not (image and commit and git_url):
    sys.exit("ci-build-publish %s succeeded but is missing IMAGE_URL / "
             "CHAINS-GIT_COMMIT / CHAINS-GIT_URL results." % build["metadata"]["name"])

print("Built image: %s" % image, file=sys.stderr)
# The ONLY stdout line: downstream nodes json.loads this node's stdout.
print(json.dumps({"issue_iid": ISSUE_IID, "image": image, "commit": commit, "git_url": git_url}))'''.replace(
    "${URLBUILDER_REF}", "${%s.stdout}" % URLBUILDER)

tests_code = CLUSTER_API_HELPERS + '''
BUILD = json.loads("""${WAITBUILD_REF}""")
GIT_HOST = "gitlab-gitlab.apps.cluster-b7zgr.dyn.redhatworkshops.io"
TESTS_TIMEOUT_MIN = 90
POLL_SECONDS = 30

# ---------------------------------------------------------------------------
# Submit both image-level test pipelines against the freshly built image.
# Same PipelineRun shape the hand-run versions use (see pipelines/README.md):
# the pipeline service account via taskRunSpecs, a fresh 2Gi workspace claim,
# the maven-settings secret, tests pinned to the commit the image was built
# from, and evidence comments on the issue (issue-iid).
# ---------------------------------------------------------------------------
TASKS = ["clone-repository", "create-test-namespace", "deploy-app-image",
         "run-tests", "comment-test-evidence", "cleanup-test-namespace"]

def test_run(pipeline):
    return {
        "apiVersion": "tekton.dev/v1",
        "kind": "PipelineRun",
        "metadata": {
            "generateName": "%s-issue-%s-" % (pipeline, BUILD["issue_iid"]),
            "namespace": NAMESPACE,
            "labels": {"orchestrated-by": "automation-orchestrator"},
        },
        "spec": {
            "pipelineRef": {"name": pipeline},
            "params": [
                {"name": "image", "value": BUILD["image"]},
                {"name": "git-url", "value": BUILD["git_url"]},
                {"name": "revision", "value": BUILD["commit"]},
                {"name": "issue-iid", "value": BUILD["issue_iid"]},
                {"name": "git-host", "value": GIT_HOST},
            ],
            "taskRunSpecs": [{"pipelineTaskName": t, "serviceAccountName": "pipeline"}
                             for t in TASKS],
            "workspaces": [
                {"name": "workspace",
                 "volumeClaimTemplate": {
                     "metadata": {},
                     "spec": {"accessModes": ["ReadWriteOnce"],
                              "resources": {"requests": {"storage": "2Gi"}}}}},
                {"name": "maven-settings", "secret": {"secretName": "maven-settings"}},
            ],
        },
    }

functional = create_run(test_run("test-image-functional"))
integration = create_run(test_run("test-image-integration"))
# Progress to stderr: the promote node parses this node's stdout as JSON.
print("Started %s and %s" % (functional, integration), file=sys.stderr)

# ---------------------------------------------------------------------------
# Both must succeed; the first failure fails this workflow (and therefore
# blocks promotion) -- evidence comments on the issue come from the pipelines
# themselves.
# ---------------------------------------------------------------------------
deadline = time.time() + TESTS_TIMEOUT_MIN * 60
pending = {functional: "functional", integration: "integration"}
while pending:
    for name in list(pending):
        s = state(get_run(name))
        if s == "True":
            print("  %s (%s) SUCCEEDED" % (name, pending[name]), file=sys.stderr)
            del pending[name]
        elif s == "False":
            sys.exit("Test pipeline %s (%s) FAILED -- promotion to prod is blocked. "
                     "See the PipelineRun log and the issue for evidence."
                     % (name, pending[name]))
    if pending and time.time() > deadline:
        sys.exit("Timed out after %d min waiting for test pipelines %s"
                 % (TESTS_TIMEOUT_MIN, ", ".join(pending)))
    if pending:
        time.sleep(POLL_SECONDS)

# The ONLY stdout line: the promote node json.loads this node's stdout.
print(json.dumps({"image": BUILD["image"], "functional_run": functional,
                  "integration_run": integration}))'''.replace(
    "${WAITBUILD_REF}", "${%s.stdout}" % WAITBUILD)

promote_code = CLUSTER_API_HELPERS + '''
import base64

BUILD = json.loads("""${WAITBUILD_REF}""")
TESTS = json.loads("""${RUNTESTS_REF}""")
PROD_TIMEOUT_MIN = 30
POLL_SECONDS = 30
# GitLab coordinates for the evidence note posted on the issue afterwards.
GITLAB_HOST = "gitlab-gitlab.apps.cluster-b7zgr.dyn.redhatworkshops.io"
PROJECT_ID = "1"   # development/spring-boot-example-application

# ---------------------------------------------------------------------------
# Both test pipelines succeeded: promote the image to prod. gitops-cd-prod
# defaults everything except the image; we pass the app repo/commit for the
# MR context, auto-merge=true so the promotion MR merges itself, and the
# issue reference so the MR description links back to the remediation issue
# (GitLab shows the MR on the issue's activity feed as "mentioned in merge
# request"; both demo projects are public, so the cross-project reference
# resolves even though the MR is authored by the gitops project's own bot).
# ---------------------------------------------------------------------------
body = {
    "apiVersion": "tekton.dev/v1",
    "kind": "PipelineRun",
    "metadata": {
        "generateName": "gitops-cd-prod-orchestrated-",
        "namespace": NAMESPACE,
        "labels": {"orchestrated-by": "automation-orchestrator"},
    },
    "spec": {
        "pipelineRef": {"name": "gitops-cd-prod"},
        "params": [
            {"name": "image", "value": BUILD["image"]},
            {"name": "app-repo-url", "value": BUILD["git_url"]},
            {"name": "app-commit", "value": BUILD["commit"]},
            {"name": "auto-merge", "value": "true"},
            {"name": "issue-ref",
             "value": "development/spring-boot-example-application#%s" % BUILD["issue_iid"]},
            # "Closes" (gitops-cd-prod's own default, restated here so the
            # workflow is self-documenting): the MR merging into the gitops
            # repo's default branch auto-closes the remediation issue -- a
            # CVE is only done once the fix ships to prod. Dev/qa promotions
            # reference the issue without closing it.
            {"name": "issue-action", "value": "Closes"},
        ],
    },
}

name = create_run(body)
# Progress to stderr for consistency (nothing parses this node's stdout).
print("Started %s (image %s, auto-merge true)" % (name, BUILD["image"]), file=sys.stderr)

deadline = time.time() + PROD_TIMEOUT_MIN * 60
while True:
    run = get_run(name)
    s = state(run)
    if s == "True":
        mr_url = result(run, "MR_URL") or "(tag was already current; no MR needed)"
        merged = result(run, "MERGED")
        print("Promotion complete for image %s" % BUILD["image"], file=sys.stderr)
        print("  functional tests: %s SUCCEEDED" % TESTS["functional_run"], file=sys.stderr)
        print("  integration tests: %s SUCCEEDED" % TESTS["integration_run"], file=sys.stderr)
        print("  promotion MR: %s (merged: %s)" % (mr_url, "yes" if merged == "1" else "no"),
              file=sys.stderr)

        # ------------------------------------------------------------------
        # Close the loop on the issue: post the promotion MR URL as a note.
        # The MR lives in the gitops project, but a note carrying the MR URL
        # is itself a cross-project reference -- GitLab links the two both
        # ways (this complements the MR-description reference set up via
        # issue-ref above). The token is the app repo's own scm-auth-secret
        # (read through the Kubernetes API, same as the /remediate comment
        # node -- no platform credential copy). Best-effort by design: the
        # promotion already succeeded, so a failure here only warns.
        # ------------------------------------------------------------------
        try:
            secret = api("GET",
                         "/api/v1/namespaces/tssc-app-ci/secrets/scm-auth-secret")
            gitlab_token = base64.b64decode(secret["data"]["token"]).decode()
            note = ("Promoted to prod: image `%s`\\n\\n"
                    "- Promotion MR: %s (merged: %s)\\n"
                    "- Functional tests: %s\\n"
                    "- Integration tests: %s"
                    % (BUILD["image"], mr_url,
                       "yes" if merged == "1" else "no",
                       TESTS["functional_run"], TESTS["integration_run"]))
            req = urllib.request.Request(
                "https://%s/api/v4/projects/%s/issues/%s/notes"
                % (GITLAB_HOST, PROJECT_ID, BUILD["issue_iid"]),
                data=json.dumps({"body": note}).encode(), method="POST")
            req.add_header("PRIVATE-TOKEN", gitlab_token)
            req.add_header("Content-Type", "application/json")
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp.read()
            print("Posted promotion evidence note on issue %s"
                  % BUILD["issue_iid"], file=sys.stderr)
        except Exception as exc:
            print("WARNING: promotion succeeded but the evidence note on "
                  "issue %s could not be posted: %s"
                  % (BUILD["issue_iid"], exc), file=sys.stderr)

        print(json.dumps({"image": BUILD["image"], "prod_run": name,
                          "mr_url": mr_url, "merged": merged}))
        break
    if s == "False":
        sys.exit("gitops-cd-prod run %s FAILED -- see the PipelineRun log." % name)
    if time.time() > deadline:
        sys.exit("Timed out after %d min waiting for %s" % (PROD_TIMEOUT_MIN, name))
    time.sleep(POLL_SECONDS)'''.replace("${WAITBUILD_REF}", "${%s.stdout}" % WAITBUILD) \
                            .replace("${RUNTESTS_REF}", "${%s.stdout}" % RUNTESTS)

comment_code = CLUSTER_API_HELPERS + '''
import base64

NOTES_URL = """${URLBUILDER_REF}"""

# ---------------------------------------------------------------------------
# Comment /remediate on the issue. The GitLab token is NOT a platform
# credential copy: it is read from the tssc-app-ci secret scm-auth-secret --
# the same single source of truth the pipelines use -- through the
# Kubernetes API (the worker pods' service account is granted `get` on
# exactly that one secret by the orchestrator component's RBAC,
# automation/gitops/components/orchestrator).
# ---------------------------------------------------------------------------
secret = api("GET", "/api/v1/namespaces/tssc-app-ci/secrets/scm-auth-secret")
token = base64.b64decode(secret["data"]["token"]).decode()

req = urllib.request.Request(NOTES_URL,
                             data=json.dumps({"body": "/remediate"}).encode(),
                             method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("PRIVATE-TOKEN", token)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        note = json.loads(resp.read().decode())
except urllib.error.HTTPError as exc:
    sys.exit("GitLab rejected the /remediate comment: HTTP %d: %s"
             % (exc.code, exc.read().decode()[:300]))
print("Commented /remediate on the issue (note id %s); the "
      "agentic-issue-commands EventListener will start the remediation "
      "pipeline." % note.get("id"))'''.replace(
    "${URLBUILDER_REF}", "${%s.stdout}" % URLBUILDER)

workflow = {
    "schema_version": "2.0.0",
    "name": "Remediate Test Promote Gitlab",
    "description": "Remediate a human-chosen GitLab issue, wait for the merge "
                   "and CI image build, run both image-level test pipelines, "
                   "and on success promote the image to prod with auto-merge",
    "triggers": [
        {
            "id": TRIGGER,
            "type": "manual_trigger",
            "name": "Start remediation and promotion",
            # Manual-trigger inputs are declared as a JSON Schema under
            # parameters.input_schema (the only key parameters accepts) and
            # referenced downstream as ${trigger.<property>} -- both shapes
            # confirmed from the platform UI's own trigger factory code.
            "parameters": {
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "issue_iid": {
                            "type": "string",
                            "description": "Issue number (iid) in development/spring-boot-example-application to remediate, test and promote, e.g. 55",
                        }
                    },
                    "required": ["issue_iid"],
                }
            },
            "position": {"x": 0, "y": 250},
        }
    ],
    "nodes": [
        {
            "id": URLBUILDER,
            "type": "script",
            "name": "Build issue notes URL",
            "parameters": {"language": "python", "code": build_url_code},
            "settings": {},
            "position": {"x": 480, "y": 250},
        },
        {
            "id": COMMENT,
            "type": "script",
            "name": "Comment /remediate on the issue",
            "parameters": {"language": "python", "code": comment_code},
            "settings": {},
            "position": {"x": 960, "y": 250},
        },
        {
            "id": WAITBUILD,
            "type": "script",
            "name": "Wait for remediation, merge and image build",
            "parameters": {"language": "python", "code": wait_code},
            # Platform script-node timeout: the engine kills scripts at
            # settings.timeout seconds (default 300) and Temporal cancels 10s
            # later, so it must exceed the script's own total wait:
            # 120 min remediation + 60 min build + 5 min slack.
            "settings": {"timeout": 11100},
            "position": {"x": 1440, "y": 250},
        },
        {
            "id": RUNTESTS,
            "type": "script",
            "name": "Run functional and integration test pipelines",
            "parameters": {"language": "python", "code": tests_code},
            # 90 min test wait + 5 min slack.
            "settings": {"timeout": 5700},
            "position": {"x": 1920, "y": 250},
        },
        {
            "id": PROMOTE,
            "type": "script",
            "name": "Promote to prod (gitops-cd-prod, auto-merge)",
            "parameters": {"language": "python", "code": promote_code},
            # 30 min promotion wait + 5 min slack.
            "settings": {"timeout": 2100},
            "position": {"x": 2400, "y": 250},
        },
    ],
    "edges": [
        {"from": TRIGGER, "to": URLBUILDER},
        {"from": URLBUILDER, "to": COMMENT},
        {"from": COMMENT, "to": WAITBUILD},
        {"from": WAITBUILD, "to": RUNTESTS},
        {"from": RUNTESTS, "to": PROMOTE},
    ],
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
     "remediate_and_promote_gitlab.json")
with open(out, "w") as fh:
    json.dump(workflow, fh, indent=2)
    fh.write("\n")

# --- self-check: every embedded python script must compile ---
for node in workflow["nodes"]:
    if node["type"] == "script":
        compile(node["parameters"]["code"], node["name"], "exec")
print("wrote %s; all %d script nodes compile" % (out, len(workflow["nodes"])))
