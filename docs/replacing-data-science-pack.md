# Replacing the data science pack with Javo

This compares, feature by feature, what the data science pack (JupyterHub with
jhub-apps) gives a NIC cluster and what Javo gives it through this pack. For
each gap it names the work needed.

**Sources.** Every claim cites a file. Paths are relative to these trees:

| Prefix | Repository and commit |
|---|---|
| `dsp:` | `nebari-dev/nebari-data-science-pack`, `origin/main` at `8f5f087` (chart 0.1.7) |
| `javo:` | `nebari-dev/javo` at `fffde98` ("Rename wsp to javo") |
| `japps:` | `nebari-dev/jhub-apps`, local checkout at `15e9263` |
| `op:` | `nebari-dev/nebari-operator` at tag `v0.1.2` |
| `pack:` | this repository |

## Summary

| Area | Data science pack | Javo on NIC | Gap |
|---|---|---|---|
| Sign-in | Hub is its own Keycloak client | Javo is its own Keycloak client | None |
| JupyterLab | Image with JupyterLab 4.6 and many extensions | JupyterLab 4.6.4 from a locked pixi environment | Extensions, user package installs, multi-kernel |
| App types | 8 jhub-apps frameworks | 23 templates: notebooks, dashboards, web, agents, jobs | None. Javo has more |
| Environments | Nebi (server and per-pod), Nebi kernels | Nebi environment per app, repo lockfiles | No kernels from other environments, no in-pod installs |
| Group gating | Profiles gated by groups or a Keycloak role | Templates and sizes gated by groups | No Keycloak-role gating |
| Shared storage | `/shared/<group>` on one RWX volume | `/shared/<group>` per-group folder claims | Folders are created by CLI, not automatically per group |
| Idle culling | Hub culler (30 min) plus kernel culler (15 min) | Idle stop per app (pack default 60 min) | No kernel-level culling |
| GPU | Profiles with GPU image variant | GPU sizes (count, resource, node selector, tolerations) | No GPU image for JupyterLab |
| Admin | JupyterHub admin panel | All apps, Usage, Backups, Storage | No start/stop or impersonation of other users |
| Operator integration | One NebariApp, app-level auth | Two NebariApps, app-level auth | Two NebariApps, against the spec's "exactly one" |
| Home data | `claim-<user>` at `/home/jovyan` (uid 1000) | `home-<slug>` at `/home/user` (allocated uid) | No import; needs a migration job |
| Argo CD | Secrets handled with annotations | Immutable random Secret, Helm-only keep annotations | Needs `ignoreDifferences`; chart should add Argo annotations |

## Sign-in and Keycloak

- **DSP:**
  - The NebariApp provisions a Keycloak client with `redirectURI: /hub/oauth_callback` and `enforceAtGateway: false` (`dsp:values.yaml`, `nebariapp.auth`, lines 87-109).
  - The hub runs `KeyCloakOAuthenticator`, a `GenericOAuthenticator` subclass (`dsp:config/jupyterhub/00-gateway-auth.py:293`, set at `:565`).
  - Admins come from `admin_groups`, default `/admin` (`:587`).
- **Javo:**
  - Javo runs the authorization code flow with PKCE and a nonce, calling back at `/auth/oidc/callback` (`javo:internal/features/authoidc/oidc.go:38-41`).
  - It reads `sub`, `email`, `name`, `picture`, the username claim and a dotted-path groups claim from the ID token (`javo:internal/features/authoidc/claims.go:18-39`).
  - Roles come from groups: `config.roles.platformAdmin`, `templateAdmin` and `member` (`javo:internal/config/config.go`, `Roles`).
- **This pack:** the NebariApp sets the same shape as DSP (`pack:templates/nebariapp.yaml`):
  - It provisions the client with `enforceAtGateway: false` and Javo's callback.
  - It adds a full-path groups mapper and, optionally, a Nebi audience mapper (`op:internal/controller/reconcilers/auth/providers/keycloak.go`, `syncClientProtocolMappers`).
  - It has the operator create a realm group, `javo-admins`, that the default roles map to platform admin.
- **Gap:** none. Verified on kind: the realm user signed in through the gateway and Javo reported `groups: ["/javo-admins"]` and role `platform-admin` (README, "What was verified").

## JupyterLab

- **DSP:**
  - The `jupyterlab` image target (`dsp:images/Dockerfile:119`) is built from `dsp:images/jupyterlab/pixi.toml`.
  - That file pins JupyterLab 4.6.2 (`:15`) and adds jupyter-server-proxy (`:13`), jupyterlab-git (`:24`), jhub-apps (`:78`), the Nebi tile (`dsp:images/nebi/jupyter_server_config.py`), code-server and Dask.
  - Homes are writable and persistent, so users can `pip install` into them.
