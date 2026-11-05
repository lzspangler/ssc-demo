#!/usr/bin/env bash
set -euo pipefail

SSC_DEMO_DIR="${SSC_DEMO_DIR:-/Users/tstetson/Public/workspaces/project-lightpath/ssc-demo}"
VALUES_FILE="${SSC_VALUES_FILE:-/tmp/ssc-demo-values.yaml}"
NS="tssc-app-ci"

require_tools() {
  command -v oc >/dev/null
  command -v helm >/dev/null
  command -v openssl >/dev/null
}

value() {
  awk -v key="$1:" '$1 == key {print $2; exit}' "$VALUES_FILE"
}

ensure_values() {
  umask 077
  local domain api
  domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
  api="$(oc whoami --show-server)"
  if [[ ! -f "$VALUES_FILE" ]]; then
    [[ -n "${ENMAAS_API_KEY:-}" ]] || { echo "ENMAAS_API_KEY must be set" >&2; exit 1; }
    cat > "$VALUES_FILE" <<EOF
deployer:
  domain: $domain
  apiUrl: $api
credentials:
  keycloakDbPassword: $(openssl rand -hex 16)
  gitlabRootPassword: $(openssl rand -hex 16)
  tpaDbPassword: $(openssl rand -hex 16)
  tpaCliClientSecret: $(openssl rand -hex 16)
  quayAdminPassword: $(openssl rand -hex 16)
EOF
    chmod 600 "$VALUES_FILE"
  fi
  for key in keycloakDbPassword gitlabRootPassword tpaDbPassword tpaCliClientSecret quayAdminPassword; do
    [[ -n "$(value "$key")" ]] || { echo "Missing $key in $VALUES_FILE" >&2; exit 1; }
  done
}

bootstrap_platform() {
  bash "$PWD/cluster/ssc-demo-cluster.sh" --preflight
  bash "$PWD/cluster/ssc-demo-cluster.sh" --bootstrap-gitops
  bash "$PWD/cluster/ssc-demo-cluster.sh" --bootstrap-platform-argocd
  bash "$PWD/cluster/ssc-demo-cluster.sh" --bootstrap-pipelines
  bash "$PWD/cluster/ssc-demo-cluster.sh" --ensure-platform-argocd-admin
  bash "$PWD/cluster/ssc-demo-cluster.sh" --ensure-keycloak-route
  bash "$PWD/cluster/ssc-demo-cluster.sh" --ensure-rhtpa-router-ca
  bash "$PWD/cluster/ssc-demo-cluster.sh" --ensure-quay-noobaa-rbac
}

install_artifactory() {
  oc create namespace artifactory --dry-run=client -o yaml | oc apply -f -
  oc apply -f "$SSC_DEMO_DIR/automation/gitops/artifactory/openshift-extras.yaml" >/dev/null
  oc -n artifactory create secret generic artifactory-admin \
    --from-literal="password=admin@*=$(value artifactoryAdminPassword)" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc -n artifactory create secret generic artifactory-keys \
    --from-literal="master-key=$(value artifactoryMasterKey)" \
    --from-literal="join-key=$(value artifactoryJoinKey)" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc -n artifactory create secret generic artifactory-postgresql \
    --from-literal="postgres-password=$(value artifactoryPostgresPassword)" \
    --from-literal="password=$(value artifactoryAppPassword)" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc apply -f "$SSC_DEMO_DIR/automation/gitops/artifactory/application-artifactory.yaml" >/dev/null
  oc wait --for=jsonpath='{.status.sync.status}'=Synced --timeout=20m application/artifactory -n platform-gitops
  oc rollout status statefulset/artifactory -n artifactory --timeout=15m
  oc rollout status statefulset/artifactory-postgresql -n artifactory --timeout=15m
  oc rollout status deployment/artifactory-frontend -n artifactory --timeout=15m
  oc rollout status deployment/artifactory-jfbus -n artifactory --timeout=15m
}

ensure_artifactory_values() {
  if [[ -z "$(value artifactoryAdminPassword)" ]]; then
    cat >> "$VALUES_FILE" <<EOF
  artifactoryAdminPassword: $(openssl rand -hex 20)
  artifactoryMasterKey: $(openssl rand -hex 32)
  artifactoryJoinKey: $(openssl rand -hex 16)
  artifactoryPostgresPassword: $(openssl rand -hex 16)
  artifactoryAppPassword: $(openssl rand -hex 16)
EOF
  fi
}

