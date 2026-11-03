<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/nebari-dev/javo/main/brand/javo-logo-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/nebari-dev/javo/main/brand/javo-logo.svg">
    <img src="https://raw.githubusercontent.com/nebari-dev/javo/main/brand/javo-logo.svg" alt="Javo" width="320">
  </picture>
</p>

<p align="center"><b>Javo on Nebari: notebooks, apps and jobs for data teams.</b></p>

> [!WARNING]
> **This pack and Javo are experimental.** Values and resources may change between releases without a migration path, and neither has run in production yet. Use a test cluster.

A Nebari software pack for [Javo](https://github.com/nebari-dev/javo). It installs the javo chart and two `NebariApp` resources, so the nebari-operator routes Javo's UI and apps hosts through the Envoy Gateway, gives them TLS, and creates Javo's Keycloak client.

## Requirements

- A NIC cluster with nebari-operator `v0.1.2` or later, Envoy Gateway, cert-manager and Keycloak.
- DNS for two hosts, `javo.<domain>` and `javo-apps.<domain>` (a wildcard covers both).
- A CNI that enforces NetworkPolicy (k3s does): apps have no login of their own, and the policy keeps other pods out.

## Install

With Helm:

```sh
helm dependency build .
kubectl create namespace javo
kubectl label namespace javo nebari.dev/managed=true
helm install javo-pack . -n javo --set global.domain=example.com
```

With Argo CD, point an Application at this repository (`path: .`) with the same values, and set `managedNamespaceMetadata.labels: {nebari.dev/managed: "true"}` on the release namespace.

The one value to set is the cluster's domain ([examples/nebari-values.yaml](examples/nebari-values.yaml)):

```yaml
global:
  domain: example.com
```

From it and the release namespace the pack derives:

| What | Default |
|---|---|
| UI and apps hosts | `javo.<domain>`, `javo-apps.<domain>` |
| Keycloak issuer | `https://keycloak.<domain>/realms/nebari` |
| Keycloak client and its Secret | `<namespace>-javo`, `javo-oidc-client` (the operator creates both) |
| Javo admins | Keycloak group `javo-admins`, with NIC's realm admin `admin` in it |
| Nebi (off) | `javo.config.nebi.enabled: true` uses nebi-pack's names when it is installed as release `nebi-pack` in namespace `nebi` |
| Storage | the cluster's default StorageClass, one disk per person |

Set any of them to override it, for example `javo.config.urls.uiHost: hub.example.org` or more admins under `nebariapp.auth.keycloakGroups`. Everything else is the [javo chart's values](https://github.com/nebari-dev/javo/blob/main/deploy/helm/javo/values.yaml), under `javo:`.

## Docs

Javo's documentation is at [javo.nebari.dev](https://javo.nebari.dev). Moving from the data science pack: [docs/replacing-data-science-pack.md](docs/replacing-data-science-pack.md).

## License

Apache-2.0
