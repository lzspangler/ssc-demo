#!/usr/bin/env bash
set -euo pipefail

# Cluster-side preparation for the SSC demo. This script never edits the
# ssc-demo checkout; it only reads its existing manifests and applies the
# explicitly requested cluster bootstrap resources.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SSC_DEMO_DIR="${SSC_DEMO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
SSC_DOMAIN="${SSC_DOMAIN:-}"
SSC_EXPECTED_OCP_VERSION="${SSC_EXPECTED_OCP_VERSION:-4.20.}"
SSC_MIN_READY_WORKERS="${SSC_MIN_READY_WORKERS:-3}"
SSC_OPERATOR_NAMESPACE="${SSC_OPERATOR_NAMESPACE:-openshift-operators}"
SSC_PLATFORM_ARGOCD_NAMESPACE="${SSC_PLATFORM_ARGOCD_NAMESPACE:-platform-gitops}"
SSC_PLATFORM_ARGOCD_NAME="${SSC_PLATFORM_ARGOCD_NAME:-platform-gitops}"
SSC_STORAGE_NAMESPACE="${SSC_STORAGE_NAMESPACE:-openshift-storage}"
SSC_RHTPA_NAMESPACE="${SSC_RHTPA_NAMESPACE:-trusted-profile-analyzer}"
SSC_QUAY_NAMESPACE="${SSC_QUAY_NAMESPACE:-quay-registry}"
SSC_STORAGE_CLUSTER_NAME="${SSC_STORAGE_CLUSTER_NAME:-ocs-storagecluster}"
SSC_NOOBAA_NAME="${SSC_NOOBAA_NAME:-noobaa}"
SSC_CEPH_STORAGE_CLASS="${SSC_CEPH_STORAGE_CLASS:-ocs-storagecluster-cephfs}"
SSC_RHTPA_HOOK_TLS_INSECURE="${SSC_RHTPA_HOOK_TLS_INSECURE:-true}"
ACTION="preflight"

usage() {
  cat <<'EOF'
Usage: ssc-demo-cluster.sh [--preflight|--ensure-storage|--bootstrap-gitops|--bootstrap-platform-argocd|--bootstrap-pipelines|--ensure-platform-argocd-admin|--ensure-keycloak-route|--ensure-rhtpa-router-ca|--ensure-rhtpa-server-ca|--ensure-rhtpa-hook-tls|--ensure-quay-noobaa-rbac]

Actions:
  --preflight             Read-only cluster and SSC prerequisite checks (default)
  --ensure-storage        Ensure ODF CephFS is the default filesystem StorageClass
  --bootstrap-gitops      Apply the existing SSC GitOps operator bootstrap manifests
  --bootstrap-platform-argocd  Apply the SSC platform ArgoCD instance and RBAC
  --bootstrap-pipelines   Render/apply the existing SSC Pipelines operator chart
  --ensure-platform-argocd-admin  Grant demo-only admin rights to the Argo controller
  --ensure-keycloak-route  Create the SSC sso hostname alias for Keycloak
  --ensure-rhtpa-router-ca Create the RHTPA namespace ingress-CA ConfigMap
  --ensure-rhtpa-server-ca Mount the CA bundle into the RHTPA server
  --ensure-rhtpa-hook-tls  Persist a dev-only TLS-compatible RHTPA hook override
  --ensure-quay-noobaa-rbac Grant the SSC Quay hook read-only ODF status access

Environment:
  SSC_DEMO_DIR             Path to an untouched ssc-demo checkout
  SSC_DOMAIN               Optional ingress domain override
  SSC_EXPECTED_OCP_VERSION Expected server-version prefix (default: 4.20.)
  SSC_MIN_READY_WORKERS     Minimum Ready worker count (default: 3)
  SSC_OPERATOR_NAMESPACE    Operator namespace (default: openshift-operators)
  SSC_PLATFORM_ARGOCD_NAMESPACE  Argo CD Application namespace (default: platform-gitops)
  SSC_PLATFORM_ARGOCD_NAME  Argo CD instance name (default: platform-gitops)
  SSC_STORAGE_NAMESPACE     ODF namespace (default: openshift-storage)
  SSC_RHTPA_NAMESPACE       RHTPA namespace (default: trusted-profile-analyzer)
  SSC_QUAY_NAMESPACE        Quay namespace (default: quay-registry)
  SSC_STORAGE_CLUSTER_NAME  ODF StorageCluster name (default: ocs-storagecluster)
  SSC_NOOBAA_NAME           NooBaa resource name (default: noobaa)
  SSC_CEPH_STORAGE_CLASS    Filesystem StorageClass (default: ocs-storagecluster-cephfs)
  SSC_RHTPA_HOOK_TLS_INSECURE  Use insecure TLS for dev hook (default: true)
EOF
}

