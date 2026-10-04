#!/usr/bin/env bash
#
# Load the Lightwell remediation dataset into RHTPA (Trustify) and verify that
# the remediated GAVs come out the far side correctly.
#
# WHAT THIS LOADS (from ../data/):
#
#   data/osv/LW-DEMO-00*.json   OSV advisories. Each aliases ONE real CVE and
#                               declares `ranges[].events[].fixed = <X.Y.Z.rhlw-NNNNN>`.
#                               Trustify turns that event into status=fixed for
#                               the remediated PURL.
#   data/sbom/*.cdx.json        One-component CycloneDX documents whose only job
#                               is to make the remediated PURL a KNOWN VERSION of
#                               its base PURL. Trustify only enumerates versions
#                               it has seen in an ingested document, so without
#                               these the `.rhlw-*` build is invisible to
#                               rhtpa-remediation-report's fix-version scan.
#
# WHY BOTH ARE NEEDED -- the two halves of "supported":
#
#   RECOMMENDED: rhtpa-remediation-report walks every known version of an
#   affected base PURL and keeps the ones that are not vulnerable. The SBOM puts
#   `.rhlw-NNNNN` on that list; the OSV `fixed` event is what marks it clean.
#
#   SCANS CLEAN: POST /api/v2/vulnerability/analyze is PURE VERSION-RANGE
#   MATCHING. It reports ONLY the `affected` bucket -- `fixed` and
#   `not_affected` statuses never appear there. A backport such as
#   6.0.3.rhlw-00001 still sorts inside the upstream GHSA range [0, 6.4.0), so
#   analyze keeps calling it affected no matter what VEX you load. That is why
#   rhtpa-vulnerability-analysis makes a second pass over
#   GET /api/v2/purl/{purl} (which DOES return fixed / not_affected) and
#   suppresses those findings. This script's --verify output is exactly the data
#   that pass consumes, so if verification is clean, the pipeline scan is clean.
#
# Usage:
#   ./rhtpa-load-lightwell-data.sh            # load, then verify
#   ./rhtpa-load-lightwell-data.sh --verify   # verify only, change nothing
#   ./rhtpa-load-lightwell-data.sh --purge    # delete what a previous load created
#
#   -n, --namespace NS   namespace holding tpa-secret   (default: tssc-app-ci)
#   -s, --secret NAME    secret name                    (default: tpa-secret)
#   -k, --insecure       skip TLS verification (not needed on cluster-6jnws)
#
# Re-running a load is safe: re-uploading a document id creates a new VERSION
# rather than a duplicate, and the one with the newest `modified` wins. Bump
# `modified` in the JSON if you edit a record, otherwise your edit ingests as a
# DEPRECATED version and silently does nothing (see rhtpa-upload-advisory.sh).
#
# No jq: python3 only, matching config/rhtpa-enable-importers-job.yaml.
#
set -euo pipefail

NAMESPACE=tssc-app-ci
SECRET=tpa-secret
INSECURE=""
MODE=load

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$(cd "${HERE}/../data" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -s|--secret)    SECRET="$2";    shift 2 ;;
    -k|--insecure)  INSECURE="-k";  shift ;;
    --verify)       MODE=verify;    shift ;;
    --purge)        MODE=purge;     shift ;;
    -h|--help)      sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1" ;;
  esac
done

command -v oc      >/dev/null || die "oc not found"
command -v python3 >/dev/null || die "python3 not found"

secret_key() {
  oc -n "$NAMESPACE" get secret "$SECRET" -o go-template="{{index .data \"$1\"|base64decode}}" 2>/dev/null \
    || die "cannot read key '$1' from secret $SECRET in namespace $NAMESPACE (logged in with 'oc'?)"
}
RHTPA=$(secret_key bombastic_api_url)
ISSUER=$(secret_key oidc_issuer_url)
CLIENT_ID=$(secret_key oidc_client_id)
CLIENT_SECRET=$(secret_key oidc_client_secret)
[[ -n "$RHTPA" ]] || die "bombastic_api_url is empty in $SECRET"

