#!/usr/bin/env bash
# Signs in to Javo through the Nebari gateway with a Keycloak user, with curl,
# on the kind cluster from dev/Makefile:
#
#   1. Javo answers on the UI host and on the apps host through Envoy (TLS from
#      the operator's per-host listeners).
#   2. /auth/oidc/start redirects to the operator-provisioned Keycloak client.
#   3. The Keycloak login form accepts the realm user.
#   4. Keycloak redirects to Javo's own callback; Javo exchanges the code and
#      sets its session.
#   5. /api/me answers as that user, with the groups from the client's mapper.
#
# Every host is reached through port-forwards (no /etc/hosts entry needed).
set -euo pipefail

NS=${NAMESPACE:-javo}
UI=${UI_HOST:-javo.nebari.local}
APPS=${APPS_HOST:-javo-apps.nebari.local}
KC_HOST=${KC_HOST:-keycloak-keycloakx-http.keycloak.svc.cluster.local}
# The realm user the operator's dev setup script creates (dev-only defaults).
KC_USER=${KC_USER:-admin}
KC_PASSWORD=${KC_PASSWORD:-nebari-admin}
GW_PORT=${GW_PORT:-18443}
# The image of the test app (the nginx the static-site template uses).
APP_IMAGE=${APP_IMAGE:-nginxinc/nginx-unprivileged:1.31.6-alpine-slim@sha256:ac4d9c7e457c6510b95ac72dd84b27f7cc68ecb9a83fbd44f05a6460cf08aba4}
KC_PORT=${KC_PORT:-18080}

work=$(mktemp -d)
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; if [ -n "${KEEP:-}" ]; then echo "kept $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

gw_svc=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=nebari-gateway -o name | head -1)
kubectl port-forward -n envoy-gateway-system "$gw_svc" "$GW_PORT:443" >"$work/pf-gw.log" 2>&1 &
pids+=($!)
kubectl port-forward -n keycloak svc/keycloak-keycloakx-http "$KC_PORT:80" >"$work/pf-kc.log" 2>&1 &
pids+=($!)

jar="$work/cookies"
c() {
  curl -sk --max-time 15 -b "$jar" -c "$jar" \
    --connect-to "$UI:443:127.0.0.1:$GW_PORT" \
    --connect-to "$APPS:443:127.0.0.1:$GW_PORT" \
    --connect-to "$KC_HOST:80:127.0.0.1:$KC_PORT" "$@"
}

for _ in $(seq 1 30); do
  c -o /dev/null "https://$UI/healthz" && break
  sleep 1
done

step() { printf '%-60s' "$1"; }
ok() { echo "ok${1:+ ($1)}"; }
die() { echo "FAILED: $1"; exit 1; }

step "UI host answers through the gateway"
code=$(c -o /dev/null -w '%{http_code}' "https://$UI/healthz")
[ "$code" = 200 ] && ok "$code" || die "GET https://$UI/healthz -> $code"

step "Apps host answers through the gateway"
code=$(c -o /dev/null -w '%{http_code}' "https://$APPS/healthz")
[ "$code" = 200 ] && ok "$code" || die "GET https://$APPS/healthz -> $code"

step "Landing page icon is served without sign-in"
code=$(c -o /dev/null -w '%{http_code}' "https://$UI/favicon.svg")
[ "$code" = 200 ] && ok "$code" || die "GET https://$UI/favicon.svg -> $code"

step "Sign-in starts at Keycloak with Javo's client"
auth_url=$(c -o /dev/null -w '%{redirect_url}' "https://$UI/auth/oidc/start")
case "$auth_url" in
  "http://$KC_HOST/"*"client_id=$NS-javo"*) ok ;;
  *) die "redirect was: $auth_url" ;;
esac