while (($#)); do
  case "$1" in
    --preflight|--ensure-storage|--bootstrap-gitops|--bootstrap-platform-argocd|--bootstrap-pipelines|--ensure-platform-argocd-admin|--ensure-keycloak-route|--ensure-rhtpa-router-ca|--ensure-rhtpa-server-ca|--ensure-rhtpa-hook-tls|--ensure-quay-noobaa-rbac)
      ACTION="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_file() {
  [[ -f "$1" ]] || { echo "Missing required file: $1" >&2; exit 1; }
}

check_login() {
  oc whoami >/dev/null
  echo "User: $(oc whoami)"
  echo "Server: $(oc whoami --show-server)"
}

check_cluster() {
  local server_version
  server_version="$(oc version | awk '/Server Version:/ {print $3; exit}')"
  [[ "$server_version" == "${SSC_EXPECTED_OCP_VERSION}"* ]] || {
    echo "Expected OpenShift ${SSC_EXPECTED_OCP_VERSION}*; found ${server_version:-unknown}" >&2
    exit 1
  }
  local ready_workers
  ready_workers="$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '$2 == "Ready" {count++} END {print count+0}')"
  (( ready_workers >= SSC_MIN_READY_WORKERS )) || { echo "Expected at least ${SSC_MIN_READY_WORKERS} Ready workers; found $ready_workers" >&2; exit 1; }
  oc wait --for=condition=Available --timeout=5m clusteroperator --all >/dev/null
  oc wait --for=condition=Degraded=false --timeout=5m clusteroperator --all >/dev/null
  echo "OpenShift: $server_version; Ready workers: $ready_workers"
}

check_storage() {
  local phase health noobaa_phase default_fs
  phase="$(oc get storagecluster "$SSC_STORAGE_CLUSTER_NAME" -n "$SSC_STORAGE_NAMESPACE" -o jsonpath='{.status.phase}')"
  health="$(oc get cephcluster -n "$SSC_STORAGE_NAMESPACE" -o jsonpath='{.items[0].status.ceph.health}')"
  noobaa_phase="$(oc get noobaa "$SSC_NOOBAA_NAME" -n "$SSC_STORAGE_NAMESPACE" -o jsonpath='{.status.phase}')"
  default_fs="$(oc get storageclass "$SSC_CEPH_STORAGE_CLASS" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')"
  [[ "$phase" == Ready && "$health" == HEALTH_OK && "$noobaa_phase" == Ready ]] || {
    echo "ODF is not ready: StorageCluster=$phase Ceph=$health NooBaa=$noobaa_phase" >&2
    exit 1
  }
  [[ "$default_fs" == true ]] || echo "WARN: CephFS is not the default StorageClass; run --ensure-storage"
  oc get pv -o custom-columns='NAME:.metadata.name,CAPACITY:.spec.capacity.storage,CLASS:.spec.storageClassName,STATUS:.status.phase' | sed -n '1,12p'
  echo "ODF StorageCluster=Ready Ceph=HEALTH_OK NooBaa=Ready"
}

check_packages() {
  local package
  for package in openshift-gitops-operator openshift-pipelines-operator-rh rhtpa-operator rhtas-operator quay-operator rhbk-operator; do
    oc get packagemanifest "$package" >/dev/null || {
      echo "Missing operator package: $package" >&2
      exit 1
    }
  done
  echo "Required operator packages are available in the catalog"
}

preflight() {
  check_login
  check_cluster
  check_storage
  check_packages
  echo "Preflight passed. No cluster resources were changed."
}

ensure_storage() {
  check_login
  check_storage
  oc patch storageclass "$SSC_CEPH_STORAGE_CLASS" --type=merge \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
  echo "Ensured $SSC_CEPH_STORAGE_CLASS is the default filesystem StorageClass"
}