- **Javo:**
  - The `jupyterlab` template (`javo:deploy/helm/javo/files/templates/jupyterlab.yaml`) runs JupyterLab 4.6.4 with ipykernel, ipywidgets and papermill.
  - That environment is a locked pixi environment (`javo:deploy/pod/envs/jupyterlab/pixi.toml`, `pixi.lock`), installed into the home at start (`javo:internal/pixienv/pixienv.go:1-14`).
  - The template is limited to Private sharing (`jupyterlab.yaml:13`).
  - Its terminal and VS Code (`javo:deploy/helm/javo/files/templates/vscode.yaml`) and RStudio (`rstudio.yaml`) are separate templates.
- **Gaps:**
  1. **Lab extensions.** jupyterlab-git, the Dask labextension and jupyter-server-proxy are not in Javo's environment.
     - **Work:** add them to `deploy/pod/envs/jupyterlab/pixi.toml` and re-lock.
  2. **Installing packages in the running Lab.** Javo installs only frozen lockfiles (`javo:site/src/content/docs/using/environments.md`). A `pip install` in a Lab terminal lands in a reinstalled environment folder, and Javo documents no way to keep it.
     - **Work:** decide the model. Either "edit pixi.toml in the home and restart", which needs Javo to read an unlocked `pixi.toml` from the home, or point people at Nebi environments.
  3. **Kernels from several environments in one Lab.** DSP ships nb-nebi-kernels (`dsp:images/jupyterlab/pixi.toml:75`), so every Nebi workspace shows up as a kernel. Javo runs one environment per app; no kernelspec code was found.
     - **Work:** add `nb-nebi-kernels`, or an equivalent kernel spec manager over `~/.javo/envs`, to the Lab environment.

## App types (jhub-apps)

- **DSP:**
  - jhub-apps offers Panel, Bokeh, Streamlit, Voila, PlotlyDash, Gradio, Custom Command and JupyterLab (`japps:jhub_apps/spawner/types.py:42-90`).
  - Frameworks can be limited with `allowed_frameworks` (`dsp:config/jupyterhub/02-jhub-apps.py:38`).
- **Javo:** 23 built-in templates (`javo:deploy/helm/javo/files/templates/`).
  - **Notebooks:** JupyterLab, marimo, Pluto, RStudio, VS Code.
  - **Dashboards:** Bokeh, Dash, Gradio, Panel, Streamlit, Voila.
  - **Web:** FastAPI, Go, Node, static site, custom command, container image.
  - **Agents:** Claude Code, pi, herdr.
  - **Jobs:** Python, R, Julia, command; scheduled with cron (`javo:site/src/content/docs/using/jobs.mdx`).
  - **From a repository:** apps run from a Git repository with pull-request previews (`javo:site/src/content/docs/using/previews.md`).
  - **Disabling templates:** `workspaceTemplates.<name>.enabled` per template.
- **Gap:** none in coverage.
  - **Work:** tell existing jhub-apps users that "PlotlyDash" is "Dash" in Javo.
  - **Work:** recreate their apps by hand. There is no importer from jhub-apps' app records; Javo's export/import carries Javo apps only (`javo:internal/transfer/transfer.go`).

## Nebi environments and conda-store

- **DSP:**
  - The hub lists Nebi environments for the jhub-apps environment selector (`dsp:config/jupyterhub/03-nebi-envs.py:1`).
  - It exchanges the hub's access token for a Nebi token at spawn (same file), and copies the nebi binary into user pods (`dsp:values.yaml`, `nebi.image`).
  - There is no conda-store.
- **Javo:**
  - New app and New job list the person's Nebi workspaces. Javo sends the person's ID token to Nebi's `POST /api/v1/auth/device-token` and copies the chosen version's `pixi.toml` and `pixi.lock` in (`javo:internal/features/envnebi/nebi.go`).
  - A repository's own lockfile is used when present (`javo:internal/pixienv/pixienv.go`).
  - There is no conda-store (searched; no hits).
- **This pack:**
  - `nebariapp.auth.nebiAudience` adds an Audience mapper so Javo's ID tokens name Nebi's client.
  - Nebi checks that audience (`javo:docs/operations/nebi.md`, "How the gateway signs in to Nebi").
  - The deployed Nebi (`sha-8b9fdd3`) serves that endpoint (`nebi:internal/api/router.go:176` at that commit).
  - Verified on kind: with the mapper set, the ID token's `aud` held both clients and Javo still accepted it. Nebi itself was not run.
