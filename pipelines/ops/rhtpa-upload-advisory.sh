#!/usr/bin/env bash
#
# Upload a SINGLE advisory document (OSV / CSAF / CVE / SBOM) to RHTPA (Trustify)
# from your laptop, without an importer.
#
# Why this exists: RHTPA's importers are bulk feeds bound to remote SOURCES --
# `osv-github` clones a git repository, `cve` the CVE List repo, `redhat-csaf` the
# Red Hat feed (see config/rhtpa-enable-importers-job.yaml and the "RHTPA
# importers" section of ../README.md). None of them will pick up one hand-written
# demo record, and a flat HTTP directory of OSV JSON (e.g. an Artifactory generic
# repo) is NOT a valid importer source. The ad-hoc endpoint below is the supported
# way to inject one document:
#
#     POST {bombastic_api_url}/api/v2/advisory?format=<fmt>&labels.<k>=<v>
#
# Auth is the same OIDC client-credentials flow the `upload-sbom-to-rhtpa` task
# uses; credentials come from the `tpa-secret` Secret in the pipeline namespace.
#
# Usage:
#   ./rhtpa-upload-advisory.sh [opts] <file>        # upload + verify
#   ./rhtpa-upload-advisory.sh --verify <doc-id>    # inspect what's ingested
#   ./rhtpa-upload-advisory.sh --delete <uuid>      # delete + wait for it to land
#
#   -n, --namespace NS     namespace holding tpa-secret   (default: tssc-app-ci)
#   -s, --secret NAME      secret name                    (default: tpa-secret)
#   -f, --format FMT       osv|csaf|cve|spdx|cyclonedx|...(default: osv)
#   -l, --label k=v        repeatable; applied as labels.k=v
#   -k, --insecure         skip TLS verification (not needed on cluster-6jnws)
#
# Examples:
#   ./rhtpa-upload-advisory.sh ../data/osv/LW-DEMO-0001.json
#   ./rhtpa-upload-advisory.sh -l source=lightwell -l tier=remediated ../data/osv/LW-DEMO-0001.json
#   ./rhtpa-upload-advisory.sh --verify LW-DEMO-0001
#
# THREE RHTPA BEHAVIOURS THIS SCRIPT EXISTS TO GUARD AGAINST (all verified
# 2026-10-04 against RHTPA 2.2.6 on cluster-6jnws):
#
#  1. An OSV record with NO `aliases` ingests cleanly (HTTP 201, downloadable)
#     but links ZERO vulnerabilities -- it never shows up in
#     POST /api/v2/vulnerability/analyze, so rhtpa-vulnerability-analysis in the
#     pipeline ignores it entirely. Trustify takes the vulnerability identifier
#     from `aliases` (the CVE), not from the document's own `id`. The preflight
#     below refuses to upload such a file unless you pass --allow-inert.
#
#  2. Re-uploading the same document id creates a NEW VERSION; it does not
#     replace. The version with the latest `modified` is current, older ones are
#     deprecated, and GET /api/v2/advisory defaults to deprecated=Ignore. So a
#     corrected re-upload that forgets to bump `modified` is invisible to search
#     while still being fetchable by uuid -- "it uploaded but I can't find it".
#     This script warns when the uploaded version did not become current.
#
#  3. DELETE /api/v2/advisory/{uuid} returns HTTP 504 from the OpenShift router
#     but COMPLETES ASYNCHRONOUSLY (~1-2 min). Do not retry on the 504 -- poll
#     GET .../{uuid} for a 404, which is what --delete does.
#
# No jq: this uses python3 for JSON, matching config/rhtpa-enable-importers-job.yaml.
#
set -euo pipefail

NAMESPACE=tssc-app-ci
SECRET=tpa-secret
FORMAT=osv
INSECURE=""
ALLOW_INERT=0
MODE=upload
TARGET=""
LABELS=()

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -s|--secret)     SECRET="$2";    shift 2 ;;
    -f|--format)     FORMAT="$2";    shift 2 ;;
    -l|--label)      LABELS+=("$2"); shift 2 ;;
    -k|--insecure)   INSECURE="-k";  shift ;;
    --allow-inert)   ALLOW_INERT=1;  shift ;;
    --verify)        MODE=verify; TARGET="$2"; shift 2 ;;
    --delete)        MODE=delete; TARGET="$2"; shift 2 ;;
    -h|--help)       sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)              die "unknown option: $1" ;;
    *)               TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]] || die "nothing to do; pass a file, --verify <doc-id> or --delete <uuid>. See --help."