bootstrap_gitops() {
  if oc get subscription openshift-gitops-operator -n "$SSC_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    echo "GitOps subscription already exists; skipping bootstrap manifests"
    return
  fi
  require_file "$SSC_DEMO_DIR/bootstrap/platform-gitops/gitops-operator/namespace-openshift-gitops-operator.yaml"
  require_file "$SSC_DEMO_DIR/bootstrap/platform-gitops/gitops-operator/olm-gitops-operatorgroup.yaml"
  require_file "$SSC_DEMO_DIR/bootstrap/platform-gitops/gitops-operator/olm-gitops-subscription.yaml"
  check_login
  oc apply \
    -f "$SSC_DEMO_DIR/bootstrap/platform-gitops/gitops-operator/namespace-openshift-gitops-operator.yaml" \
    -f "$SSC_DEMO_DIR/bootstrap/platform-gitops/gitops-operator/olm-gitops-operatorgroup.yaml" \
    -f "$SSC_DEMO_DIR/bootstrap/platform-gitops/gitops-operator/olm-gitops-subscription.yaml"
  # The demo manifest pins an older starting CSV. Let the current 4.20 catalog
  # resolve the selected channel instead of failing on that stale pin.
  oc patch subscription openshift-gitops-operator -n "$SSC_OPERATOR_NAMESPACE" \
    --type=merge -p '{"spec":{"startingCSV":null}}' >/dev/null
  echo "GitOps operator bootstrap applied; wait for the CSV before creating the SSC app-of-apps."
}

bootstrap_pipelines() {
  if oc get subscription openshift-pipelines-operator -n "$SSC_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    echo "Pipelines subscription already exists; skipping bootstrap chart"
    return
  fi
  require_file "$SSC_DEMO_DIR/automation/gitops/components/pipelines/Chart.yaml"
  check_login
  command -v helm >/dev/null || { echo "helm is required for --bootstrap-pipelines" >&2; exit 1; }
  oc create namespace openshift-pipelines --dry-run=client -o yaml | oc apply -f -
  # Tekton Chains is configured by the SSC app-of-apps after RHTAS exists;
  # do not start its bootstrap Job during this operator-only preparation.
  helm template ssc-pipelines "$SSC_DEMO_DIR/automation/gitops/components/pipelines" \
    --set chains.enabled=false | oc apply -f -
  echo "SSC Pipelines operator resources applied from the existing chart (Chains deferred until RHTAS)."
}

bootstrap_platform_argocd() {
  if oc get argocd "$SSC_PLATFORM_ARGOCD_NAME" -n "$SSC_PLATFORM_ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    echo "$SSC_PLATFORM_ARGOCD_NAME ArgoCD already exists; skipping bootstrap manifests"
    return
  fi
  local dir="$SSC_DEMO_DIR/bootstrap/platform-gitops/gitops-platform-instance"
  require_file "$dir/namespace-platform-gitops.yaml"
  require_file "$dir/platform-gitops-argocd.yaml"
  require_file "$dir/platform-gitops-clusterrole.yaml"
  require_file "$dir/platform-gitops-clusterrolebinding.yaml"
  check_login
  oc apply \
    -f "$dir/namespace-platform-gitops.yaml" \
    -f "$dir/platform-gitops-clusterrole.yaml" \
    -f "$dir/platform-gitops-clusterrolebinding.yaml" \
    -f "$dir/platform-gitops-argocd.yaml"
  echo "SSC platform ArgoCD instance and RBAC applied. Component Applications were not applied."
}

