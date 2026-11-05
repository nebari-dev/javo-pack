# Local development for javo-pack on kind.
#
# Creates a kind cluster with the Nebari stack the operator's own dev scripts
# install (MetalLB, Envoy Gateway, cert-manager, Keycloak, nebari-operator),
# installs the pack with both NebariApps enabled, and signs in to Javo through
# the gateway with a Keycloak user (verify-signin.sh).
#
# Prerequisites: docker, kind, helm, kubectl, git, curl.
#
# The kubeconfig lives in dev/.cache/kubeconfig, so ~/.kube/config is never
# touched. Export it to use kubectl yourself:
#   export KUBECONFIG=$(pwd)/.cache/kubeconfig
#
# Usage:
#   make cluster        Create the cluster and the Nebari stack (5-10 minutes)
#   make vendor-javo    Package the Javo chart from JAVO_CHART_DIR into ../charts/
#   make load-image     Load JAVO_IMAGE into the kind nodes
#   make up             Install the pack (needs vendor-javo and load-image first)
#   make verify         Sign in through the gateway with Keycloak and open Javo
#   make down           Delete the cluster
#
# Before the Javo chart is published, point JAVO_CHART_DIR at a checkout:
#   make vendor-javo JAVO_CHART_DIR=~/src/javo/deploy/helm/javo
# After it is published, `helm dependency build ..` pulls it from GHCR instead.

CLUSTER_NAME   ?= javo-pack-dev
# Third-party code and manifests the cluster setup runs, pinned by commit and
# sha256 so a moved tag or a replaced file cannot change what runs:
# nebari-operator v0.1.2 (git ls-remote ... 'refs/tags/v0.1.2^{}') and its
# release's install.yaml, and MetalLB v0.14.8's manifest at the tag's commit.
OPERATOR_REF   := v0.1.2
OPERATOR_SHA   := 38447bf2323ee3398a9b667ad71fad2c40f54218
OPERATOR_INSTALL_SHA256 := 7d65d40b8039d41fee349d9df0755a3907664236b9b35a9a4b2901bd16eb7e28
METALLB_SHA    := 80fa562f23fdf05b578329adbcfc4c5da534760f
METALLB_SHA256 := 11b5906021fde56040cf10d1bcbaf5c2b7a4206045ebb103915347dfcc533f0e
CACHE_DIR      := .cache
OPERATOR_REPO  := $(CACHE_DIR)/nebari-operator
KUBECONFIG     := $(abspath $(CACHE_DIR))/kubeconfig
export KUBECONFIG
# The operator's scripts run `helm repo add/update`; keep that out of your own
# Helm repository list (one unreachable repo there fails `helm repo update`).
export HELM_REPOSITORY_CONFIG := $(abspath $(CACHE_DIR))/helm/repositories.yaml
export HELM_REPOSITORY_CACHE  := $(abspath $(CACHE_DIR))/helm/cache

CHART_DIR      := ..
NAMESPACE      ?= javo
RELEASE        ?= javo-pack
JAVO_CHART_DIR ?=
JAVO_IMAGE     ?= quay.io/nebari/javo:0.1.0
VALUES         ?= ../examples/kind-values.yaml
# Extra helm flags, for example -f my-overrides.yaml
HELM_ARGS      ?=

define METALLB_POOL
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - METALLB_BASE_IP.255.200-METALLB_BASE_IP.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - kind-pool
endef
export METALLB_POOL

# fetch <url>,<sha256>,<file>: download url to file; fail unless it has that sha256.
fetch = mkdir -p $(dir $(3)) && curl -fsSLo $(3) $(1) && echo "$(2)  $(3)" | shasum -a 256 -c -

.PHONY: cluster vendor-javo load-image up verify down

cluster:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster '$(CLUSTER_NAME)' already exists, skipping setup"; \
	else \
		$(MAKE) _clone-operator _kind-create _metallb _services _keycloak-setup _operator; \
	fi

