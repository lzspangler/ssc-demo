# orchestrator

Red Hat Automation Orchestrator — the platform the `orchestration/`
remediation workflows run on — as an app-of-apps component. Installs the
operator (Red Hat Operators, `stable` channel), a BYO PostgreSQL 15 for the
platform's backend + Temporal databases, the `AutomationOrchestrator` CR,
the worker's Kubernetes access, and a setup Job that finishes the install in
ways Argo alone cannot.

`orchestration/` at the repo root holds the workflow definitions and the
full design notes for the worker patches and script-node constraints; this
README covers the chart itself.

## Why a chart (and not plain YAML like `orchestration/` used to have)

The platform's Postgres password appears in **three rendered places** — the
postgres Deployment's `POSTGRESQL_PASSWORD` env, the init SQL's `CREATE
USER` statements, and the two connection Secrets the CR's
`backendDatabase`/`temporalDatabase` refs point at. They must all carry the
same value at first boot (the init SQL creates the users the connection
Secrets authenticate as), and Argo has no way to template one value into a
plain-YAML directory. So the manifests that used to live in
`orchestration/*.yaml` moved here behind a single `dbPassword` value, which
bootstrap-infra sets from `credentials.orchestratorDbPassword`.

## What the setup Job does

Argo can apply manifests, but three parts of this install need an actor:
the operator owns the worker Deployment (Argo would fight it), the platform
API is not Kubernetes at all, and the workflow JSONs carry the reference
cluster's coordinates. The Job (`templates/cm-setup-script.yaml` +
`templates/job-setup.yaml`) is bash + curl + jq against the in-cluster
Kubernetes API — the same pattern as `start-gitops-cd-dev` — and:

