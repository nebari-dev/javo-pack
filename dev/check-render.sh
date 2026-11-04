#!/bin/sh
# Renders the pack with helm template and checks what the values derive:
# the domain alone gives both hosts, the Keycloak issuer, the client ID and
# the Nebi names; explicit values still win; values that would point Javo at
# a client or Secret the operator does not create are refused.
#
# Usage (from the repository root, after helm dependency build):
#   dev/check-render.sh
set -eu

out=$(mktemp)
trap 'rm -f "$out"' EXIT
failed=0

# Javo refuses to render without ValidatingAdmissionPolicy, which every
# supported cluster (Kubernetes 1.30+) serves; helm template sees no cluster.
API_VERSIONS="--api-versions admissionregistration.k8s.io/v1/ValidatingAdmissionPolicy"

# render <args>: helm template into $out; the check fails if it does not render.
render() {
  if ! helm template javo-pack . $API_VERSIONS "$@" >"$out" 2>&1; then
    echo "FAIL: did not render: $*"; sed 's/^/  /' "$out"; failed=1; return 1
  fi
}

# has <text> / lacks <text>: the last render does (not) contain the line.
has() {
  grep -qF -- "$1" "$out" || { echo "FAIL: render lacks '$1'"; failed=1; }
}
# has_after <line> <next>: a line containing next follows one containing line.
has_after() {
  awk -v a="$1" -v b="$2" 'prev && index($0, b) { found = 1 } { prev = index($0, a) } END { exit !found }' "$out" ||
    { echo "FAIL: render lacks '$1' followed by '$2'"; failed=1; }
}
lacks() {
  if grep -qF -- "$1" "$out"; then echo "FAIL: render has '$1'"; failed=1; fi
}

# fails <message> <args>: helm template refuses the values, saying message.
fails() {
  msg=$1; shift
  if helm template javo-pack . $API_VERSIONS "$@" >"$out" 2>&1; then
    echo "FAIL: rendered, but should have failed: $*"; failed=1
  elif ! grep -qF -- "$msg" "$out"; then
    echo "FAIL: refused without '$msg': $*"; sed 's/^/  /' "$out"; failed=1
  fi
}

minimal="-n javo --set global.domain=example.com"

# The minimal NIC values: the domain.
if render $minimal; then
  has "hostname: javo.example.com"
  has "hostname: javo-apps.example.com"
  has "uiHost: javo.example.com"
  has "appsHost: javo-apps.example.com"
  has "issuer: https://keycloak.example.com/realms/nebari"
  has "clientID: javo-javo"
  has "- --public-host=javo.example.com"
  has "- --trusted-proxies=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  has "icon: \"https://javo.example.com/favicon.svg\""
  has "mode: perUser"
  has_after "members:" "- admin"
  lacks "nebi-audience"
  lacks ".Values.global"
  lacks ".Release.Namespace"
fi

# The client ID follows the release namespace.
if render -n other --set global.domain=example.com; then
  has "clientID: other-javo"
fi

# Nebi from nebi-pack under its standard names: one switch.
if render $minimal --set javo.config.nebi.enabled=true; then
  has "included.client.audience: \"nebi-nebi-pack-nebari-nebi-pack\""
  has "url: http://nebi-pack-nebari-nebi-pack.nebi.svc.cluster.local"
fi

# Explicit values win over the derived ones.
if render $minimal \
  --set javo.config.urls.uiHost=hub.example.org \
  --set javo.config.urls.appsHost=apps.example.org \
  --set javo.config.auth.oidc.issuer=https://sso.example.org/realms/team \
  --set javo.publicHost=hub.example.org \
  --set 'javo.gateway.trustedProxies={10.42.0.0/16}' \
  --set javo.config.storage.home.mode=auto; then
  has "hostname: hub.example.org"
  has "hostname: apps.example.org"
  has "issuer: https://sso.example.org/realms/team"
  has "- --public-host=hub.example.org"
  has "- --trusted-proxies=10.42.0.0/16"
  has "mode: auto"
  lacks "example.com"
fi

# Explicit hosts and issuer need no domain.
if render -n javo --set javo.config.urls.uiHost=hub.example.org \
  --set javo.config.urls.appsHost=apps.example.org \
  --set javo.config.auth.oidc.issuer=https://sso.example.org/realms/team; then
  has "hostname: hub.example.org"
fi

fails "global.domain" -n javo
# The javo chart refuses an empty UI host before the pack's own check runs.
fails "config.auth.oidc needs the UI's host" $minimal --set javo.config.urls.uiHost=
fails "javo.config.auth.oidc.issuer is" $minimal --set javo.config.auth.oidc.issuer=
fails "global.domain" -n javo --set javo.config.urls.uiHost=hub.example.org
fails "clientID must be" $minimal --set javo.config.auth.oidc.clientID=wrong
fails "oidcClientSecret must be" $minimal --set javo.gateway.oidcClientSecret=wrong
fails "mode must be path" $minimal --set javo.config.urls.mode=subdomain --set javo.config.urls.appsDomain=apps.example.com
fails "nebiAudience is required" $minimal --set javo.config.nebi.enabled=true --set nebariapp.auth.nebiAudience=
fails "publicHost must equal" $minimal --set javo.publicHost=other.example.com

if [ "$failed" != 0 ]; then
  echo "render checks failed"; exit 1
fi
echo "render checks passed"