create_runtime_secrets() {
  local domain tpa_cli
  domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
  tpa_cli="$(value tpaCliClientSecret)"
  oc -n "$NS" create secret generic tpa-secret \
    --from-literal="bombastic_api_url=https://server-trusted-profile-analyzer.${domain}" \
    --from-literal="oidc_issuer_url=https://sso.${domain}/realms/backstage" \
    --from-literal=oidc_client_id=tpa-cli \
    --from-literal="oidc_client_secret=$tpa_cli" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  [[ -n "${ENMAAS_API_KEY:-}" ]] || { echo "ENMAAS_API_KEY must be set" >&2; exit 1; }
  oc -n "$NS" create secret generic ai-agent-secret \
    --from-literal="OPENAI_API_KEY=$ENMAAS_API_KEY" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
}

create_maven_settings() {
  local admin af
  af="http://artifactory.artifactory.svc.cluster.local:8082/artifactory"
  admin="$(oc -n artifactory get secret artifactory-admin -o jsonpath='{.data.password}' | base64 -d | sed 's/^admin@\*=//')"
  python3 - "$af" "$admin" <<'PY' > /tmp/settings.xml
import sys
af, pw = sys.argv[1], sys.argv[2]
print(f'''<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers><server><id>artifactory</id><username>admin</username><password>{pw}</password></server></servers>
  <mirrors><mirror><id>artifactory</id><name>Artifactory maven virtual</name>
    <url>{af}/maven</url><mirrorOf>*</mirrorOf></mirror></mirrors>
</settings>''')
PY
  oc -n "$NS" create secret generic maven-settings \
    --from-file=settings.xml=/tmp/settings.xml --dry-run=client -o yaml | oc apply -f - >/dev/null
  rm -f /tmp/settings.xml
}

apply_ssc() {
  helm template ssc "$SSC_DEMO_DIR/automation/gitops/bootstrap-infra" \
    -f "$VALUES_FILE" --set argocd.namespace=platform-gitops \
    --set components.rhtpaPrerequisites.enabled=false | oc apply -f - >/dev/null
  # The auto-toolbox ODF store is RGW-backed, so the SSC Quay pvPool hook is
  # incompatible. Quay itself remains enabled and uses managed object storage.
  oc patch application ssc-quay -n platform-gitops --type=merge \
    -p '{"spec":{"source":{"helm":{"valuesObject":{"quay-registry":{"noobaa":{"enabled":false}}}}}}}' >/dev/null
  oc annotate application ssc-quay -n platform-gitops argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  # The local fork's CA-aware prerequisite chart is applied directly until its
  # fork branch is pushed and selected by the remote Argo source.
  if oc get application ssc-rhtpa-prerequisites -n platform-gitops >/dev/null 2>&1; then
    oc patch application ssc-rhtpa-prerequisites -n platform-gitops \
      --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null || true
    oc delete application ssc-rhtpa-prerequisites -n platform-gitops \
      --wait=false >/dev/null || true
  fi
  oc delete job wait-for-keycloak -n trusted-profile-analyzer --ignore-not-found=true >/dev/null 2>&1 || true
  helm template tpa "$SSC_DEMO_DIR/automation/gitops/components/rhtpa/tpa-prerequisites" \
    --namespace trusted-profile-analyzer \
    --set global.cluster.subdomain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')" \
    --set pgsql.password="$(value tpaDbPassword)" \
    --set oidc.issuerUrl="https://sso.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/realms/backstage" \
    --set oidc.tpaCli.secret="$(value tpaCliClientSecret)" \
    --set oidc.caConfigMap=ssc-router-ca | oc apply -n trusted-profile-analyzer -f - >/dev/null
  bash "$PWD/cluster/ssc-demo-cluster.sh" --ensure-rhtpa-server-ca
}

main() {
  require_tools
  oc whoami >/dev/null
  ensure_values
  ensure_artifactory_values
  bootstrap_platform
  install_artifactory
  create_runtime_secrets
  create_maven_settings
  apply_ssc
  echo "SSC demo deployment flow completed; run cluster/ssc-demo-actions.sh status for readiness."
}

main "$@"
