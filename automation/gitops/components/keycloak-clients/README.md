# Bring-your-own-Keycloak

Provisions the realm objects ssc-demo needs into a Keycloak that **already
exists**, instead of installing one. Mutually exclusive with the `keycloak`
component — `bootstrap-infra` fails the render if both are enabled.

## When you need it

When the cluster already runs a Keycloak you must not replace. The case that
actually bites is a cluster whose **own OAuth is federated to it**: deleting
that Keycloak locks every user out of the cluster, including you.

```sh
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{" "}{.type}{"\n"}{end}'
oc get user $(oc whoami) -o jsonpath='{.identities}{"\n"}'
oc -n kube-system get secret kubeadmin
```

An `OpenID` provider, your own user resolving through it, and no `kubeadmin`
secret means that Keycloak is load-bearing for cluster access. Leave it alone.

Installing a second Keycloak alongside is not an option either:
`applications.yaml` derives the issuer host as `sso.<domain>`, which the
existing Keycloak's Route already holds.

## Usage

```yaml
components:
  keycloak:
    enabled: false
    realm: sso          # the realm your existing Keycloak actually serves
  keycloakClients:
    enabled: true
```

`realm` stays on the `keycloak` component on purpose. The issuer URL is
computed at the top of `applications.yaml`, *outside* the component guard, so
one value drives both the clients this chart creates and the issuer handed to
RHTAS and RHTPA — they cannot disagree.

## What it creates

| Kind | Name | Why |
|---|---|---|
| Client scope | `read:document`, `create:document`, `update:document`, `delete:document` | RHTPA authorises on the scopes present in the token |
| Realm role | `tpa-user`; `tpa-manager` → `tpa-user`; `tpa-admin` → `tpa-manager` | the composite chain the realm import defines |
| Client | `tpa-cli` | confidential, service accounts on — the client-credentials grant the Tekton tasks and RHTPA importers use |
| Client | `tpa-frontend` | public — browser login to the RHTPA console |
| Client | `trusted-artifact-signer` | public — RHTAS validates cosign identities against it |
| Role mapping | `tpa-admin` on `service-account-tpa-cli` | without it every SBOM upload authenticates fine and then 403s |

It does **not** touch existing clients, users, or identity-provider
configuration. Every step reads before it writes, so re-running converges
rather than duplicating — which matters, because it runs on every Argo sync.

Two things are easy to get wrong and silent when you do:

- **`clients.tpaCli.secret` must equal `credentials.tpaCliClientSecret`**, which
  must equal `oidc_client_secret` in the hand-made `tpa-secret`. Three copies
  of one value; if any drifts, every RHTPA call returns 401 and nothing else
  looks wrong. The Application wires the first two together automatically; the
  third is still manual, in RUNBOOK §8a.
- **`tpa-frontend`'s redirect URIs** default to the RHTPA console Route. An
  empty list in Keycloak produces an "Invalid parameter: redirect_uri" page
  with no other symptom.

## Running it outside Argo CD

```sh
helm template kc automation/gitops/components/keycloak-clients \
  --set global.cluster.subdomain=$DOMAIN \
  --set realm=sso \
  --set clients.tpaCli.secret=<tpaCliClientSecret> | oc apply -f -

oc -n keycloak wait --for=condition=complete job/keycloak-clients --timeout=300s
oc -n keycloak logs job/keycloak-clients
```

Expected output is one line per object, each `created` or `exists`, ending in
`OK: realm 'sso' provisioned for ssc-demo`.

## Verifying

```sh
TOKEN=$(curl -s -d grant_type=client_credentials -d client_id=tpa-cli \
  -d client_secret=<secret> \
  "https://sso.$DOMAIN/realms/sso/protocol/openid-connect/token" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

python3 -c "import sys,json,base64;p=sys.argv[1].split('.')[1];print(json.loads(base64.urlsafe_b64decode(p+'=='))['scope'])" "$TOKEN"
```

The scope claim must list the four `*:document` scopes. If it does not, the
default client scopes did not attach and RHTPA will 403 on upload.