- **Gaps:**
  1. **No Nebi tile or CLI inside the Lab.** DSP runs Nebi in the Lab.
     - **Work:** add the nebi binary to the Lab environment if wanted.
  2. **The environment is fixed when the app is created** (`javo:site/src/content/docs/admin/nebi.md`, "Limits").

## Groups and profile gating

- **DSP:** profiles can be gated three ways (`dsp:values.yaml`, profile comments around line 511; `dsp:config/jupyterhub/01-spawner.py:430`, `_filter_profiles`):
  - `access: yaml`, by groups or usernames.
  - `access: keycloak`, by a `jupyterlab-profiles` client role whose `profiles` attribute lists the allowed slugs.
- **Javo:**
  - Templates carry `allowedGroups` and `allowedUsers` (`javo:internal/model/template.go:148-149`, enforced in `javo:internal/authz/authz.go:321-328`).
  - Sizes carry `allowedGroups` (`javo:internal/sizes/sizes.go:43-45`, `authz.go:349-353`).
  - Custom CPU and memory are allowed per role or group (`javo:internal/sizes/sizes.go:135-140`).
- **Gap:** no gating by a Keycloak client role with an attribute list. Javo reads one groups claim (a dotted path, so `resource_access.<client>.roles` works), not role attributes.
  - **Work:** express each DSP `access: keycloak` allow-list as a Keycloak group and list it in `allowedGroups`. Alternatively, point `groupsClaim` at client roles. The operator can create the groups (`keycloakConfig.groups`).

## Shared storage

- **DSP:**
  - One RWX volume holds every group's folder. Each group the user is in is mounted at `/shared/<group>`, optionally limited by an allow-list (`dsp:values.yaml`, `sharedStorage`, lines 204-230).
  - An in-cluster NFS server provides RWX when the cluster has none.
- **Javo:**
  - Shared folders are one claim per group, mounted at `/shared/<group>` with the group's allocated gid (`javo:internal/storage/podstorage/podstorage.go:22-27, 66-69, 106-112`; claim name `folder-<name>`, `javo:internal/naming/naming.go:144-147`).
  - Homes are a disk per person or one shared drive, chosen from what the cluster offers (`config.storage.home.mode`, `javo:site/src/content/docs/admin/storage.md`).
- **Gap:** folders are not created automatically for every group. An admin adds each one with `javo storage folder add <group>` (`javo:cmd/javo/storage.go:215-272`).
  - **Work:** a values list of groups the chart creates folders for, or a setting that creates a folder on first use by a group member.

## Idle culling

- **DSP:**
  - The hub culler stops servers after 30 minutes (`dsp:values.yaml`, `jupyterhub.cull`, `timeout: 1800`).
  - The in-pod culler stops idle kernels and terminals after 15 minutes, even with tabs open (`singleuserCuller`, lines 164-180).
- **Javo:**
  - Idle stop per app, off by default (`javo:deploy/helm/javo/values.yaml`, `config.idleStop`).
  - Any request or open connection through the gateway counts as use (`javo:internal/activity/activity.go`). The leader stops idle apps every 30 seconds (`javo:internal/controller/idle/idle.go`).
  - This pack sets a default of 60 minutes (`pack:values.yaml`).
- **Gap:** an open JupyterLab tab keeps an app alive, because its websocket counts as use. DSP's in-pod culler exists precisely for that case.
  - **Work:** add an in-pod kernel and terminal culler to the Lab environment, using the same `ServerApp`/`MappingKernelManager` settings DSP uses. Or have Javo's activity tracker ignore idle websockets.

## GPU

- **DSP:**
  - GPU profiles request `nvidia.com/gpu`.
  - `image-variant: gpu` swaps in the `-gpu` JupyterLab image (`dsp:values.yaml`, profile comments). That image is built from the same Dockerfile with the `GPU` build argument, which puts the NVIDIA driver paths on `PATH` and `LD_LIBRARY_PATH` (`dsp:images/Dockerfile:70-77`).
- **Javo:**
  - Sizes carry a GPU count, a GPU resource name, a node selector and tolerations (`javo:internal/sizes/sizes.go:20-38`, applied at `:69-106`).
  - Sizes that fit no node are refused (`javo:internal/capacity/capacity.go`).
- **Gap:** no CUDA environment for JupyterLab. Javo's environments come from conda-forge locks, not an image.
  - **Work:** add a `jupyterlab-gpu` pixi environment (conda-forge `cuda` packages) or a GPU template that uses it.

## Admin