ensure_quay_noobaa_rbac() {
  check_login
  oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ssc-quay-noobaa-reader
  namespace: ${SSC_STORAGE_NAMESPACE}
rules:
- apiGroups: ["noobaa.io"]
  resources: ["noobaas"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["noobaa.io"]
  resources: ["backingstores"]
  verbs: ["get", "list", "watch", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ssc-quay-noobaa-reader
  namespace: ${SSC_STORAGE_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ssc-quay-noobaa-reader
subjects:
- kind: ServiceAccount
  name: quay-noobaa
  namespace: ${SSC_QUAY_NAMESPACE}
EOF
  echo "SSC Quay NooBaa read-only RBAC applied."
}

ensure_platform_argocd_admin() {
  check_login
  oc create clusterrolebinding ssc-${SSC_PLATFORM_ARGOCD_NAME}-application-admin \
    --clusterrole=cluster-admin \
    --serviceaccount=${SSC_PLATFORM_ARGOCD_NAMESPACE}:${SSC_PLATFORM_ARGOCD_NAME}-argocd-application-controller \
    --dry-run=client -o yaml | oc apply -f -
  echo "Demo-only cluster-admin binding applied to the platform Argo application controller."
}

ensure_keycloak_route() {
  check_login
  local domain
  domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
  oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: sso
  namespace: keycloak
  labels:
    app.kubernetes.io/part-of: ssc-demo
    app.kubernetes.io/component: keycloak-compatibility
spec:
  host: sso.${domain}
  port:
    targetPort: 8080
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: edge
  to:
    kind: Service
    name: keycloak-service
    weight: 100
  wildcardPolicy: None
EOF
  echo "SSC Keycloak sso route applied"
}

ensure_rhtpa_router_ca() {
  check_login
  oc get namespace "$SSC_RHTPA_NAMESPACE" >/dev/null
  oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | oc create configmap ssc-router-ca -n "$SSC_RHTPA_NAMESPACE" \
        --from-file=ca-bundle.crt=/dev/stdin --dry-run=client -o yaml | oc apply -f -
  echo "RHTPA router CA ConfigMap applied"
}

ensure_rhtpa_server_ca() {
  check_login
  local app_patch
  app_patch='{"spec":{"ignoreDifferences":[{"group":"apps","kind":"Deployment","name":"server","namespace":"'"$SSC_RHTPA_NAMESPACE"'","jsonPointers":["/spec/template/spec/containers/0/env","/spec/template/spec/containers/0/volumeMounts","/spec/template/spec/volumes","/spec/strategy"]}]}}'
  oc patch application ssc-rhtpa-operator -n "$SSC_PLATFORM_ARGOCD_NAMESPACE" --type=merge -p "$app_patch" >/dev/null
  oc set env deployment/server -n "$SSC_RHTPA_NAMESPACE" SSL_CERT_FILE=/etc/rhtpa-ca/ca-bundle.crt
  oc set volume deployment/server -n "$SSC_RHTPA_NAMESPACE" --add --name=rhtpa-extra-ca --type=configmap --configmap-name=rhtpa-extra-ca --mount-path=/etc/rhtpa-ca --read-only --overwrite
  oc patch deployment server -n "$SSC_RHTPA_NAMESPACE" --type=merge -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}' >/dev/null
  oc rollout status deployment/server -n "$SSC_RHTPA_NAMESPACE" --timeout=5m
  echo "RHTPA server CA trust and low-resource rollout override applied"
}

ensure_rhtpa_hook_tls() {
  check_login
  local domain="${SSC_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')}"
  local tls_option=""
  [[ "$SSC_RHTPA_HOOK_TLS_INSECURE" == true ]] && tls_option="-k"
  oc patch application ssc-rhtpa-prerequisites -n "$SSC_PLATFORM_ARGOCD_NAMESPACE" --type=merge -p '{"spec":{"ignoreDifferences":[{"group":"batch","kind":"Job","name":"wait-for-keycloak","namespace":"'"$SSC_RHTPA_NAMESPACE"'","jsonPointers":["/spec/template/spec/containers/0/command"]}]}}' >/dev/null
  oc delete job wait-for-keycloak -n "$SSC_RHTPA_NAMESPACE" --ignore-not-found=true
  oc create job wait-for-keycloak -n "$SSC_RHTPA_NAMESPACE" \
    --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
    -- /bin/sh -c "curl $tls_option -sf -o /dev/null https://sso.${domain}/realms/backstage/.well-known/openid-configuration"
  oc annotate job wait-for-keycloak -n "$SSC_RHTPA_NAMESPACE" \
    argocd.argoproj.io/hook=PreSync \
    argocd.argoproj.io/hook-delete-policy=BeforeHookCreation \
    argocd.argoproj.io/sync-wave=0 >/dev/null
  oc wait --for=condition=complete --timeout=120s job/wait-for-keycloak -n "$SSC_RHTPA_NAMESPACE"
  echo "Development-only RHTPA TLS hook override applied and completed"
}

case "$ACTION" in
  --preflight) preflight ;;
  --ensure-storage) ensure_storage ;;
  --bootstrap-gitops) bootstrap_gitops ;;
  --bootstrap-platform-argocd) bootstrap_platform_argocd ;;
  --bootstrap-pipelines) bootstrap_pipelines ;;
  --ensure-platform-argocd-admin) ensure_platform_argocd_admin ;;
  --ensure-keycloak-route) ensure_keycloak_route ;;
  --ensure-rhtpa-router-ca) ensure_rhtpa_router_ca ;;
  --ensure-rhtpa-server-ca) ensure_rhtpa_server_ca ;;
  --ensure-rhtpa-hook-tls) ensure_rhtpa_hook_tls ;;
  --ensure-quay-noobaa-rbac) ensure_quay_noobaa_rbac ;;
esac