TOKEN_EP=$(curl -s $INSECURE --max-time 30 "${ISSUER%/}/.well-known/openid-configuration" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token_endpoint"])') \
  || die "OIDC discovery failed against $ISSUER"
TOKEN=$(curl -s $INSECURE --max-time 30 -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d grant_type=client_credentials "$TOKEN_EP" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])') \
  || die "could not mint an OIDC token for client $CLIENT_ID"

API=(curl -s $INSECURE --max-time 180 -H "authorization: Bearer $TOKEN")

echo "RHTPA:     $RHTPA"
echo "data:      $DATA_DIR"
echo "mode:      $MODE"

# The PURL pairs this dataset is responsible for: "<base purl>|<remediated purl>".
PAIRS=(
  "pkg:maven/org.apache.commons/commons-lang3@3.14.0|pkg:maven/org.apache.commons/commons-lang3@3.14.0.rhlw-00001"
  "pkg:maven/com.fasterxml.woodstox/woodstox-core@6.0.3|pkg:maven/com.fasterxml.woodstox/woodstox-core@6.0.3.rhlw-00001"
)

urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

# ---------------------------------------------------------------------------
# purge
# ---------------------------------------------------------------------------
if [[ "$MODE" == "purge" ]]; then
  # DELETE returns 504 from the router but completes asynchronously; poll for 404.
  delete_and_wait() {
    local kind="$1" uuid="$2"
    echo "  deleting $kind $uuid (a 504 here is expected)"
    "${API[@]}" -X DELETE -o /dev/null -w "    DELETE -> http=%{http_code}\n" \
      "$RHTPA/api/v2/$kind/$uuid" || true
    for _ in $(seq 1 30); do
      local code
      code=$("${API[@]}" -o /dev/null -w '%{http_code}' "$RHTPA/api/v2/$kind/$uuid" || true)
      [[ "$code" == "404" ]] && { echo "    gone"; return 0; }
      sleep 10
    done
    echo "    WARNING: still present after 5 minutes"
  }

  for f in "$DATA_DIR"/osv/*.json; do
    [[ -e "$f" ]] || continue
    doc=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["id"])' "$f")
    # deprecated=Consider so superseded versions get cleaned up too.
    uuids=$("${API[@]}" --get --data-urlencode "q=$doc" --data-urlencode 'deprecated=Consider' \
      "$RHTPA/api/v2/advisory" | python3 -c '
import sys, json
for i in json.load(sys.stdin).get("items", []):
    print(i["uuid"])' || true)
    for u in $uuids; do delete_and_wait advisory "$u"; done
  done

  for f in "$DATA_DIR"/sbom/*.cdx.json; do
    [[ -e "$f" ]] || continue
    serial=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["serialNumber"])' "$f")
    uuids=$("${API[@]}" --get --data-urlencode "q=$serial" "$RHTPA/api/v2/sbom" | python3 -c '
import sys, json
for i in json.load(sys.stdin).get("items", []):
    print(i["id"])' || true)
    for u in $uuids; do delete_and_wait sbom "$u"; done
  done

  echo "purge complete"
  exit 0
fi

# ---------------------------------------------------------------------------
# load
# ---------------------------------------------------------------------------
if [[ "$MODE" == "load" ]]; then
  echo
  echo "--- advisories (OSV) ---"
  for f in "$DATA_DIR"/osv/*.json; do
    [[ -e "$f" ]] || die "no OSV records under $DATA_DIR/osv"
    # Refuse to ship a record that would ingest inert; see rhtpa-upload-advisory.sh.
    python3 -c '
import sys, json
d = json.load(open(sys.argv[1]))
if not d.get("aliases"):
    sys.exit("%s has no aliases -- it would ingest but link no vulnerability" % sys.argv[1])' "$f"
    resp=$("${API[@]}" -X POST -H 'content-type: application/json' --data-binary "@$f" \
      "$RHTPA/api/v2/advisory?format=osv&labels.source=lightwell&labels.tier=remediated")
    python3 -c '
import sys, json
try:
    r = json.loads(sys.argv[2])
except Exception:
    sys.exit("  %s -> unparseable response: %s" % (sys.argv[1], sys.argv[2][:200]))
if "id" not in r:
    sys.exit("  %s -> rejected: %s" % (sys.argv[1], sys.argv[2][:200]))
print("  %-20s -> %s" % (sys.argv[1].rsplit("/", 1)[-1], r["id"]))' "$f" "$resp"
  done

  echo
  echo "--- catalog SBOMs (CycloneDX) ---"
  for f in "$DATA_DIR"/sbom/*.cdx.json; do
    [[ -e "$f" ]] || die "no SBOMs under $DATA_DIR/sbom"
    resp=$("${API[@]}" -X POST -H 'content-type: application/json' --data-binary "@$f" \
      "$RHTPA/api/v2/sbom?labels.source=lightwell&labels.tier=remediated")
    python3 -c '
import sys, json
try:
    r = json.loads(sys.argv[2])
except Exception:
    sys.exit("  %s -> unparseable response: %s" % (sys.argv[1], sys.argv[2][:200]))
if "id" not in r:
    sys.exit("  %s -> rejected: %s" % (sys.argv[1], sys.argv[2][:200]))
print("  %-40s -> %s" % (sys.argv[1].rsplit("/", 1)[-1], r["id"]))' "$f" "$resp"
  done

  # Ingestion is asynchronous; give Trustify a moment before reading it back.
  echo
  echo "waiting 20s for ingestion to settle..."
  sleep 20
fi

# ---------------------------------------------------------------------------
# verify (runs after a load, or on its own)
# ---------------------------------------------------------------------------
echo
echo "=== verification ==="
RC=0
for pair in "${PAIRS[@]}"; do
  base="${pair%%|*}"
  remediated="${pair##*|}"

  echo
  echo "$remediated"

  # 1. Is the remediated version visible as a version of its base PURL? This is
  #    what makes it a candidate in rhtpa-remediation-report's fix-version scan.
  # /purl/base/{key} takes the url-encoded base PURL directly -- the `q=` search
  # does NOT match on a full purl string, only on name fragments.
  base_no_version="${base%@*}"
  versions=$("${API[@]}" "$RHTPA/api/v2/purl/base/$(urlenc "$base_no_version")" | python3 -c '
import sys, json
try:
    print(" ".join(v.get("version", "") for v in json.load(sys.stdin).get("versions", [])))
except Exception:
    pass' || true)
  if [[ -z "$versions" ]]; then
    echo "  [FAIL] base PURL $base_no_version is unknown to RHTPA"; RC=1
  else
    echo "  known versions: $versions"
    case " $versions " in
      *" ${remediated##*@} "*) echo "  [ok]   remediated version is a recommendation candidate" ;;
      *) echo "  [FAIL] remediated version is NOT a known version -- the catalog SBOM did not ingest"; RC=1 ;;
    esac
  fi

  # 2. For every CVE that still matches the remediated PURL by version range,
  #    is there an explicit fixed / not_affected status to suppress it? Any CVE
  #    left with only `affected` is one the pipeline scan will still report.
  "${API[@]}" "$RHTPA/api/v2/purl/$(urlenc "$remediated")" > /tmp/lw-purl.json || true
  python3 - /tmp/lw-purl.json <<'PY' || RC=1
import collections, json, sys

try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit("  [FAIL] could not read purl status")

by_cve = collections.defaultdict(lambda: collections.defaultdict(list))
for adv in doc.get("advisories") or []:
    for st in adv.get("status") or []:
        cve = st["vulnerability"]["identifier"]
        by_cve[cve][st.get("status")].append(adv.get("document_id"))

if not by_cve:
    print("  [ok]   no advisory matches this PURL at all")
    raise SystemExit(0)

unsuppressed = []
for cve in sorted(by_cve):
    statuses = by_cve[cve]
    clearing = sorted({d for s in ("fixed", "not_affected") for d in statuses.get(s, [])})
    if "affected" in statuses and not clearing:
        unsuppressed.append(cve)
        print("  [FAIL] %-16s affected by %s, nothing clears it"
              % (cve, ",".join(sorted(set(statuses["affected"])))))
    else:
        print("  [ok]   %-16s cleared by %s" % (cve, ",".join(clearing) or "(no affected status)"))

raise SystemExit(1 if unsuppressed else 0)
PY
done

echo
if [[ $RC -eq 0 ]]; then
  echo "All remediated PURLs are recommendation candidates and fully suppressed."
else
  echo "Verification FAILED -- see [FAIL] lines above."
fi
exit $RC
