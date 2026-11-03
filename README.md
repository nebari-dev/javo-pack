# javo-pack

A Nebari software pack for [Javo](https://github.com/nebari-dev/javo): apps,
notebooks and scheduled jobs for teams. Each person runs JupyterLab, Streamlit,
Panel, VS Code, RStudio and other apps, and shares them with people, groups or
everyone. It is a candidate replacement for the data science pack
(JupyterHub with jhub-apps); see
[docs/replacing-data-science-pack.md](docs/replacing-data-science-pack.md).

> [!WARNING]
> **This pack and Javo are experimental.** Values and resources may change between releases without a migration path, and neither has run in production yet. Use a test cluster.

The chart wraps the `javo` chart and adds what NIC needs: two `NebariApp`
resources, which make the nebari-operator route Javo's two hosts through the
shared Envoy Gateway, give them TLS, and provision Javo's Keycloak client.

## What it deploys

| Resource | From | Purpose |
|---|---|---|
| Deployment `javo`, Service `javo-gateway` | javo chart | Javo's gateway (UI, API, app proxy) and controller in one pod (SQLite) |
| PVC `javo-data` | javo chart | The SQLite database, kept on uninstall |
| Namespace `javo-apps` | javo chart | Where apps, their homes and shared folders live (Pod Security `restricted`, default-deny ingress) |
| ConfigMap `javo-config`, Secret `javo-secrets-key`, RBAC | javo chart | Platform config, the key of people's secrets, the controller's rights |
| NebariApp `javo` | this pack | UI host: HTTPRoute, TLS, Keycloak client `<namespace>-javo` and Secret `javo-oidc-client`, landing-page card |
| NebariApp `javo-apps` | this pack | Apps host: HTTPRoute and TLS only |

## Prerequisites

- A NIC cluster with nebari-operator `v0.1.2` or later, Envoy Gateway,
  cert-manager and Keycloak. The pack was written against `v0.1.2`; the fields
  it uses (`enforceAtGateway`, `redirectURI`, `keycloakConfig`) exist there.
- The release namespace labelled `nebari.dev/managed=true` (the Argo CD example
  does this with `managedNamespaceMetadata`).
- DNS for two hosts pointing at the gateway, for example `javo.example.com`
  and `javo-apps.example.com`. A wildcard record for the cluster domain covers
  both.
- A CNI that enforces NetworkPolicy. Apps have no login of their own; Javo's
  default-deny policy is what keeps other pods out. k3s enforces it.
- The javo chart and image published (see "Publishing Javo").

## How sign-in works

Javo signs people in itself. The gateway only routes and terminates TLS.

```
Browser            Envoy Gateway           Javo                    Keycloak
   | GET javo.example.com | ---------------> |                          |
   | <---- sign-in page --------------------- |                          |
   | GET /auth/oidc/start  ----------------> |                          |
   | <---- 302 to Keycloak (client <ns>-javo, PKCE, nonce) ------------ |
   | login ----------------------------------------------------------->  |
   | <---- 302 https://javo.example.com/auth/oidc/callback?code=... ---- |
   | GET /auth/oidc/callback ------------> | -- code + client secret --> |
   |                                       | <-- ID token (groups, aud) - |
   | <---- session cookie, 302 / ---------- |                          |
```

What sets each part up:

1. **The operator provisions the client.** NebariApp `javo` has
   `auth.enabled: true`, `provisionClient: true`, `enforceAtGateway: false` and
   `redirectURI: /auth/oidc/callback`. That gives:
   - a confidential client `<namespace>-javo`;
   - redirect URI `https://<uiHost>/auth/oidc/callback`;
   - post-logout redirect `https://<uiHost>/*`;
   - the Secret `javo-oidc-client` holding `client-id`, `client-secret` and `issuer-url`.

   The operator creates no SecurityPolicy for it, so Envoy runs no login of its
   own in front of Javo.
2. **Javo reads the client from the Secret.** The javo chart mounts
   `javo-oidc-client` at `/etc/javo-oidc` (`javo.gateway.oidcClientSecret`).
   Javo's config names the issuer and client ID (`javo.config.auth.oidc`).
3. **Groups come from the ID token.** The NebariApp declares a group-membership
   mapper on Javo's client (claim `groups`, full path, in the ID token), which
   is where Javo reads groups. `javo.config.roles` maps groups to roles: by
   default `/javo-admins` holds platform and template admin, and every
   signed-in person is a member.
4. **The operator creates the admin group.** NebariApp `javo` lists `javo-admins`
   under `keycloakConfig.groups`, so the operator creates it and adds the
   usernames in `nebariapp.auth.keycloakGroups[].members`.
5. **Nebi trusts Javo's tokens (optional).** With `nebariapp.auth.nebiAudience`
   set to Nebi's client ID, an Audience mapper adds that client to the ID
   token's `aud`. Javo sends that token to Nebi to list the person's
   environments, and Nebi accepts only tokens whose audience names it.
6. **Apps get their own origin.** The apps host has its own NebariApp with no
   auth. When a signed-in person opens an app there, Javo sends them through a
   single-use ticket on the UI host, then sets a cookie valid for that app only.
   Javo checks every request on the apps host against the app's sharing, so
   anonymous visitors still reach public apps.

**Why the client ID is typed into the values.** Helm cannot pass values a
parent chart computes into a dependency. The javo values therefore repeat the
names the operator derives, and the chart refuses to render when they differ:
- `javo.config.auth.oidc.clientID` must be `<release namespace>-<nebariapp.name>`;
- `javo.gateway.oidcClientSecret` must be `<nebariapp.name>-oidc-client`.

**Two NebariApps.** The Nebari pack specification asks for one NebariApp per
pack. A NebariApp has one hostname, and Javo refuses sharing until apps have
their own origin, so this pack needs two. The second has no auth. See the
"nebari-operator integration" section of the gap analysis for the operator
change that would remove it.

## Install with Argo CD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: javo-pack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/nebari-dev/javo-pack.git
    targetRevision: main          # pin a release commit or tag
    path: .
    helm:
      releaseName: javo-pack
      valuesObject:
        nebariapp:
          auth:
            keycloakGroups:
              - name: javo-admins
                members: [admin]
        javo:
          publicHost: javo.example.com
          config:
            auth:
              oidc:
                issuer: https://keycloak.example.com/realms/nebari
                clientID: javo-javo        # <namespace>-<nebariapp.name>
            urls:
              uiHost: javo.example.com
              appsHost: javo-apps.example.com
  destination:
    server: https://kubernetes.default.svc
    namespace: javo
  # The javo chart makes the key of people's secrets once, as an immutable
  # Secret with a random value; Argo CD renders without cluster access, so
  # keep the live value.
  ignoreDifferences:
    - kind: Secret
      name: javo-secrets-key
      namespace: javo
      jsonPointers: [/data]
  syncPolicy:
    managedNamespaceMetadata:
      labels:
        nebari.dev/managed: "true"
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
```

To wire in Nebi environments (nebari-nebi-pack), add to the values:

```yaml
nebariapp:
  auth:
    nebiAudience: nebi-nebi-pack-nebari-nebi-pack   # nebi-pack's client ID
javo:
  config:
    nebi:
      enabled: true
      url: http://nebi-pack-nebari-nebi-pack.nebi.svc.cluster.local
```

Javo's issuer must equal Nebi's (`NEBI_AUTH_OIDC_ISSUER_URL` on the Nebi
Deployment).

Argo CD does not read `helm.sh/resource-policy: keep`. The javo chart puts that
annotation on the `javo-apps` namespace and the `javo-data` claim, which hold
people's data. Do not delete the Application with cascading deletion unless
you mean to delete that data.

## Install with Helm

```sh
helm dependency build .
kubectl create namespace javo
kubectl label namespace javo nebari.dev/managed=true
helm install javo-pack . -n javo -f examples/nebari-values.yaml
```

## Values

### This pack (`nebariapp`)

| Key | Default | Meaning |
|---|---|---|
| `nebariapp.enabled` | `true` | `false` renders only the javo chart (bring your own Ingress, TLS and OIDC client) |
| `nebariapp.name` | `javo` | NebariApp of the UI host; the operator names the client `<namespace>-<name>` and the Secret `<name>-oidc-client` |
| `nebariapp.appsName` | `javo-apps` | NebariApp of the apps host, rendered when `javo.config.urls.appsHost` is set and differs from `uiHost` |
| `nebariapp.service` | `javo-gateway:80` | The javo chart's gateway Service |
| `nebariapp.gateway` | `public` | Shared Gateway, `public` or `internal` |
| `nebariapp.auth.scopes` | `openid, profile, email` | Default scopes of Javo's client |
| `nebariapp.auth.groupsFullPath` | `true` | Groups as `/group` (true) or `group`; match any realm-wide groups scope |
| `nebariapp.auth.nebiAudience` | `""` | Nebi's client ID; required with `javo.config.nebi.enabled` |
| `nebariapp.auth.keycloakGroups` | `javo-admins`, no members | Realm groups the operator ensures, with members it adds (never removes) |
| `nebariapp.landingPage` | enabled, "Javo", Data Science | Landing-page card; icon defaults to `https://<uiHost>/favicon.svg`; health check `/healthz` |

### Javo (`javo`, passed to the javo chart)

Required per cluster:

| Key | Example |
|---|---|
| `javo.config.urls.uiHost` | `javo.example.com` |
| `javo.config.urls.appsHost` | `javo-apps.example.com` |
| `javo.publicHost` | `javo.example.com` (same as `uiHost`; Panel and Bokeh websocket origin) |
| `javo.config.auth.oidc.issuer` | `https://keycloak.example.com/realms/nebari` |
| `javo.config.auth.oidc.clientID` | `javo-javo` (`<namespace>-<nebariapp.name>`) |

Defaults this pack changes from the javo chart:

| Key | Pack default | Why |
|---|---|---|
| `javo.image` | `ghcr.io/nebari-dev/javo:0.1.0` | The published image |
| `javo.database.engine` | `sqlite`, 5Gi | See below |
| `javo.database.backup.schedule` | `""` (off) | Turn on with a cron schedule; add `javo.backupTarget` for off-cluster copies |
| `javo.gateway.secureCookies` | `true` | Served over HTTPS |
| `javo.gateway.oidcClientSecret` | `javo-oidc-client` | The operator's Secret |
| `javo.ingress.enabled` | `false` | The NebariApps route |
| `javo.config.auth.local.enabled` | `false` | Keycloak only |
| `javo.config.roles` | admins `/javo-admins`, everyone a member | |
| `javo.config.idleStop.defaultMinutes` | `60` | Free idle apps, as the data science pack's culler does; people may pick another timeout or Off |

Other values worth setting per cluster:
- `javo.database.sqlite.storageClass` and `javo.config.storage.home.storageClassName`, for example `longhorn` on Hetzner;
- `javo.sizes` and `javo.defaultSize`: sizes that fit the nodes;
- `javo.gateway.trustedProxies`: the pod CIDR, so login rate limits see real clients;
- `javo.config.mcp.publicURL`: `https://<uiHost>`.

The javo chart's `values.yaml` documents every other key.

**SQLite or Postgres.** SQLite is the default: one pod runs the gateway and the
controller, the database is a file on a volume, and nothing else needs to run
in the cluster. Javo stores only its own records there (people, apps, sharing,
jobs, sessions). The files people work on live in their homes. Use Postgres
(`javo.database.engine: postgres` with `javo.database.postgres.dsnSecret`) for
more than one gateway or controller replica. A cluster with CloudNativePG
(NIC on Hetzner has it) can provide the database and its backups.

## Publishing Javo

The pack pulls `oci://ghcr.io/nebari-dev/charts/javo` and `ghcr.io/nebari-dev/javo`,
which do not exist yet. In `nebari-dev/javo`:

1. Add [deploy-examples/javo-repo/release.yaml](deploy-examples/javo-repo/release.yaml)
   as `.github/workflows/release.yaml`. On a tag `vX.Y.Z` it:
   - builds the image for amd64 and arm64;
   - pushes `ghcr.io/nebari-dev/javo:X.Y.Z`;
   - sets the chart's default image to that tag and its digest;
   - pushes the chart as `oci://ghcr.io/nebari-dev/charts/javo` version `X.Y.Z`.

   It uses `GITHUB_TOKEN` with `packages: write`, so no secret is needed.
2. Tag `v0.1.0` and push the tag.
3. On GitHub, make both packages public (Package settings, Change visibility),
   or give every consumer a pull credential. The repository is private, so its
   packages start private, and the javo chart has no `imagePullSecrets` value.
4. In this repository, run `helm dependency build .` and commit `Chart.lock`.

To move to a new Javo release, bump `dependencies[0].version`, `appVersion` and
`javo.image.tag` together, then bump `version`.

Before the chart is published, develop against a checkout:

```sh
make -C dev vendor-javo JAVO_CHART_DIR=~/src/javo/deploy/helm/javo
```

This packages it into `charts/`, where `helm` uses it like a downloaded dependency.

## Local development

`dev/Makefile` builds a kind cluster with the Nebari stack from the operator's
own dev scripts (MetalLB, Envoy Gateway, cert-manager, Keycloak in dev mode,
nebari-operator `v0.1.2`). The kubeconfig stays in `dev/.cache/kubeconfig`.

```sh
make -C dev cluster                     # 5-10 minutes the first time
make -C dev vendor-javo JAVO_CHART_DIR=...   # until the chart is published
docker build -t javo:local ~/src/javo
make -C dev load-image JAVO_IMAGE=javo:local
make -C dev up HELM_ARGS="--set javo.image.repository=javo --set javo.image.tag=local"
make -C dev verify
make -C dev down
```

The operator's `install.sh` ends by adding the gateway IP to `/etc/hosts` with
`sudo`. Nothing here needs that entry.

`make verify` runs [dev/verify-signin.sh](dev/verify-signin.sh). It reaches
every host through port-forwards and checks, in order:

1. Both hosts answer through Envoy.
2. The landing-page icon loads without sign-in.
3. `/auth/oidc/start` sends the browser to Keycloak with Javo's client.
4. The realm user signs in and Keycloak returns to Javo's callback.
5. Javo starts a session, and `/api/me` shows the user with the `/javo-admins` group and the platform-admin role.
6. A container app starts, opens on the apps host after the ticket hop, and is deleted.

## What was verified

On a local kind cluster (operator `v0.1.2`), with the javo chart and an image
built from `nebari-dev/javo` at `fffde98` (the rename to javo):

- **Templates:**
  - `helm lint` and `helm template` pass with NebariApps enabled and disabled.
  - The chart refuses each mismatched value listed in `.github/workflows/lint.yaml`.
- **NebariApps:** both reach `Ready`. TLS comes from the shared wildcard listener, because the dev stack has no ClusterIssuer.
- **Keycloak client:** the operator creates `javo-javo`, the Secret `javo-oidc-client`, the realm group `javo-admins` with user `admin`, and the groups mapper.
- **End to end:** `make verify` passes all of its checks.
- **Audience mapper:** with `nebiAudience` set, an ID token from that client carried `aud: [javo-javo, <extra client>]`, and Javo still signed people in.

Not verified:
- **Real NIC cluster:** a deploy on one, with per-host Let's Encrypt certificates.
- **Nebi:** Nebi accepting Javo's token (Nebi was not run on kind).
- **CI:** the GitHub workflows, which need the published chart and image.

## CI

| Workflow | When | What |
|---|---|---|
| `lint.yaml` | push, PR | `helm lint`, `helm template` (NebariApps on and off), and refusal of mismatched values |
| `test.yaml` | push, PR | The local-development flow above on a kind runner: cluster, install, `make verify` |
| `release.yaml` | `Chart.yaml` change on main, manual | Package, GitHub release, `gh-pages` Helm index |

Actions are pinned to commit SHAs.

## Troubleshooting

- **The NebariApp reports `NamespaceNotOptedIn`.** Label the namespace
  `nebari.dev/managed=true`.
- **The sign-in page says the provider is unavailable.** The Javo pod cannot
  reach the issuer. Check `kubectl logs -n javo deploy/javo | grep oidc`. Javo
  discovers the issuer at its public URL from inside the cluster. Where that
  host does not resolve or route in-cluster, map it to the gateway Service with
  `javo.config.auth.oidc.dial`.
- **Keycloak says "Invalid parameter: redirect_uri".** `javo.config.urls.uiHost`
  differs from the host the client was provisioned for.
- **Admins have no admin tabs.** Check the groups Javo sees on `/api/me`. They
  must match `javo.config.roles` exactly, including the leading `/`.
- **The Environment card says Nebi did not accept the sign-in.** Set
  `nebariapp.auth.nebiAudience` to Nebi's client ID. Javo's issuer must also
  equal Nebi's `NEBI_AUTH_OIDC_ISSUER_URL`.

## License

Apache 2.0, see [LICENSE](LICENSE).
