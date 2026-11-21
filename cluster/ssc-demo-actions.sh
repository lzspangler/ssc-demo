#!/usr/bin/env bash
set -euo pipefail

NS="${SSC_PIPELINE_NAMESPACE:-tssc-app-ci}"
DOMAIN="${SSC_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}') }"
DOMAIN="${DOMAIN// /}"

usage() {
  cat <<'EOF'
Usage:
  ssc-demo-actions.sh status
  ssc-demo-actions.sh gitlab-info
  ssc-demo-actions.sh start-test-generation

Environment for start-test-generation:
  REPO_URL       Required repository URL
  REVISION       Default: main
  BASE_BRANCH    Default: main
  SUBDIRECTORY   Default: source
  AGENT_IMAGE    Optional agent image override
  VERIFY_COMMIT  Default: false
  SCM_PROVIDER   Default: gitlab

The helper reads the existing SSC Tekton resources and secrets. It does not
edit the ssc-demo repository or create source-control changes directly.
EOF
}

status() {
  oc get applications.argoproj.io -n platform-gitops \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase
  oc -n "$NS" get tasks,pipelines 2>/dev/null || true
  oc -n "$NS" get secret scm-auth-secret gitlab-webhook-secret quay-push ai-agent-secret maven-settings 2>/dev/null || true
  oc -n gitlab get pods 2>/dev/null || true
  oc -n quay-registry get quayregistry quay 2>/dev/null || true
}

gitlab_info() {
  cat <<EOF
GitLab URL: https://gitlab-gitlab.${DOMAIN}
Username: root
Password source: /tmp/ssc-demo-values.yaml (gitlabRootPassword)
Project: development/spring-boot-example-application
Pipeline namespace: ${NS}
EOF
}

start_test_generation() {
  : "${REPO_URL:?Set REPO_URL to the GitLab repository URL}"
  oc -n "$NS" get secret ai-agent-secret maven-settings scm-clone-basic-auth >/dev/null
  if command -v tkn >/dev/null; then
    local ws
    ws="$(mktemp /tmp/ssc-demo-workspace.XXXXXX.yaml)"
    trap 'rm -f "$ws"' EXIT
    cat > "$ws" <<'EOF'
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOF
    local -a agent_args=()
    if [[ -n "${AGENT_IMAGE:-}" ]]; then
      agent_args=(-p "agent-image=$AGENT_IMAGE")
    fi
    tkn -n "$NS" pipeline start agentic-test-generation \
      -p git-url="$REPO_URL" \
      -p revision="${REVISION:-main}" \
      -p base-branch="${BASE_BRANCH:-main}" \
      -p subdirectory="${SUBDIRECTORY:-source}" \
      -p verify-commit="${VERIFY_COMMIT:-false}" \
      -p git-host="gitlab-gitlab.${DOMAIN}" \
      -p scm-provider="${SCM_PROVIDER:-gitlab}" \
      "${agent_args[@]}" \
      -w name=workspace,volumeClaimTemplateFile="$ws" \
      -w name=maven-settings,secret=maven-settings \
      -w name=git-auth,secret=scm-clone-basic-auth \
      --showlog
    return
  fi
  oc create -n "$NS" -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: agentic-test-generation-
spec:
  pipelineRef:
    name: agentic-test-generation
  params:
  - name: git-url
    value: "$REPO_URL"
  - name: revision
    value: "${REVISION:-main}"
  - name: base-branch
    value: "${BASE_BRANCH:-main}"
  - name: subdirectory
    value: "${SUBDIRECTORY:-source}"
  - name: verify-commit
    value: "${VERIFY_COMMIT:-false}"
  - name: git-host
    value: "gitlab-gitlab.${DOMAIN}"
  - name: scm-provider
    value: "${SCM_PROVIDER:-gitlab}"
  workspaces:
  - name: workspace
    volumeClaimTemplate:
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 5Gi
  - name: maven-settings
    secret:
      secretName: maven-settings
  - name: git-auth
    secret:
      secretName: scm-clone-basic-auth
EOF
  echo "PipelineRun created; inspect with: oc get pipelinerun -n $NS"
}

case "${1:-}" in
  status) status ;;
  gitlab-info) gitlab_info ;;
  start-test-generation) start_test_generation ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
