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
The apps host, when apps are served on a host of their own: empty otherwise.
*/}}
{{- define "javo-pack.appsHost" -}}
{{- $urls := .Values.javo.config.urls -}}
{{- if and $urls.appsHost (ne $urls.appsHost $urls.uiHost) -}}
{{- $urls.appsHost -}}
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
{{- if not $urls.uiHost -}}
{{- fail "javo.config.urls.uiHost is required: Javo's host, for example javo.example.com" -}}
{{- end -}}
{{- if ne (default "path" $urls.mode) "path" -}}
{{- fail "javo.config.urls.mode must be path: subdomain mode needs a wildcard host, which a NebariApp cannot route" -}}
{{- end -}}
{{- if not $oidc.issuer -}}
{{- fail "javo.config.auth.oidc.issuer is required: the Keycloak realm URL, for example https://keycloak.example.com/realms/nebari" -}}
{{- end -}}
{{- $clientID := include "javo-pack.clientID" . -}}
{{- if ne (toString $oidc.clientID) $clientID -}}
{{- fail (printf "javo.config.auth.oidc.clientID must be %q, the client the operator provisions for NebariApp %q in namespace %q" $clientID .Values.nebariapp.name .Release.Namespace) -}}
{{- end -}}
{{- $secret := include "javo-pack.clientSecretName" . -}}
{{- if ne (toString $j.gateway.oidcClientSecret) $secret -}}
{{- fail (printf "javo.gateway.oidcClientSecret must be %q, the Secret the operator writes Javo's client secret to" $secret) -}}
{{- end -}}
{{- if and $j.publicHost (ne $j.publicHost $urls.uiHost) -}}
{{- fail "javo.publicHost must equal javo.config.urls.uiHost (or be empty)" -}}
{{- end -}}
{{- if and ((default (dict) $j.config.nebi).enabled) (not .Values.nebariapp.auth.nebiAudience) -}}
{{- fail "nebariapp.auth.nebiAudience is required with javo.config.nebi.enabled: Nebi's Keycloak client ID, so Nebi accepts Javo's ID tokens" -}}
{{- end -}}
{{- end }}
