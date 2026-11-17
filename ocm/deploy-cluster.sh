#!/usr/bin/env bash
# deploy-cluster.sh — Deploy keystone from scratch on a Kubernetes cluster.
#
# Target clusters are assumed to have Flux, kro, cert-manager, and the OCM
# controller already installed (via GreenhouseBootstrap). This script only
# handles namespace/secret setup, kro RGD application, and stack instance
# deployment.
#
# RUN FROM THE REPO ROOT:
#   cd /path/to/sci-keystone
#   ./ocm/deploy-cluster.sh
#
# REQUIRED environment variables:
#   KUBECONFIG                    Path to the target cluster kubeconfig
#   ON_SITE_KEYSTONE_REGISTRY     OCI registry holding the keystone OCM bundle
#                                 Example: sci-ocm-bundles-keppel.keppel.eu-nl-1.cloud.sap
#   ON_SITE_INFRA_REGISTRY        OCI registry holding the infra OCM bundle
#                                 Example: sci-ocm-bundles-keppel.keppel.eu-nl-1.cloud.sap
#   KEYSTONE_VALUES_YAML          Path to keystone Helm values file
#   SEEDER_VALUES_YAML            Path to openstack-seeder Helm values file
#
# OPTIONAL environment variables:
#   REGISTRY_USER                 Username for the on-site registries.
#                                 Not required when registries allow anonymous pulls.
#   REGISTRY_TOKEN                Password / token for the on-site registries.
#                                 When unset: OCM pulls anonymously and no
#                                 imagePullSecrets is created on the cluster.
#   KEYSTONE_COMPONENT_VERSION    Semver constraint for keystone (default: >=0.13.3)
#   INFRA_COMPONENT_VERSION       Semver constraint for infra (default: >=1.0.0)
#
# TOOLS REQUIRED (must be on PATH):
#   kubectl, ocm (v0.48+), jq

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
KEYSTONE_COMPONENT_VERSION="${KEYSTONE_COMPONENT_VERSION:->=0.13.3}"
INFRA_COMPONENT_VERSION="${INFRA_COMPONENT_VERSION:->=1.0.0}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_TOKEN="${REGISTRY_TOKEN:-}"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
step() { echo -e "\n${BOLD}── $*${RESET}"; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
die()  { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# ── Validate ──────────────────────────────────────────────────────────────────
step "Validating prerequisites"

for var in KUBECONFIG ON_SITE_KEYSTONE_REGISTRY ON_SITE_INFRA_REGISTRY KEYSTONE_VALUES_YAML SEEDER_VALUES_YAML; do
  [[ -n "${!var:-}" ]] || die "Required env var \$${var} is not set"
done

[[ -f "${KEYSTONE_VALUES_YAML}" ]] || die "KEYSTONE_VALUES_YAML file not found: ${KEYSTONE_VALUES_YAML}"
[[ -f "${SEEDER_VALUES_YAML}" ]]   || die "SEEDER_VALUES_YAML file not found: ${SEEDER_VALUES_YAML}"
[[ -d "ocm/deploy" ]]              || die "Run this script from the repo root (ocm/deploy/ not found)"

for tool in kubectl ocm jq; do
  command -v "${tool}" >/dev/null 2>&1 || die "Required tool '${tool}' not found on PATH"
done

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

# Export OCM registry credentials when provided.
[[ -n "${REGISTRY_TOKEN}" ]] && export OCM_REGISTRY_CREDS="${REGISTRY_USER}:${REGISTRY_TOKEN}"

ok "All checks passed"
echo "  ON_SITE_KEYSTONE_REGISTRY = ${ON_SITE_KEYSTONE_REGISTRY}"
echo "  ON_SITE_INFRA_REGISTRY    = ${ON_SITE_INFRA_REGISTRY}"
echo "  KUBECONFIG                = ${KUBECONFIG}"
echo "  KEYSTONE_VALUES_YAML      = ${KEYSTONE_VALUES_YAML}"
echo "  SEEDER_VALUES_YAML        = ${SEEDER_VALUES_YAML}"
echo "  AUTH                      = ${REGISTRY_TOKEN:+authenticated (${REGISTRY_USER})}${REGISTRY_TOKEN:-anonymous}"

# ── Step 1: Verify cluster connectivity ───────────────────────────────────────
step "Step 1 — Verifying cluster connectivity"
kubectl cluster-info
ok "Cluster reachable"

# ── Step 2: Create namespaces ─────────────────────────────────────────────────
step "Step 2 — Creating namespaces"
for ns in monsoon3 vault external-secrets; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  ok "Namespace ${ns} ready"
done

# ── Step 3: Create registry pull secret ───────────────────────────────────────
step "Step 3 — Creating registry pull secret"

if [[ -n "${REGISTRY_TOKEN}" ]]; then
  REGISTRY_HOST="${ON_SITE_KEYSTONE_REGISTRY%%/*}"
  for ns in monsoon3 vault external-secrets; do
    kubectl create secret docker-registry keystone-ocm-registry-creds \
      --namespace "${ns}" \
      --docker-server="${REGISTRY_HOST}" \
      --docker-username="${REGISTRY_USER}" \
      --docker-password="${REGISTRY_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  ok "Registry secret keystone-ocm-registry-creds created in monsoon3, vault, external-secrets"
else
  ok "Skipping registry secret (anonymous pulls)"
fi

# ── Step 4: Apply stub CRDs ────────────────────────────────────────────────────
step "Step 4 — Applying stub CRDs"
# These stub CRDs must be present before Helm charts are deployed.
# openstackseed: required by keystone chart; prometheusrule/sentryproject: avoid
# admission webhook failures; priority-classes: required scheduling guarantees.
kubectl apply -f crds/
ok "Stub CRDs applied"

# ── Step 5: Apply kro ResourceGraphDefinitions ────────────────────────────────
step "Step 5 — Applying kro ResourceGraphDefinitions"
kubectl apply -k ocm/deploy/

echo "Waiting for KeystoneStack and InfraStack CRDs (kro processes RGDs)..."
for crd in keystonestacks.kro.run infrastacks.kro.run; do
  echo "  waiting for CRD ${crd} to appear..."
  until kubectl get crd "${crd}" >/dev/null 2>&1; do
    sleep 3
  done
  kubectl wait --for=condition=Established crd/"${crd}" --timeout=60s
  echo "  ✓ ${crd}"
done
ok "RGDs applied, CRDs registered"

# ── Step 6: Deploy InfraStack (vault + eso + rabbitmq) ────────────────────────
step "Step 6 — Applying InfraStack instance"
sed "s|<on-site-infra-registry>|${ON_SITE_INFRA_REGISTRY}|g" \
  ocm/deploy/infra-instance.yaml | kubectl apply -f -

echo "Waiting for OCIRepository reconciliation to start..."
sleep 15
kubectl annotate ocirepository --all -n monsoon3 \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite 2>/dev/null || true

echo "Waiting for vault HelmRelease (up to 8m)..."
kubectl wait helmrelease/vault \
  --namespace vault \
  --for=condition=Ready \
  --timeout=480s
ok "vault ready"

echo "Waiting for external-secrets HelmRelease (up to 8m)..."
kubectl wait helmrelease/external-secrets \
  --namespace external-secrets \
  --for=condition=Ready \
  --timeout=480s
ok "external-secrets ready"

echo "Waiting for rabbitmq HelmRelease (up to 8m)..."
kubectl wait helmrelease/rabbitmq \
  --namespace monsoon3 \
  --for=condition=Ready \
  --timeout=480s
ok "rabbitmq ready"

# ── Step 7: Create keystone values secrets ────────────────────────────────────
step "Step 7 — Creating keystone Helm values secrets"
kubectl create secret generic keystone-helm-values \
  --namespace monsoon3 \
  --from-file=values.yaml="${KEYSTONE_VALUES_YAML}" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "keystone-helm-values secret created"

kubectl create secret generic seeder-values \
  --namespace monsoon3 \
  --from-file=values.yaml="${SEEDER_VALUES_YAML}" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "seeder-values secret created"

# ── Step 8: Deploy KeystoneStack ──────────────────────────────────────────────
step "Step 8 — Applying KeystoneStack instance"
sed "s|<on-site-keystone-registry>|${ON_SITE_KEYSTONE_REGISTRY}|g" \
  ocm/deploy/keystone-instance.yaml | kubectl apply -f -

echo "Waiting for HelmRelease/keystone to be created by kro..."
until kubectl get helmrelease keystone -n monsoon3 >/dev/null 2>&1; do
  echo "  waiting for HelmRelease/keystone..."
  sleep 10
done
ok "HelmRelease/keystone created"

# ── Step 9: Wait for keystone HelmRelease ────────────────────────────────────
step "Step 9 — Waiting for keystone HelmRelease (up to 15m)"

if ! kubectl wait helmrelease/keystone -n monsoon3 \
    --for=condition=Ready --timeout=480s 2>/dev/null; then
  HR_REASON=$(kubectl get helmrelease keystone -n monsoon3 \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
  echo "HelmRelease not ready (reason: ${HR_REASON}) — checking if retry is needed..."

  if [[ "${HR_REASON}" == "InstallFailed" || "${HR_REASON}" == "UpgradeFailed" ]]; then
    echo "Forcing HelmRelease retry via suspend+unsuspend..."
    kubectl patch helmrelease keystone -n monsoon3 \
      --type=merge -p '{"spec":{"suspend":true}}'
    sleep 5
    kubectl patch helmrelease keystone -n monsoon3 \
      --type=merge -p '{"spec":{"suspend":false}}'
    echo "Waiting for HelmRelease retry (up to 8m)..."
    kubectl wait helmrelease/keystone -n monsoon3 \
      --for=condition=Ready --timeout=480s
  else
    kubectl describe helmrelease keystone -n monsoon3 | tail -20
    die "HelmRelease/keystone not ready (reason: ${HR_REASON})"
  fi
fi
ok "keystone HelmRelease ready"

echo "Waiting for HelmRelease/openstack-seeder to be created by kro..."
until kubectl get helmrelease openstack-seeder -n monsoon3 >/dev/null 2>&1; do
  echo "  waiting for HelmRelease/openstack-seeder..."
  sleep 10
done

echo "Waiting for seeder HelmRelease (up to 10m)..."
kubectl wait helmrelease/openstack-seeder -n monsoon3 \
  --for=condition=Ready --timeout=600s
ok "openstack-seeder HelmRelease ready"

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verify"
echo ""
echo "=== HelmReleases (monsoon3) ==="
kubectl get helmrelease -n monsoon3

echo ""
echo "=== HelmReleases (vault) ==="
kubectl get helmrelease -n vault

echo ""
echo "=== HelmReleases (external-secrets) ==="
kubectl get helmrelease -n external-secrets

echo ""
echo "=== Pods (monsoon3) ==="
kubectl get pods -n monsoon3

echo ""
echo "=== KeystoneStack ==="
kubectl get keystonestack keystone -n monsoon3 2>/dev/null \
  || echo "(KeystoneStack not found — kro status may still be reconciling)"

echo ""
echo "=== InfraStack ==="
kubectl get infrastack infra -n monsoon3 2>/dev/null \
  || echo "(InfraStack not found — kro status may still be reconciling)"

echo ""
ok "Deploy complete."