1. Waits for the `automationorchestrator-demo-worker` Deployment (the
   operator's first install takes a while).
2. Strategically merges the worker patch onto it: env
   `APP_SCRIPT_NODES_ENABLED=true` (script nodes ship disabled; env-only
   setting, no CR field — see `orchestration/README.md`) and the
   `orchestrator-worker-k8s-access` Secret mounted at `/var/run/ao-k8s`
   (the operator mounts no token in the worker and resets manual
   `automountServiceAccountToken` changes, but extra env/volumes/mounts
   survive its reconcile). The patch reads the container name from the live
   object rather than assuming it. Idempotent: skipped when the env entry
   is already present.
3. Discovers the platform's API host by probing every Route in the
   namespace for `/api/v1/auth/providers` (the Route name is
   operator-generated and not documented as stable), then logs in with the
   operator-generated initial admin credentials
   (`<crName>-initial-admin-password`, keys `username`/`password`).
4. Resolves the app project's GitLab id through GitLab's anonymous API
   (both demo projects are public), falling back to id 1 with a warning.
5. Clones the gitops repo at the SAME revision Argo pulls this chart from,
   rewrites the cluster-specific values in the two workflow JSONs
   (GitLab host, `projects/1/`, `PROJECT_ID = "1"`, and the HTTP nodes'
   `credential_id` when it created a credential), best-effort creates a
   GitLab credential from `scm-auth-secret`, and imports-or-updates
   (match by name → `PATCH` with `expected_version`, else `POST` with
   `is_import: true`) then publishes each workflow.

The script is idempotent, so Argo-triggered retries (the Job carries
`Replace=true,Force=true` like the GitLab seeding Job) are safe. It never
logs secret values — key names and HTTP codes only.

## The REST API contract, and what is verified

The workflow-builder endpoints were reverse-engineered from the platform
UI's JavaScript bundle (the cluster went down mid-analysis), and are
**confirmed against the bundle**:

| Call | Body |
| ---- | ---- |
| `POST /api/v1/workflows` | `{name, description, workflow_definition, project_id, is_import: true}` |
| `PATCH /api/v1/workflows/{id}` | `{name, description, workflow_definition, expected_version}` |
| `POST /api/v1/workflows/{id}/versions/{v}/publish` | `{name: null, change_description, expected_version}` |
| `GET /api/v1/workflows` | list responses are `{resources: [...]}`; workflow objects carry `current_version` (or `version.version`) |
| `GET /api/v1/auth/providers` | unauthenticated health probe, `{resources: [...]}` |

Two points could NOT be verified and are handled defensively:

1. **Login.** The SPA's auth client is a separate, unsaved chunk. The Job
   tries `POST /api/v1/auth/login` (JSON `{username, password}`), then
   `POST /api/v1/auth/token` (form `grant_type=password`), accepts either a
   bearer token (`token`/`access_token`) or a session cookie, and verifies
   with `GET /api/v1/auth/me`. If both shapes are wrong the Job fails with
   a message pointing here.
2. **`POST /api/v1/credentials`.** The credential-create modal is another
   unsaved chunk; no `POST /credentials` call exists anywhere in the saved
   bundle. The Job sends `{name, credential_type: "gitlab", inputs:
   {host, token}, project_id?}` (credential type name confirmed from
   `GET /credential_types` when possible) and treats any failure as
   warn-and-continue: the workflows still import, but
   `remediate_next_gitlab.json`'s two HTTP nodes keep the old cluster's
   credential GUID and must be re-pointed by hand in the UI.
   `remediate_and_promote_gitlab.json` is unaffected — its nodes are script
   nodes that read `scm-auth-secret` directly.

To pin either one against a live instance, open the UI with the browser
devtools Network tab, perform the action by hand (log in; Credentials →
create), and read the request off the wire:

```bash
# login: watch for the POST the login page makes, e.g.
curl -v https://<orchestrator-route>/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<from the initial-admin-password Secret>"}'
# credentials: the create modal's POST, e.g.
curl -v https://<orchestrator-route>/api/v1/credentials \
  -H "Authorization: Bearer <token>" -H 'Content-Type: application/json' \
  -d '{"name":"...","credential_type":"...","inputs":{...}}'
```

Then fix `try_login` / the credential block in
`templates/cm-setup-script.yaml` accordingly.

## Manual fallbacks

Everything the Job does can be done by hand; `orchestration/README.md` has
the worker patches, and the import instructions with the two per-instance
node settings (GitLab credential, LLM model). The one step that is manual
on EVERY cluster regardless: the **LLM model** for the agentic node of
"Remediate Next Gitlab" — models are per-instance platform objects with no
stable identifier to script against. The Job logs a reminder when it
finishes.

## Other design notes

- **`installPlanApproval: Automatic`** (the hand-install used Manual): a
  fresh-cluster install is unattended and nothing is around to click
  "approve". Trade-off: the `stable` channel ships continuous builds, so
  Automatic also upgrades the operator under a live demo — switch to
  Manual (or pin `startingCSV`) on a cluster you keep demoing on.
- **No `imagePullSecrets` / no `spec.secrets` on the CR** — the operator
  pulls from registry.redhat.io via the cluster's global pull secret, and
  auto-generates the admin password + encryption key when refs are omitted.
- **Worker RBAC lives in `pipelineNamespace`** (`tssc-app-ci`): the Roles
  grant the worker SA `pipelineruns get/list/watch/create` and `get` on the
  single named Secret `scm-auth-secret`. The setup Job's own SA is scoped
  to: read/patch Deployments, list Routes, read the initial-admin Secret,
  read `automationorchestrators`, and (via the second binding) read
  `scm-auth-secret` in the pipeline namespace.
- **The workflow list may paginate.** The import matches by name against
  `GET /workflows`; with more workflows than one page holds, a name on a
  later page would not match and the import would try to create a
  duplicate. On a demo install (two workflows) that cannot happen; if you
  grow the platform, delete the duplicate and import by hand.
- **Anonymous clone**: the Job clones the gitops repo without credentials
  (same source Argo reads). Keep the repo public, or prefetch the JSONs
  another way on a private fork.
