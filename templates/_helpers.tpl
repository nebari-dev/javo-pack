{{/*
Chart name and labels.
*/}}
{{- define "javo-pack.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "javo-pack.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "javo-pack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
The Keycloak client ID and client Secret name the operator gives the UI
NebariApp (nebari-operator: <namespace>-<name> and <name>-oidc-client).
*/}}
{{- define "javo-pack.clientID" -}}
{{- printf "%s-%s" .Release.Namespace .Values.nebariapp.name -}}
{{- end }}

{{- define "javo-pack.clientSecretName" -}}
{{- printf "%s-oidc-client" .Values.nebariapp.name -}}
{{- end }}

{{/*
A javo value as the javo chart renders it: values may be templates of
.Values.global and .Release, which read the same here. (list $ value)
*/}}
{{- define "javo-pack.tpl" -}}
{{- $v := index . 1 -}}
{{- if $v }}{{ tpl (toString $v) (index . 0) }}{{ end -}}
{{- end }}

{{- define "javo-pack.uiHost" -}}
{{- include "javo-pack.tpl" (list . .Values.javo.config.urls.uiHost) -}}
{{- end }}

{{- define "javo-pack.issuer" -}}
{{- $oidc := (default (dict) .Values.javo.config.auth).oidc | default (dict) -}}
{{- include "javo-pack.tpl" (list . $oidc.issuer) -}}
{{- end }}

{{/*
The apps host, when apps are served on a host of their own: empty otherwise.
*/}}
{{- define "javo-pack.appsHost" -}}
{{- $apps := include "javo-pack.tpl" (list . .Values.javo.config.urls.appsHost) -}}
{{- if and $apps (ne $apps (include "javo-pack.uiHost" .)) -}}
{{- $apps -}}
{{- end -}}
{{- end }}

{{/*
Fails unless host is a DNS name with no empty label: a derived host is
javo. or keycloak./ when global.domain is not set. (list key host)
*/}}
{{- define "javo-pack.requireHost" -}}
{{- $key := index . 0 -}}
{{- $host := index . 1 -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]+)?$" $host) -}}
{{- fail (printf "%s is %q: set global.domain to the cluster's domain (for example example.com), or set %s" $key $host $key) -}}
{{- end -}}
{{- end }}

{{/*
Fails the render when the javo values do not match what the NebariApps make
the operator create. Helm cannot pass computed values to a dependency, so the
javo values are literal and checked here instead.
*/}}
{{- define "javo-pack.validate" -}}
{{- $j := .Values.javo -}}
{{- $urls := $j.config.urls -}}
{{- $oidc := (default (dict) $j.config.auth).oidc | default (dict) -}}
{{- $uiHost := include "javo-pack.uiHost" . -}}
{{- include "javo-pack.requireHost" (list "javo.config.urls.uiHost" $uiHost) -}}
{{- with include "javo-pack.tpl" (list . $urls.appsHost) -}}
{{- include "javo-pack.requireHost" (list "javo.config.urls.appsHost" .) -}}
{{- end -}}
{{- if ne (default "path" $urls.mode) "path" -}}
{{- fail "javo.config.urls.mode must be path: subdomain mode needs a wildcard host, which a NebariApp cannot route" -}}
{{- end -}}
{{- $issuer := include "javo-pack.issuer" . -}}
{{- include "javo-pack.requireHost" (list "javo.config.auth.oidc.issuer" ((urlParse $issuer).host | default "")) -}}
{{- $clientID := include "javo-pack.clientID" . -}}
{{- if ne (include "javo-pack.tpl" (list . $oidc.clientID)) $clientID -}}
{{- fail (printf "javo.config.auth.oidc.clientID must be %q, the client the operator provisions for NebariApp %q in namespace %q" $clientID .Values.nebariapp.name .Release.Namespace) -}}
{{- end -}}
{{- $secret := include "javo-pack.clientSecretName" . -}}
{{- if ne (toString $j.gateway.oidcClientSecret) $secret -}}
{{- fail (printf "javo.gateway.oidcClientSecret must be %q, the Secret the operator writes Javo's client secret to" $secret) -}}
{{- end -}}
{{- if and $j.publicHost (ne $j.publicHost $uiHost) -}}
{{- fail "javo.publicHost must equal javo.config.urls.uiHost (or be empty)" -}}
{{- end -}}
{{- if and ((default (dict) $j.config.nebi).enabled) (not .Values.nebariapp.auth.nebiAudience) -}}
{{- fail "nebariapp.auth.nebiAudience is required with javo.config.nebi.enabled: Nebi's Keycloak client ID, so Nebi accepts Javo's ID tokens" -}}
{{- end -}}
{{- end }}