command -v oc      >/dev/null || die "oc not found"
command -v python3 >/dev/null || die "python3 not found"

# --- credentials -------------------------------------------------------------
secret_key() {
  oc -n "$NAMESPACE" get secret "$SECRET" -o go-template="{{index .data \"$1\"|base64decode}}" 2>/dev/null \
    || die "cannot read key '$1' from secret $SECRET in namespace $NAMESPACE (are you logged in with 'oc'?)"
}
RHTPA=$(secret_key bombastic_api_url)
ISSUER=$(secret_key oidc_issuer_url)
CLIENT_ID=$(secret_key oidc_client_id)
CLIENT_SECRET=$(secret_key oidc_client_secret)
[[ -n "$RHTPA" ]] || die "bombastic_api_url is empty in $SECRET"

# Tokens are short-lived; mint one per run (every call below finishes well inside it).
TOKEN_EP=$(curl -s $INSECURE --max-time 30 "${ISSUER%/}/.well-known/openid-configuration" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token_endpoint"])') \
  || die "OIDC discovery failed against $ISSUER"
TOKEN=$(curl -s $INSECURE --max-time 30 -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d grant_type=client_credentials "$TOKEN_EP" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])') \
  || die "could not mint an OIDC token for client $CLIENT_ID"

API=(curl -s $INSECURE --max-time 120 -H "authorization: Bearer $TOKEN")

echo "RHTPA:     $RHTPA"
echo "namespace: $NAMESPACE (secret $SECRET)"

# --- helpers -----------------------------------------------------------------

# Print "<uuid>|<modified>|<vulns>" for every version of a document id, current first.
list_versions() {
  local doc="$1"
  "${API[@]}" --get --data-urlencode "q=$doc" --data-urlencode 'deprecated=Consider' \
    "$RHTPA/api/v2/advisory" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in d.get("items", []):
    vulns = ",".join(v.get("identifier","") for v in (i.get("vulnerabilities") or [])) or "-"
    print("%s|%s|%s" % (i.get("uuid"), i.get("modified"), vulns))'
}

# uuid of the CURRENT (non-deprecated) version, if any.
current_uuid() {
  local doc="$1"
  "${API[@]}" --get --data-urlencode "q=$doc" "$RHTPA/api/v2/advisory" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in d.get("items", []):
    print(i.get("uuid")); break'
}

report_advisory() {
  local uuid="$1"
  "${API[@]}" "$RHTPA/api/v2/advisory/$uuid" | python3 -c '
import sys, json
d = json.load(sys.stdin)
vulns = [v.get("identifier") for v in (d.get("vulnerabilities") or [])]
print("  document_id:     %s" % d.get("document_id"))
print("  uuid:            %s" % d.get("uuid"))
print("  modified:        %s" % d.get("modified"))
print("  labels:          %s" % d.get("labels"))
print("  vulnerabilities: %s" % (vulns or "[] <- INERT: nothing will match this advisory"))
sys.exit(0 if vulns else 3)'
}

# --- modes -------------------------------------------------------------------

if [[ "$MODE" == "verify" ]]; then
  echo
  echo "Versions of '$TARGET' (newest = current, others deprecated):"
  versions=$(list_versions "$TARGET")
  [[ -n "$versions" ]] || { echo "  (none found)"; exit 1; }
  printf '  %s\n' $versions
  cur=$(current_uuid "$TARGET")
  echo
  if [[ -n "$cur" ]]; then
    echo "Current version:"
    report_advisory "$cur" || echo "  WARNING: no linked vulnerabilities (missing 'aliases'?)"
  else
    echo "WARNING: no CURRENT version -- every copy is deprecated. Bump 'modified' and re-upload."
  fi
  exit 0
fi

if [[ "$MODE" == "delete" ]]; then
  echo
  echo "Deleting $TARGET (a 504 here is expected -- the router times out, the delete still runs)"
  "${API[@]}" -X DELETE -o /dev/null -w "  DELETE -> http=%{http_code}\n" \
    "$RHTPA/api/v2/advisory/$TARGET" || true
  echo -n "  waiting for it to disappear "
  for _ in $(seq 1 30); do
    code=$("${API[@]}" -o /dev/null -w '%{http_code}' "$RHTPA/api/v2/advisory/$TARGET" || true)
    if [[ "$code" == "404" ]]; then echo "-> gone"; exit 0; fi
    echo -n "."
    sleep 10
  done
  echo
  die "still present after 5 minutes (last status $code)"
