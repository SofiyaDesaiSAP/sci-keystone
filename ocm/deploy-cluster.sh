#!/usr/bin/env bash
# deploy-cluster.sh — Deploy keystone from scratch on a Kubernetes cluster.
#
# Fully automated, air-gapped, idempotent. No secrets files needed.
#
# Flow:
#   Phase 0 — Bootstrap cert-manager, OCM controller, Flux, kro from Keppel infra bundle
#   Steps 1-6 — Namespaces, registry secrets, stub CRDs, kro RGDs, InfraStack (vault+eso+rabbitmq)
#   Step 6b — Vault init + unseal + populate (auto-generates all credentials)
#   Step 6c — ESO ClusterSecretStore + ExternalSecrets (syncs vault → K8s secrets)
#   Steps 7-9 — KeystoneStack deployment via kro
#
# The OCM bundles (keystone + infra) must already be present in ON_SITE_INFRA_REGISTRY.
# Run the GitHub Actions workflows first:
#   1. build-push-ocm-bundle.yaml  →  pushes bundles to JFrog
#   2. deploy.yaml                 →  transfers JFrog → Keppel (ON_SITE_INFRA_REGISTRY)
#
# RUN FROM THE REPO ROOT:
#   cd /path/to/sci-keystone
#   ./ocm/deploy-cluster.sh
#
# REQUIRED environment variables:
#   KUBECONFIG                    Path to the target cluster kubeconfig
#   ON_SITE_KEYSTONE_REGISTRY     OCI registry holding the keystone OCM bundle
#                                 Example: keppel.eu-nl-1.cloud.sap/cloud-infrastructure-release-management
#   ON_SITE_INFRA_REGISTRY        OCI registry holding the infra OCM bundle
#                                 Example: keppel.eu-nl-1.cloud.sap/cloud-infrastructure-release-management
#   DB_BACKUP_CREDENTIAL_ID       OpenStack Application Credential ID for Swift backup storage
#                                 (SCI Horizon: Identity → Application Credentials, role: swiftoperator)
#   DB_BACKUP_CREDENTIAL_SECRET   OpenStack Application Credential secret (shown only at creation time)
#
# OPTIONAL environment variables:
#   KEPPEL_USER                   Username for the on-site Keppel registries.
#   KEPPEL_TOKEN                  Password / token for the on-site Keppel registries.
#   KEYSTONE_COMPONENT_VERSION    Semver constraint for keystone (default: >=0.13.3)
#   INFRA_COMPONENT_VERSION       Semver constraint for infra (default: >=1.1.0)
#   VAULT_INIT_FILE               Where to save vault unseal keys (default: vault/vault-init.json)
#   DB_BACKUP_AUTH_URL            Swift identity endpoint (default: https://identity-3.eu-nl-1.cloud.sap/v3)
#   DB_BACKUP_REGION              Swift region (default: eu-nl-1)
#   DB_BACKUP_CONTAINER           Swift container name (default: keystone-db-backup)
#
# TOOLS REQUIRED (must be on PATH):
#   kubectl, helm, ocm (v0.48+), jq

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
KEYSTONE_COMPONENT_VERSION="${KEYSTONE_COMPONENT_VERSION:->=0.13.3}"
INFRA_COMPONENT_VERSION="${INFRA_COMPONENT_VERSION:->=1.1.0}"
KEPPEL_USER="${KEPPEL_USER:-}"
KEPPEL_TOKEN="${KEPPEL_TOKEN:-}"
VAULT_INIT_FILE="${VAULT_INIT_FILE:-vault/vault-init.json}"
VAULT_NS="vault"
VAULT_POD="vault-0"
DB_BACKUP_AUTH_URL="${DB_BACKUP_AUTH_URL:-https://identity-3.eu-nl-1.cloud.sap/v3}"
DB_BACKUP_REGION="${DB_BACKUP_REGION:-eu-nl-1}"
DB_BACKUP_CONTAINER="${DB_BACKUP_CONTAINER:-keystone-db-backup}"

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
step() { echo -e "\n${BOLD}── $*${RESET}"; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
die()  { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# Fernet-compatible key: 32 random bytes as URL-safe base64 (no padding)
_fernet_key() { openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'; }

# Run a vault command inside the vault pod using the root token
_vault() { kubectl exec "${VAULT_POD}" -n "${VAULT_NS}" -- env VAULT_TOKEN="${ROOT_TOKEN}" vault "$@"; }

# _bootstrap_tool: download a Helm chart from an OCM component in Keppel and install it.
# Skips if any Running pod already exists in the target namespace (idempotent).
# Usage: _bootstrap_tool <namespace> <ocm-component> <ocm-resource> <helm-release> [helm-flags...]
_bootstrap_tool() {
  local ns="$1" component="$2" resource="$3" release="$4"
  shift 4

  if kubectl get pods -n "${ns}" --field-selector=status.phase=Running \
       --no-headers 2>/dev/null | grep -q .; then
    ok "${release} already running in ${ns}, skipping"
    return 0
  fi

  local ver
  ver=$(ocm get componentversion \
    --repo "oci://${ON_SITE_INFRA_REGISTRY}" "${component}" \
    -o json 2>/dev/null \
    | jq -r '[.items[].metadata.version] | sort | last // empty')
  [[ -n "${ver}" ]] || die "${release}: cannot find component ${component} in ${ON_SITE_INFRA_REGISTRY}. Has deploy.yaml run successfully?"

  local chart="${TMP}/bootstrap/${release}.tgz"
  mkdir -p "${TMP}/bootstrap"

  echo "  Downloading ${release} ${ver} chart from Keppel..."
  ocm download resources \
    --repo "oci://${ON_SITE_INFRA_REGISTRY}" \
    "${component}:${ver}" "${resource}" \
    --download-handler helm \
    -O "${chart}" \
  || die "${release}: chart download failed. Check registry credentials and that the bundle was transferred."

  helm upgrade --install "${release}" "${chart}" \
    --namespace "${ns}" --create-namespace \
    "$@" --wait --timeout 5m
  ok "${release} ${ver} installed from Keppel"
}

# ── Validate ──────────────────────────────────────────────────────────────────
step "Validating prerequisites"

for var in KUBECONFIG ON_SITE_KEYSTONE_REGISTRY ON_SITE_INFRA_REGISTRY DB_BACKUP_CREDENTIAL_ID DB_BACKUP_CREDENTIAL_SECRET; do
  [[ -n "${!var:-}" ]] || die "Required env var \$${var} is not set"
done

[[ -d "ocm/deploy" ]] || die "Run this script from the repo root (ocm/deploy/ not found)"
[[ -d "eso" ]]        || die "eso/ directory not found — run from repo root"

for tool in kubectl helm ocm jq; do
  command -v "${tool}" >/dev/null 2>&1 || die "Required tool '${tool}' not found on PATH"
done

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

[[ -n "${KEPPEL_TOKEN}" ]] && export OCM_REGISTRY_CREDS="${KEPPEL_USER}:${KEPPEL_TOKEN}"

ok "All checks passed"
echo "  ON_SITE_KEYSTONE_REGISTRY = ${ON_SITE_KEYSTONE_REGISTRY}"
echo "  ON_SITE_INFRA_REGISTRY    = ${ON_SITE_INFRA_REGISTRY}"
echo "  KUBECONFIG                = ${KUBECONFIG}"
echo "  VAULT_INIT_FILE           = ${VAULT_INIT_FILE}"
echo "  AUTH                      = ${KEPPEL_TOKEN:+authenticated (${KEPPEL_USER})}${KEPPEL_TOKEN:-anonymous}"
echo "  DB_BACKUP_AUTH_URL        = ${DB_BACKUP_AUTH_URL}"
echo "  DB_BACKUP_CONTAINER       = ${DB_BACKUP_CONTAINER}"
echo "  DB_BACKUP_CREDENTIAL_ID   = ${DB_BACKUP_CREDENTIAL_ID}"

# ── Step 1: Verify cluster connectivity ───────────────────────────────────────
step "Step 1 — Verifying cluster connectivity"
kubectl cluster-info
ok "Cluster reachable"

# ── Phase 0: Bootstrap platform tools from Keppel (air-gapped) ───────────────
# Downloads cert-manager, OCM controller, Flux, and kro charts from the infra
# OCM bundle already in ON_SITE_INFRA_REGISTRY. Each tool is skipped if its
# namespace already has Running pods (safe to re-run on an existing cluster).
step "Phase 0 — Bootstrapping platform tools from Keppel (air-gapped)"

# 1. cert-manager — required by OCM controller (webhook TLS certs)
_bootstrap_tool cert-manager \
  "ocm.software/sap/keystone/infra/cert-manager" \
  "cert-manager-chart" \
  "cert-manager" \
  --set installCRDs=true

# 2. OCM controller — provides delivery.ocm.software/v1alpha1 CRDs used by kro RGDs
_bootstrap_tool ocm-system \
  "ocm.software/sap/keystone/infra/ocm-controller" \
  "ocm-controller-chart" \
  "ocm-controller" \
  --set tlsCert.generateTlsCert=true

echo "  Waiting for ocm-registry-tls-certs secret (required before Flux)..."
until kubectl get secret ocm-registry-tls-certs -n ocm-system >/dev/null 2>&1; do sleep 3; done
ok "ocm-registry-tls-certs secret present"

# 3. Flux — provides OCIRepository and HelmRelease CRDs used by kro RGDs
_bootstrap_tool flux-system \
  "ocm.software/sap/keystone/infra/flux" \
  "flux-chart" \
  "flux"

# 4. kro — provides ResourceGraphDefinition CRD (required for KeystoneStack/InfraStack)
_bootstrap_tool kro-system \
  "ocm.software/sap/keystone/infra/kro" \
  "kro-chart" \
  "kro"

ok "All platform tools ready"

# ── Step 2: Create namespaces ─────────────────────────────────────────────────
step "Step 2 — Creating namespaces"
for ns in monsoon3 vault external-secrets; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  ok "Namespace ${ns} ready"
done

# ── Step 3: Create registry pull secret ───────────────────────────────────────
step "Step 3 — Creating registry pull secret"
if [[ -n "${KEPPEL_TOKEN}" ]]; then
  REGISTRY_HOST="${ON_SITE_KEYSTONE_REGISTRY%%/*}"
  for ns in monsoon3 vault external-secrets; do
    kubectl create secret docker-registry keystone-ocm-registry-creds \
      --namespace "${ns}" \
      --docker-server="${REGISTRY_HOST}" \
      --docker-username="${KEPPEL_USER}" \
      --docker-password="${KEPPEL_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  ok "Registry secret keystone-ocm-registry-creds created in monsoon3, vault, external-secrets"
else
  ok "Skipping registry secret (anonymous pulls)"
fi

# ── Step 4: Apply stub CRDs ────────────────────────────────────────────────────
step "Step 4 — Applying stub CRDs"
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
  until kubectl get crd "${crd}" >/dev/null 2>&1; do sleep 3; done
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
kubectl wait helmrelease/vault --namespace vault \
  --for=condition=Ready --timeout=480s
ok "vault ready"

echo "Waiting for external-secrets HelmRelease (up to 8m)..."
kubectl wait helmrelease/external-secrets --namespace external-secrets \
  --for=condition=Ready --timeout=480s
ok "external-secrets ready"

echo "Waiting for rabbitmq HelmRelease (up to 8m)..."
kubectl wait helmrelease/rabbitmq --namespace monsoon3 \
  --for=condition=Ready --timeout=480s
ok "rabbitmq ready"

# ── Step 6b: Vault init + unseal + populate ────────────────────────────────────
step "Step 6b — Initializing Vault"

kubectl wait pod/"${VAULT_POD}" -n "${VAULT_NS}" \
  --for=jsonpath='{.status.phase}'=Running --timeout=120s

VAULT_INITIALIZED=$(kubectl exec "${VAULT_POD}" -n "${VAULT_NS}" -- \
  vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

if [[ "${VAULT_INITIALIZED}" == "true" ]]; then
  [[ -f "${VAULT_INIT_FILE}" ]] \
    || die "Vault is already initialized but ${VAULT_INIT_FILE} is missing. Cannot unseal."
  ok "Vault already initialized — using existing ${VAULT_INIT_FILE}"
else
  mkdir -p "$(dirname "${VAULT_INIT_FILE}")"
  kubectl exec "${VAULT_POD}" -n "${VAULT_NS}" -- \
    vault operator init -key-shares=1 -key-threshold=1 -format=json \
    > "${VAULT_INIT_FILE}"
  ok "Vault initialized — keys saved to ${VAULT_INIT_FILE} (do NOT commit this file)"
fi

ROOT_TOKEN=$(jq -r '.root_token'          "${VAULT_INIT_FILE}")
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]'  "${VAULT_INIT_FILE}")

VAULT_SEALED=$(kubectl exec "${VAULT_POD}" -n "${VAULT_NS}" -- \
  vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")

if [[ "${VAULT_SEALED}" == "true" ]]; then
  kubectl exec "${VAULT_POD}" -n "${VAULT_NS}" -- vault operator unseal "${UNSEAL_KEY}"
  ok "Vault unsealed"
else
  ok "Vault already unsealed"
fi

kubectl exec "${VAULT_POD}" -n "${VAULT_NS}" -- \
  env VAULT_TOKEN="${ROOT_TOKEN}" \
  vault secrets enable -path=secrets kv-v2 2>/dev/null || true
ok "KV v2 at 'secrets/' ready"

# ── Step 6c: Populate Vault with keystone credentials ─────────────────────────
# Skips if admin password already exists (idempotent re-runs won't rotate secrets).
step "Step 6c — Populating Vault with keystone credentials"

ALREADY_POPULATED=$(_vault kv get -field=password secrets/test/keystone/keystone-user/admin \
  2>/dev/null && echo "yes" || echo "no")

if [[ "${ALREADY_POPULATED}" == "yes" ]]; then
  ok "Vault secrets already populated, skipping (run with VAULT_REPOPULATE=true to overwrite)"
else
  ADMIN_PASS=$( openssl rand -base64 20 | tr -d '+/=' | cut -c1-20)
  MARIADB_ROOT=$(openssl rand -base64 20 | tr -d '+/=' | cut -c1-20)
  MARIADB_KS=$(  openssl rand -base64 20 | tr -d '+/=' | cut -c1-20)
  MARIADB_BK=$(  openssl rand -base64 20 | tr -d '+/=' | cut -c1-20)
  MARIADB_MT=$(  openssl rand -base64 20 | tr -d '+/=' | cut -c1-20)
  RABBITMQ_PASS=$(openssl rand -base64 20 | tr -d '+/=' | cut -c1-20)
  FERNET_0=$(_fernet_key); FERNET_1=$(_fernet_key); FERNET_2=$(_fernet_key)
  CRED_0=$(_fernet_key);   CRED_1=$(_fernet_key)

  echo "  Writing secrets to Vault..."
  _vault kv put secrets/test/keystone/keystone-user/admin            password="${ADMIN_PASS}"
  _vault kv put secrets/test/keystone/mariadb-user/keystone          password="${MARIADB_KS}"
  _vault kv put secrets/test/keystone/mariadb-user/root              password="${MARIADB_ROOT}"
  _vault kv put secrets/test/keystone/mariadb-user/backup            user="keystone-backup"    password="${MARIADB_BK}"
  _vault kv put secrets/test/keystone/mariadb-user/metis             username="keystone-metis" password="${MARIADB_MT}"
  _vault kv put secrets/test/keystone/keystone-fernet-secrets/default      0="${FERNET_0}" 1="${FERNET_1}" 2="${FERNET_2}"
  _vault kv put secrets/test/keystone/keystone-credentials-secrets/default 0="${CRED_0}"   1="${CRED_1}"
  _vault kv put secrets/test/hermes/rabbitmq-user/notifications-keystone   username="keystone-notifications" password="${RABBITMQ_PASS}"
  _vault kv put secrets/test/shared/radius-auth/default             secret="dummy-radius-secret"
  _vault kv put secrets/test/keystone/db-backup/swift \
    auth_url="${DB_BACKUP_AUTH_URL}" \
    application_credential_id="${DB_BACKUP_CREDENTIAL_ID}" \
    application_credential_secret="${DB_BACKUP_CREDENTIAL_SECRET}" \
    region_name="${DB_BACKUP_REGION}" \
    container_name="${DB_BACKUP_CONTAINER}"
  ok "All secrets written to Vault"
fi

# vault-token K8s secret for ESO auth (safe to re-apply)
kubectl create secret generic vault-token \
  --from-literal=token="${ROOT_TOKEN}" \
  --namespace "${VAULT_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "vault-token K8s secret ready"

# ── Step 6d: ESO ClusterSecretStore + ExternalSecrets → K8s secrets ───────────
step "Step 6d — Applying ESO ClusterSecretStore and ExternalSecrets"
kubectl apply -f eso/clusterstore.yaml
kubectl apply -f eso/externalsecrets.yaml

echo "Waiting for ExternalSecrets to sync (creates keystone-helm-values and seeder-values)..."
for es in keystone-helm-values seeder-values; do
  echo "  waiting for ExternalSecret/${es} to be Ready..."
  until kubectl get externalsecret "${es}" -n monsoon3 \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null | grep -q "True"; do
    sleep 5
  done
  ok "ExternalSecret/${es} synced → K8s secret created"
done

# ── Step 7: Verify secrets exist (created by ESO above) ──────────────────────
step "Step 7 — Verifying keystone values secrets"
kubectl get secret keystone-helm-values -n monsoon3 -o name \
  || die "keystone-helm-values secret missing — check ESO logs: kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets"
kubectl get secret seeder-values -n monsoon3 -o name \
  || die "seeder-values secret missing — check ESO logs"
ok "keystone-helm-values and seeder-values secrets present"

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
    kubectl patch helmrelease keystone -n monsoon3 --type=merge -p '{"spec":{"suspend":true}}'
    sleep 5
    kubectl patch helmrelease keystone -n monsoon3 --type=merge -p '{"spec":{"suspend":false}}'
    echo "Waiting for HelmRelease retry (up to 8m)..."
    kubectl wait helmrelease/keystone -n monsoon3 --for=condition=Ready --timeout=480s
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