step "Keycloak shows its login form"
c -o "$work/login.html" "$auth_url"
action=$(grep -o 'action="[^"]*login-actions/authenticate[^"]*"' "$work/login.html" | head -1 \
  | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
[ -n "$action" ] && ok || die "no login form in Keycloak's page"
# Dev Keycloak serves plain HTTP but marks its login-session cookies Secure,
# which curl then never sends back over http. Clear the flag on Keycloak's
# cookies in the jar (a browser makes the same exception for localhost only).
awk -v h="$KC_HOST" 'BEGIN{FS=OFS="\t"} ($1==h || $1=="#HttpOnly_" h) {$4="FALSE"} {print}' "$jar" >"$jar.tmp" && mv "$jar.tmp" "$jar"

step "Keycloak accepts $KC_USER and returns to Javo's callback"
callback=$(c -w '%{redirect_url}' \
  --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASSWORD" \
  -o "$work/post.html" "$action")
case "$callback" in
  "https://$UI/auth/oidc/callback?"*) ok ;;
  *) die "redirect was: '$callback' (rerun with KEEP=1 and read $work/post.html)" ;;
esac

step "Javo exchanges the code and starts a session"
code=$(c -o /dev/null -w '%{http_code}' "$callback")
case "$code" in 302|303) ok "$code" ;; *) die "callback -> $code" ;; esac

step "Javo knows the user"
c "https://$UI/api/me" >"$work/me.json"
grep -q "\"$KC_USER\"" "$work/me.json" && ok || die "$(cat "$work/me.json")"
echo "  $(cat "$work/me.json")"

# An app on the apps host: a Container image app serving nginx, opened through
# the single-use ticket hop from the UI host to the apps host. Skip with
# APP_CHECK=0 (it pulls the nginx image on first run).
if [ "${APP_CHECK:-1}" = 1 ]; then
  step "Javo creates an app (Container image, nginx)"
  # The app has no login of its own, so Javo creates it only once its
  # NetworkPolicy probe has seen the policy enforced. The first probe runs as
  # Javo starts and can end Unknown; it tries again after 30 s, then 60 s.
  for try in $(seq 1 12); do
    c -o "$work/app.json" -w '%{http_code}' -H 'Content-Type: application/json' -H 'X-Javo-Request: 1' \
      -d "{\"displayName\":\"Pack check $(date +%s)\",\"template\":\"container\",\"image\":\"$APP_IMAGE\",\"port\":8080}" \
      "https://$UI/api/workspaces" >"$work/code"
    grep -q 'does not enforce NetworkPolicy' "$work/app.json" || break
    [ "$try" = 1 ] && echo "  waiting for Javo's NetworkPolicy probe"
    sleep 10
  done
  case "$(cat "$work/code")" in 200|201) ok ;; *) die "$(cat "$work/code") $(cat "$work/app.json")" ;; esac
  name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$work/app.json" | head -1)

  step "The app runs"
  for _ in $(seq 1 90); do
    c "https://$UI/api/workspaces/$name" >"$work/app.json"
    grep -q '"phase":"Running"' "$work/app.json" && break
    sleep 2
  done
  grep -q '"phase":"Running"' "$work/app.json" && ok || die "$(cat "$work/app.json")"
  url=$(sed -n 's/.*"url":"\([^"]*\)".*/\1/p' "$work/app.json" | head -1)

  step "The app opens on the apps host after the ticket hop"
  case "$url" in "https://$APPS/"*) ;; *) die "app URL is $url, not on $APPS" ;; esac
  c -L -o "$work/page.html" -w '%{http_code} %{url_effective}' "$url" >"$work/code"
  read -r code final <"$work/code" || true
  [ "$code" = 200 ] && grep -qi "welcome to nginx" "$work/page.html" && case "$final" in "https://$APPS/"*) true ;; *) false ;; esac \
    && ok "$code" || die "$code at $final"

  step "Javo deletes the app"
  code=$(c -o /dev/null -w '%{http_code}' -H 'X-Javo-Request: 1' -X DELETE "https://$UI/api/workspaces/$name")
  case "$code" in 200|202|204) ok "$code" ;; *) die "DELETE -> $code" ;; esac
fi
