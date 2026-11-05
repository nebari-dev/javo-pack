#!/bin/sh
# Puts the javo chart this pack depends on into charts/, pulled by the OCI
# digest Chart.yaml names (annotation javo.nebari.dev/chart-digest), not by
# its tag, which can be moved. Before using it, cosign checks that the javo
# repository's release workflow signed that chart for the tag v<version>
# (keyless: GitHub's OIDC identity of .github/workflows/release.yaml run by a
# tag push), and the same for the image the chart names by digest.
#
# When the javo dependency is bumped, set the annotation to the digest
# `helm pull oci://quay.io/nebari/charts/javo --version <version>` prints.
#
# Needs helm and cosign. Usage (from the repository root):
#   dev/fetch-javo-chart.sh
set -eu

die() { echo "fetch-javo-chart: $*" >&2; exit 1; }

chart=quay.io/nebari/charts/javo
version=$(awk '$0 == "  - name: javo" { dep = 1; next } dep && $1 == "version:" { print $2; exit }' Chart.yaml)
digest=$(sed -n 's|^  javo.nebari.dev/chart-digest: *"*\(sha256:[0-9a-f]\{64\}\)"*$|\1|p' Chart.yaml)
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "no javo dependency version X.Y.Z in Chart.yaml (found '$version')" ;;
esac
[ -n "$digest" ] || die "Chart.yaml has no annotation javo.nebari.dev/chart-digest: sha256:<64 hex>"

ref="refs/tags/v$version"
signed_by_javo_release() {
  cosign verify "$1" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity "https://github.com/nebari-dev/javo/.github/workflows/release.yaml@$ref" \
    --certificate-github-workflow-repository nebari-dev/javo \
    --certificate-github-workflow-ref "$ref" \
    --certificate-github-workflow-trigger push >/dev/null ||
    die "$1 is not signed by nebari-dev/javo's release workflow for $ref"
}

signed_by_javo_release "$chart@$digest"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
helm pull "oci://$chart@$digest" -d "$tmp" >/dev/null
tgz=$(ls "$tmp"/*.tgz)
helm show chart "$tgz" | grep -qx "version: $version" ||
  die "$chart@$digest is not javo $version"

# The image the chart installs, by digest (the javo release writes both).
helm show values "$tgz" >"$tmp/values.yaml"
image=$(awk '
  $0 == "image:" { in_image = 1; next }
  in_image && /^[^ ]/ { exit }
  in_image && $1 == "repository:" { repo = $2 }
  in_image && $1 == "digest:" { gsub(/"/, "", $2); digest = $2 }
  END { if (repo != "" && digest ~ /^sha256:[0-9a-f]+$/) print repo "@" digest }
' "$tmp/values.yaml")
[ -n "$image" ] || die "$chart@$digest does not name its image by digest"
signed_by_javo_release "$image"

mkdir -p charts
rm -f charts/javo-*.tgz
cp "$tgz" "charts/javo-$version.tgz"
echo "charts/javo-$version.tgz: $chart@$digest, image $image, both signed by nebari-dev/javo's release workflow for $ref"