fi

# --- upload ------------------------------------------------------------------
FILE="$TARGET"
[[ -f "$FILE" ]] || die "no such file: $FILE"

echo "file:      $FILE (format=$FORMAT)"
echo
echo "--- preflight ---"
python3 - "$FILE" "$FORMAT" "$ALLOW_INERT" <<'PY'
import json, sys
path, fmt, allow_inert = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
try:
    doc = json.load(open(path))
except Exception as e:
    sys.exit("  invalid JSON: %s" % e)
print("  valid JSON")

if fmt != "osv":
    print("  format=%s: skipping OSV-specific checks" % fmt)
    sys.exit(0)

print("  id:       %s" % doc.get("id"))
print("  modified: %s" % doc.get("modified"))

aliases = doc.get("aliases") or []
if aliases:
    print("  aliases:  %s" % aliases)
else:
    msg = ("  NO 'aliases' -- Trustify links an OSV advisory's vulnerability from its\n"
           "  aliases (the CVE), not from its own id. Without one this uploads with\n"
           "  HTTP 201 but links zero vulnerabilities and will never appear in\n"
           "  /api/v2/vulnerability/analyze, so the pipeline's scan ignores it.")
    if allow_inert:
        print("  WARNING:\n%s" % msg)
    else:
        sys.exit("  REFUSING:\n%s\n  Add an alias, or re-run with --allow-inert." % msg)

# A Maven purl must be pkg:maven/<groupId>/<artifactId>@<version>; a mismatch against
# package.name matches nothing in any SBOM even when the aliases are right.
for a in doc.get("affected") or []:
    pkg = a.get("package") or {}
    name, purl = pkg.get("name"), pkg.get("purl")
    if not purl:
        continue
    print("  purl:     %s" % purl)
    if (pkg.get("ecosystem") or "").lower() == "maven" and name and ":" in name:
        group, artifact = name.split(":", 1)
        expect = "pkg:maven/%s/%s@" % (group, artifact)
        if not purl.startswith(expect):
            print("  WARNING: purl does not match package.name '%s'; expected it to start\n"
                  "           with '%s'. As written it will match nothing." % (name, expect))
PY

echo
echo "--- uploading ---"
QS="format=$FORMAT"
for kv in "${LABELS[@]:-}"; do
  [[ -n "$kv" ]] || continue
  [[ "$kv" == *=* ]] || die "label must be k=v, got: $kv"
  QS="$QS&labels.${kv%%=*}=${kv#*=}"
done

RESP=$("${API[@]}" -X POST -H 'content-type: application/json' \
  --data-binary "@$FILE" "$RHTPA/api/v2/advisory?$QS") \
  || die "upload failed"
UUID=$(python3 -c 'import sys,json
try:
    print(json.load(sys.stdin)["id"])
except Exception:
    sys.exit("upload did not return an id: %s" % sys.stdin)' <<<"$RESP") \
  || die "upload rejected: $RESP"
DOC_ID=$(python3 -c 'import sys,json;print(json.load(sys.stdin).get("document_id",""))' <<<"$RESP")
echo "  uploaded: $UUID  (document_id=$DOC_ID)"

echo
echo "--- verifying ---"
rc=0
report_advisory "$UUID" || rc=$?
if [[ $rc -eq 3 ]]; then
  echo "  WARNING: ingested but INERT -- no vulnerabilities linked."
fi

CURRENT=$(current_uuid "$DOC_ID")
if [[ "$CURRENT" == "$UUID" ]]; then
  echo "  this version is CURRENT (visible in default advisory search)"
else
  echo
  echo "  WARNING: this upload did NOT become the current version."
  echo "  Another copy of '$DOC_ID' has a newer (or equal) 'modified', so yours is"
  echo "  deprecated and hidden from default search. Bump 'modified' in the file and"
  echo "  re-run, then delete the stale copy:"
  echo "      $0 --verify $DOC_ID"
  echo "      $0 --delete <old-uuid>"
fi

echo
echo "Done. Inspect later with:  $0 --verify $DOC_ID"