_clone-operator:
	@if [ ! -d "$(OPERATOR_REPO)" ]; then \
		mkdir -p $(OPERATOR_REPO) && \
		git -C $(OPERATOR_REPO) init -q && \
		git -C $(OPERATOR_REPO) fetch -q --depth 1 https://github.com/nebari-dev/nebari-operator.git $(OPERATOR_SHA) && \
		git -C $(OPERATOR_REPO) checkout -q FETCH_HEAD; \
	fi
	@test "$$(git -C $(OPERATOR_REPO) rev-parse HEAD)" = "$(OPERATOR_SHA)" || \
		{ echo "$(OPERATOR_REPO) is not at $(OPERATOR_SHA) ($(OPERATOR_REF)): delete it and run make cluster again"; exit 1; }

_kind-create:
	mkdir -p $(CACHE_DIR)
	kind create cluster --name $(CLUSTER_NAME) --kubeconfig $(KUBECONFIG)
	@# A second kind cluster on the same Docker VM can exhaust inotify instances
	@# and crash-loop kube-proxy; raise the limit on this node.
	docker exec $(CLUSTER_NAME)-control-plane sysctl -w fs.inotify.max_user_instances=1024

_metallb:
	$(call fetch,https://raw.githubusercontent.com/metallb/metallb/$(METALLB_SHA)/config/manifests/metallb-native.yaml,$(METALLB_SHA256),$(CACHE_DIR)/metallb-native.yaml)
	kubectl apply -f $(CACHE_DIR)/metallb-native.yaml
	kubectl wait -n metallb-system --for=condition=available deployment/controller --timeout=120s
	kubectl wait -n metallb-system --for=jsonpath='{.status.numberReady}'=1 daemonset/speaker --timeout=120s
	@KIND_NET_CIDR=$$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep '\.' | head -n1); \
	BASE_IP=$$(echo $${KIND_NET_CIDR} | awk -F. '{print $$1"."$$2}'); \
	echo "$$METALLB_POOL" | sed "s/METALLB_BASE_IP/$${BASE_IP}/g" | kubectl apply -f -

# The operator's install.sh ends by adding the gateway IP to /etc/hosts with
# sudo. Nothing below needs that entry: verify-signin.sh resolves every host
# itself through a port-forward.
_services:
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/services/install.sh

# The realm user's password is KC_PASSWORD (verify-signin.sh signs in with
# it); there is no default.
_keycloak-setup:
	@test -n "$$KC_PASSWORD" || { echo "set KC_PASSWORD to the password the Keycloak realm user gets (verify-signin.sh signs in with it)"; exit 1; }
	CLUSTER_NAME=$(CLUSTER_NAME) REALM_ADMIN_PASSWORD="$$KC_PASSWORD" $(OPERATOR_REPO)/dev/scripts/services/keycloak/setup.sh

_operator:
	$(call fetch,https://github.com/nebari-dev/nebari-operator/releases/download/$(OPERATOR_REF)/install.yaml,$(OPERATOR_INSTALL_SHA256),$(CACHE_DIR)/nebari-operator-install.yaml)
	kubectl apply -f $(CACHE_DIR)/nebari-operator-install.yaml
	kubectl wait --for=condition=available deployment/nebari-operator-controller-manager \
		-n nebari-operator-system --timeout=180s

vendor-javo:
	@test -n "$(JAVO_CHART_DIR)" || { echo "set JAVO_CHART_DIR to the javo chart directory"; exit 1; }
	mkdir -p $(CHART_DIR)/charts
	helm package $(JAVO_CHART_DIR) -d $(CHART_DIR)/charts

load-image:
	kind load docker-image $(JAVO_IMAGE) --name $(CLUSTER_NAME)

up:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl label namespace $(NAMESPACE) nebari.dev/managed=true --overwrite
	helm upgrade --install $(RELEASE) $(CHART_DIR) -n $(NAMESPACE) -f $(VALUES) $(HELM_ARGS) --wait --timeout 5m
	kubectl wait -n $(NAMESPACE) --for=condition=Ready nebariapp --all --timeout=180s
	kubectl get nebariapp -n $(NAMESPACE)

verify:
	NAMESPACE=$(NAMESPACE) ./verify-signin.sh

down:
	kind delete cluster --name $(CLUSTER_NAME) --kubeconfig $(KUBECONFIG)