- **DSP:** the JupyterHub admin panel (JupyterHub 5.5.0, `dsp:images/jupyterhub/pixi.toml:14`) lists users and servers, and starts, stops and opens other users' servers.
- **Javo:** Settings has four admin tabs (`javo:ui/src/App.tsx:36-46`, `javo:ui/src/routes/Settings.tsx:282-285`):
  - **All apps:** every app, with stop and delete.
  - **Usage:** running time per person and per group (`javo:internal/usage/usage.go`).
  - **Backups:** database copies, restic home backups and Velero (`javo:site/src/content/docs/admin/backups.mdx`).
  - **Storage:** home modes and migration.

  User accounts come from Keycloak. Local accounts are managed only with the CLI (`javo:cmd/javo/user.go`).
- **Gap:** no way for an admin to open another person's Private app the way JupyterHub's "access server" does.
  - **Work:** none if this is deliberate (Javo checks sharing on every request). Otherwise, an audited admin access path.

## nebari-operator integration

- **DSP:** one NebariApp with a landing-page card (`dsp:templates/nebariapp.yaml`).
- **This pack:** two NebariApps, one for the UI host and one for the apps host (`pack:templates/nebariapp.yaml`).
  - **Why two:** a NebariApp has one `hostname` (`op:api/v1/nebariapp_types.go:31`). Javo refuses sharing beyond Private unless apps are on another origin (`javo:site/src/content/docs/admin/app-addresses.md`).
  - **Subdomain mode:** it would need a wildcard host, and the hostname pattern does not allow one. The chart refuses it.
  - **Conflict with the spec:** the Nebari pack specification asks for exactly one NebariApp per pack (`nebari-operator` `docs/pack-specification.md`, section 1, on `main`).
- **Gap:**
  - **Work, operator:** add extra hostnames to a NebariApp (`spec.additionalHostnames`), each routed and given a certificate, with auth on the primary host only. Then the pack goes back to one NebariApp.
  - **Work, spec:** alternatively, amend the spec to allow a second auth-less NebariApp for a separate origin.

## Data migration (user homes)

- **DSP:** each user's home is the PVC `claim-<username>` in the hub's namespace, mounted at `/home/jovyan` (`dsp:config/jupyterhub/01-spawner.py:37-68`). Files are owned by the image user, uid 1000.
- **Javo:**
  - Homes are PVCs named `home-<slug>` in the workspace namespace (`javo:internal/naming/naming.go:107-120`), mounted at `/home/user` (`javo:internal/storage/podstorage/podstorage.go:22-27`).
  - Each person has an allocated uid from 100000 to 199999 (`javo:deploy/helm/javo/values.yaml`, `config.identity`).
  - Javo adopts an existing claim by name only when it carries Javo's owner label (`javo:internal/controller/storage/home.go:211-228`).
  - Javo has no importer for outside data. Its storage migration moves homes between Javo's own modes only (`javo:cmd/javo/storage_migrate.go`).
- **Gap:** moving a DSP home means three things:
  1. Moving the data across namespaces. PVCs are namespaced, so either rebind the PV, or copy.
  2. Renaming it to `home-<slug>` with the owner label.
  3. Changing ownership from uid 1000 to the person's allocated uid. The uid exists only after their first Javo sign-in.
- **Work:** a `javo home import` command. For each person who has signed in, it would:
  1. Copy `claim-<user>` into their Javo home with the existing homecopy code (`javo:internal/storage/homecopy/homecopy.go`), from a pod that mounts the source PV.
  2. Run `chown -R` to the allocated uid.
  3. Leave the DSP claim untouched for rollback.
  
  Matching DSP usernames (the Keycloak `preferred_username`) to Javo identities (`sub`) needs the issuer and subject. Both packs use the same realm, so the match is direct.

## Argo CD

- The javo chart makes the key of people's secrets once, as an immutable Secret with a random value, and keeps it with `helm.sh/resource-policy: keep` (`javo:deploy/helm/javo/templates/secrets-key.yaml`).
  - Argo CD renders without cluster access, so each render has a new value.
  - This pack's Argo CD example ignores that Secret's data (`pack:README.md`, "Install with Argo CD": `ignoreDifferences` with `RespectIgnoreDifferences=true`).
- The workspace namespace and the SQLite claim carry only Helm's keep annotation, which Argo CD does not read.
  - **Risk:** a cascading delete of the Application, or a prune, removes them, homes included.
  - **Work, javo chart:** add `argocd.argoproj.io/sync-options: Prune=false,Delete=false` next to `helm.sh/resource-policy: keep`, and an `imagePullSecrets` value for private registries.
