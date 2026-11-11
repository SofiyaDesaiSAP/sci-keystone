# SAP SCI Keystone Deployment Guide

> Deploying SAP's Keystone on a personal Gardener shoot cluster (`k8s-release`)
> using HashiCorp Vault + External Secrets Operator + OCM + Flux
> instead of Concourse CI/CD.

---

## Why this guide exists

SAP's SCI production deploys Keystone via Concourse pipelines.
This guide replaces that with OCM + Flux on a personal cluster, using:

- **HashiCorp Vault** (local, on-cluster) — replaces SAP's central Vault for secrets
- **External Secrets Operator (ESO)** — syncs Vault secrets → K8s Secrets
- **Local RabbitMQ** — replaces Hermes (SAP's audit notification bus)
- **OCM controller** (`delivery.ocm.software/v1alpha1`) — fetches + verifies signed component from OCI registry
- **Flux** (helm-controller) — deploys the HelmRelease created by OCM's FluxDeployer

---

## Comparison: Concourse (production) vs OCM+Flux (this guide)

| Step | Concourse (production) | This guide (OCM + Flux) |
|---|---|---|
| Secrets storage | SAP central Vault | Local HashiCorp Vault on cluster |
| Secret injection | Vault agent / pipeline resolves `vault+kvv2:///` URIs | ESO → K8s Secret → HelmRelease `valuesFrom` |
| Audit notifications | SAP Hermes (`hermes-rabbitmq-notifications.hermes`) | Local RabbitMQ in `monsoon3` namespace |
| Chart source | `keppel.eu-de-1.cloud.sap/ccloud-helm` (direct OCI pull) | OCM component on `ghcr.io/sofiyadesaisap/keystone-ctf` (signed, verified) |
| Deploy trigger | Concourse pipeline job | `make ocm-deploy` / `kubectl apply` |
| Signature verification | None | RSA + jsonNormalisation/v3 via OCM controller |
| Seeding | Concourse runs seeder pipeline | openstack-seeder helm deploy |
| Namespace | `monsoon3` | `monsoon3` (same) |

---

## Full Architecture

```
Local workstation
  │
  ├── ocm add componentversions   (pack keystone-0.13.3.tgz as OCM component)
  ├── ocm sign componentversions  (RSA sign)
  └── ocm transfer ctf            (push to ghcr.io/sofiyadesaisap/keystone-ctf)

ghcr.io/sofiyadesaisap/keystone-ctf (GitHub Container Registry)
  └── ocm.software/sap/keystone:0.13.3  (signed component)
       └── resource: keystone-chart (helmChart tgz, label-patched)

Your Gardener Shoot (k8s-release)
  │
  ── ocm-system namespace ──────────────────────────────────────────────
  OCM Controller (v0.33.0)
  │
  ── monsoon3 namespace ────────────────────────────────────────────────
  ComponentVersion: keystone          ← fetches + verifies RSA signature
    └── Resource: keystone-chart      ← extracts chart as OCI Snapshot
         └── FluxDeployer: keystone   ← creates and manages:
              ├── OCIRepository: keystone-chart  (Flux source → Snapshot)
              └── HelmRelease: keystone          (chart: keystone@0.13.3+<digest>)
                   ├── MariaDB   (subchart, enabled: true)
                   ├── Memcached (subchart, enabled: true)
                   ├── keystone-api Deployment
                   └── keystone-cron Deployment

  ── vault namespace ───────────────────────────────────────────────────
  HashiCorp Vault (standalone, file backend)
  └── KV v2 mount: secrets/
       ├── test/keystone/keystone-user/admin       → password
       ├── test/keystone/mariadb-user/keystone     → password
       ├── test/keystone/mariadb-user/root         → password
       ├── test/keystone/mariadb-user/backup       → user, password
       ├── test/keystone/mariadb-user/metis        → username, pass
       ├── test/keystone/keystone-fernet-secrets/default → 0, 1, 2
       ├── test/keystone/keystone-credentials-secrets/default → 0, 1
       └── test/hermes/rabbitmq-user/notifications-keystone → user, pw

  ── external-secrets namespace ────────────────────────────────────────
  External Secrets Operator
  └── ClusterSecretStore: vault-store (token auth via vault-token)
  └── ExternalSecret: keystone-helm-values → K8s Secret (monsoon3)
       key: values.yaml  ← all Keystone + MariaDB secrets in one YAML

  RabbitMQ (plain Deployment, official rabbitmq:3.13-management image)
  └── svc: rabbitmq.monsoon3.svc.cluster.local:5672
```

---

## Prerequisites

- [ ] Gardener shoot cluster running, kubeconfig at `../kubeconfig-for-shoot.yaml`
- [ ] OCM CLI (`ocm` v0.48.0) installed locally
- [ ] RSA signing keypair exists: `ocm/keystone-signing-key.pem` + `ocm/keystone-signing-key-pub.pem`
- [ ] cert-manager installed on cluster (Phase 0)
- [ ] OCM controller v0.33.0 installed on cluster (Phase 0)
- [ ] Flux installed on cluster (Phase 0)

---

## Vault Secrets Structure

All secrets mirror SAP production Vault paths (`vault+kvv2:///secrets/<region>/...`),
replacing `<region>` with `test` for this local deployment.

```
secrets/test/keystone/keystone-user/admin
  password          — Keystone admin password (20 chars, no special chars)

secrets/test/keystone/mariadb-user/keystone
  password          — MariaDB keystone user password

secrets/test/keystone/mariadb-user/root
  password          — MariaDB root password

secrets/test/keystone/mariadb-user/backup
  user              — MariaDB backup username
  password          — MariaDB backup password

secrets/test/keystone/mariadb-user/metis
  username          — MariaDB metis username
  password          — MariaDB metis password

secrets/test/keystone/keystone-fernet-secrets/default
  0, 1, 2           — Fernet keys (token encryption, base64)

secrets/test/keystone/keystone-credentials-secrets/default
  0, 1              — Credential encryption keys (base64)

secrets/test/hermes/rabbitmq-user/notifications-keystone
  username          — RabbitMQ user for audit notifications
  password          — RabbitMQ password

secrets/test/shared/radius-auth/default
  secret            — RADIUS secret (stub value for test)
```

> Generate password: `openssl rand -base64 20 | tr -d '+/=' | cut -c1-20`
> Generate fernet key: `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"`

---

## File Inventory

| File | Purpose |
|---|---|
| `Makefile.scikeystone` | All deployment commands |
| `component-constructor.yaml` | OCM component descriptor — bundles `keystone-0.13.3.tgz` + `openstack-seeder-0.1.0.tgz` |
| `charts/keystone-0.13.3.tgz` | Patched keystone Helm chart (`Chart.Version` labels use `\| replace "+" "_"`) |
| `charts/openstack-seeder-0.1.0.tgz` | Patched openstack-seeder Helm chart (same label patch) |
| `ocm/keystone-ocm-deploy.yaml` | ComponentVersion + Resource (×2) + FluxDeployer (×2) manifests for keystone + seeder |
| `ocm/keystone-signing-key-pub.pem` | RSA public key — stored in `keystone-signing-pubkey` K8s Secret |
| `ocm/keystone-signing-key.pem` | RSA private key — **gitignored, never commit** |
| `vault/vault-init.json` | Vault unseal keys + root token — **gitignored, never commit** |
| `eso/clusterstore.yaml` | ESO ClusterSecretStore → Vault token auth |
| `eso/externalsecrets.yaml` | ExternalSecret CRs — `keystone-helm-values`, `seeder-values`, `rabbitmq-secrets` |
| `rabbitmq/rabbitmq-deployment.yaml` | RabbitMQ plain Deployment + Service (official image, no Bitnami) |
| `seeder/seeder-values.yaml` | openstack-seeder non-secret values (reference — values are now inline in FluxDeployer) |
| `crds/` | Stub CRDs: OpenstackSeed, SentryProject, PrometheusRule |

---

## Step-by-Step Deployment

### Phase 0 — Install cluster-level prerequisites (one-time per cluster)

These must be installed before anything else. OCM controller depends on cert-manager for its internal TLS registry.

**0a — cert-manager**
```bash
helm upgrade --install cert-manager \
  oci://ghcr.io/cloudoperators/greenhouse-extensions/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.20.1 \
  --set installCRDs=true \
  --wait --timeout 5m
```

**0b — OCM controller v0.33.0**
```bash
helm upgrade --install ocm-controller \
  oci://ghcr.io/open-component-model/helm/ocm-controller \
  --namespace ocm-system \
  --create-namespace \
  --version v0.33.0 \
  --set tlsCert.generateTlsCert=true \
  --wait --timeout 5m
```

> `--set tlsCert.generateTlsCert=true` is **required** — the default is `false`. Without it the `ocm-registry-tls-certs` secret is never created and OCM pods stay in `ContainerCreating`. This secret is also needed in Phase 5a.

Wait for the TLS secret before continuing:
```bash
kubectl get secret ocm-registry-tls-certs -n ocm-system
```

**0c — Flux**
```bash
flux install
```

Verify all three are running:
```bash
kubectl get pods -n cert-manager
kubectl get pods -n ocm-system
kubectl get pods -n flux-system
```

---

### Phase 1 — Cluster setup

```bash
make -f Makefile.scikeystone setup
make -f Makefile.scikeystone crds-apply
make -f Makefile.scikeystone coredns-rewrite
make -f Makefile.scikeystone coredns-verify
```

Creates namespaces (`monsoon3`, `vault`, `external-secrets`), labels nodes with
`openstack-control-plane=enabled`, applies stub CRDs, and patches CoreDNS for SAP DNS.

---

### Phase 2 — Deploy HashiCorp Vault

```bash
make -f Makefile.scikeystone vault-deploy
# Wait until vault-0 shows STATUS=Running (0/1 is expected — sealed but running)
make -f Makefile.scikeystone vault-init      # saves to vault/vault-init.json (gitignored)
make -f Makefile.scikeystone vault-unseal    # pod becomes 1/1 Ready after this
make -f Makefile.scikeystone vault-enable-kv
make -f Makefile.scikeystone vault-populate
make -f Makefile.scikeystone vault-token-secret   # MUST run here, before Phase 3 ESO clusterstore
make -f Makefile.scikeystone vault-status
```
<img width="1666" height="888" alt="Screenshot 2026-09-07 at 16 12 55" src="https://github.wdf.sap.corp/user-attachments/assets/ecd00a12-a7b8-4719-9cdb-e3d4e534fc16" />


**Important notes:**
- `vault/vault-init.json` is gitignored — save the unseal keys and root token somewhere safe
- `vault-token-secret` MUST be run before `eso-apply-clusterstore` — ESO needs it to authenticate to Vault
- `vault-init` waits for `status.phase=Running`, NOT `condition=Ready` — Vault never becomes Ready until unsealed

---

### Phase 3 — External Secrets Operator

```bash
make -f Makefile.scikeystone eso-deploy
# vault-token-secret was already created in Phase 2 — no need to repeat
make -f Makefile.scikeystone eso-apply-clusterstore
make -f Makefile.scikeystone eso-apply-externalsecrets
make -f Makefile.scikeystone eso-status
```

Expected output after sync:
```
NAME                  STORE        READY   STATUS
keystone-helm-values  vault-store  True    Secret synced
rabbitmq-secrets      vault-store  True    Secret synced
```
<img width="965" height="242" alt="Screenshot 2026-09-07 at 16 24 07" src="https://github.wdf.sap.corp/user-attachments/assets/edc57ba2-39e4-402a-a368-2a78d1af5c42" />

**Important notes:**
- ESO v1 uses `apiVersion: external-secrets.io/v1` — `v1beta1` is NOT served
- `ClusterSecretStore` shows `InvalidProviderConfig` initially if `vault-token` secret doesn't exist — it auto-recovers once the secret is created

---

### Phase 4 — Deploy local RabbitMQ

```bash
make -f Makefile.scikeystone rabbitmq-deploy
make -f Makefile.scikeystone rabbitmq-status
```

Uses `rabbitmq/rabbitmq-deployment.yaml` — a plain Kubernetes Deployment with the official `rabbitmq:3.13-management` image. No Bitnami (Bitnami restricted free DockerHub pulls after August 2025).

---

### Phase 5 — OCM: pack, sign, push, and deploy Keystone

This is the core of the OCM pipeline. It replaces the Concourse deploy task.
MariaDB and Memcached are deployed as subcharts of the keystone Helm chart.

#### 5a — One-time cluster prerequisites

> Requires Phase 0 to be complete — `ocm-tls-cert-secret` copies a secret that only exists after the OCM controller is installed.

```bash
# Create the RSA public key secret used by ComponentVersion for signature verification
make -f Makefile.scikeystone ocm-signing-secret

# Copy TLS cert secret from ocm-system to monsoon3
# (FluxDeployer auto-sets certSecretRef on the OCIRepository it creates)
make -f Makefile.scikeystone ocm-tls-cert-secret
```

#### 5b — Package and patch the charts

> Skip to 5c if both `charts/keystone-0.13.3.tgz` and `charts/openstack-seeder-0.1.0.tgz` already exist and are label-patched.

```bash
# Keppel login is required for helm dep update (pulls subchart deps from SAP's registry)
# KEPPEL_USER and KEPPEL_TOKEN env vars must be set
make -f Makefile.scikeystone keppel-login

# Clone sapcc/helm-charts and package both charts
make -f Makefile.scikeystone chart-clone-sapcc
make -f Makefile.scikeystone chart-package-keystone   # packages + patches labels automatically
make -f Makefile.scikeystone chart-package-seeder     # packages + patches labels automatically
```

Both packaging targets apply the same `| replace "+" "_"` label patch. Flux OCI appends `+<oci-digest>` to the chart version at deploy time, and Kubernetes rejects `+` in label values. The patch is required for both charts.

The patch replaces `{{ .Chart.Version }}` with `{{ .Chart.Version | replace "+" "_" }}` in all
chart templates. This is required because Flux OCI appends `+<oci-digest>` to the chart version
(e.g. `0.13.3+f7345bba2a8c`), and Kubernetes rejects `+` in label values.

Update `component-constructor.yaml` with the new version (component version, resource version, chart path).

#### 5c — Build, sign, push

```bash
make -f Makefile.scikeystone ocm-fresh-push   # build CTF + sign + push to ghcr.io
```

Or step by step (from inside `sci-keystone-deployment/`):
```bash
# 1. Build
rm -rf keystone-ctf
ocm add componentversions \
  --file keystone-ctf \
  --create \
  component-constructor.yaml

# 2. Sign
ocm sign componentversions \
  --repo ctf::keystone-ctf \
  --signature keystone-sig \
  --private-key ocm/keystone-signing-key.pem \
  ocm.software/sap/keystone

# 3. Push  (requires GITHUB_TOKEN env var with write:packages scope)
ocm \
  --cred :type=OCIRegistry --cred :hostname=ghcr.io \
  --cred username=sofiyadesaisap --cred password=$GITHUB_TOKEN \
  transfer ctf \
  --overwrite \
  --copy-resources \
  keystone-ctf \
  oci://ghcr.io/sofiyadesaisap/keystone-ctf
```

**Note:** `--copy-resources` ensures the chart blob is uploaded into ghcr.io, not left as a reference pointing back to a local path. Without it the pushed component is broken.

#### 5d — Deploy

```bash
make -f Makefile.scikeystone ocm-deploy
make -f Makefile.scikeystone ocm-status
```

Expected reconciliation sequence:
```
ComponentVersion: keystone       READY=True  (fetched + signature verified)
Resource: keystone-chart         READY=True  (keystone chart extracted as Snapshot)
Resource: seeder-chart           READY=True  (seeder chart extracted as Snapshot)
OCIRepository: keystone-chart    READY=True  (Flux source → keystone Snapshot)
OCIRepository: seeder-chart      READY=True  (Flux source → seeder Snapshot)
HelmRelease: keystone            READY=True  Helm install succeeded
HelmRelease: openstack-seeder    READY=True  Helm install succeeded (after keystone Ready)
```
<img width="2014" height="526" alt="Screenshot 2026-09-07 at 15 26 30" src="https://github.wdf.sap.corp/user-attachments/assets/e480db71-5500-44f3-a02b-9ef27db70916" />

All pods when healthy:
```
keystone-api-xxx          3/3 Running
keystone-cron-xxx         2/2 Running
keystone-mariadb-xxx      3/3 Running
keystone-memcached-xxx    2/2 Running
keystone-mysql-metrics-xx 1/1 Running
keystone-job-migration    0/2 Completed
keystone-job-bootstrap    0/2 Completed
```
<img width="869" height="201" alt="Screenshot 2026-09-07 at 16 00 44" src="https://github.wdf.sap.corp/user-attachments/assets/671f64c0-de9f-433f-9cee-506ae419ed8d" />

---

### Phase 5e — Unset immutable roles (one-time, after first bootstrap)

Keystone's bootstrap creates `admin`, `member`, `reader`, `service`, `manager` roles marked as **immutable**. The openstack-seeder (Phase 6) tries to update their descriptions and gets HTTP 403. This must be fixed before deploying the seeder.

```bash
# In one terminal — keep running
make -f Makefile.scikeystone keystone-port-forward

# In another terminal
make -f Makefile.scikeystone fix-immutable-roles
```

---

### Phase 6 — openstack-seeder (OCM-managed, deploys automatically)

The seeder is now bundled in the same OCM component as Keystone and deployed by the `openstack-seeder` FluxDeployer in `ocm/keystone-ocm-deploy.yaml`. It deploys automatically after `kubectl apply -f ocm/keystone-ocm-deploy.yaml` in Phase 5d — no separate step needed.

The FluxDeployer has `dependsOn: keystone`, so Flux waits for the Keystone HelmRelease to be Ready before installing the seeder.

Check seeder status:
```bash
make -f Makefile.scikeystone seeder-status
make -f Makefile.scikeystone seeder-logs
```
<img width="3324" height="1029" alt="Screenshot 2026-09-07 at 16 43 14" src="https://github.wdf.sap.corp/user-attachments/assets/9a114cbe-538f-49a6-b49d-486f238485c7" />

If the seeder pod crashes during seeding — delete the pod, it retries automatically.

---

### Phase 7 — Domain seeding

```bash
make -f Makefile.scikeystone seed-domains
make -f Makefile.scikeystone seed-status
```

---

### Phase 8 — Keystone policy update (cloudAdminProjectId)

After seeding, retrieve the `ccadmin/cloud_admin` project ID:

```bash
make -f Makefile.scikeystone keystone-port-forward &
# Set OS_* env vars from the keystone-helm-values secret
make -f Makefile.scikeystone get-cloudadmin-project-id
```

Update `api.cloudAdminProjectId` in `ocm/keystone-ocm-deploy.yaml` (in the FluxDeployer values),
then re-apply:

```bash
make -f Makefile.scikeystone ocm-deploy
```
<img width="816" height="355" alt="Screenshot 2026-09-07 at 17 10 48" src="https://github.wdf.sap.corp/user-attachments/assets/b144d7d4-d878-4e93-a52a-ab49b2ae2a12" />

---

## Upgrading or Downgrading Keystone

To deploy a different chart version (e.g. `0.14.0`):

**1. Get the new chart**
```bash
# Update KEYSTONE_VERSION in Makefile.scikeystone
make -f Makefile.scikeystone chart-clone-sapcc
make -f Makefile.scikeystone chart-package-keystone   # packages + patches in one step
```

**2. Update `component-constructor.yaml`** — bump version in 3 places:
- `components[0].version`
- `components[0].resources[0].version`
- `components[0].resources[0].input.path` (chart filename)

**3. Build, sign, push**
```bash
make -f Makefile.scikeystone ocm-fresh-push
```

**4. Update `ocm/keystone-ocm-deploy.yaml`** — bump version in 2 places:
- `ComponentVersion.spec.version.semver`
- `Resource.spec.sourceRef.resourceRef.version`

**5. Apply**
```bash
make -f Makefile.scikeystone ocm-deploy
make -f Makefile.scikeystone ocm-status
```

The OCM controller detects the new semver, fetches and verifies it, and Flux upgrades the HelmRelease automatically.

**If the upgrade gets stuck** (HelmRelease stuck in terminal error):
```bash
make -f Makefile.scikeystone ocm-fresh-install
```

---

## Concourse → OCM+Flux step mapping

| Concourse step | This guide |
|---|---|
| Generate admin password → update `keystone.yaml` | `make vault-populate` |
| Update DB/rabbitmq passwords | `make vault-populate` |
| `run make` to update Concourse pipeline | Not needed |
| Run Concourse deploy task for Keystone | `make ocm-fresh-push && make ocm-deploy` |
| Add region to openstack-seeder | `make seeder-helm-deploy` |
| Run Concourse seeder pipeline | Seeder runs automatically as K8s operator |
| `kubectl get openstackseeds` | `make seeder-status` |
| Run domain-seeds pipeline | `make seed-domains` |
| Get `cloud_admin` project ID → redeploy | `make get-cloudadmin-project-id` → update FluxDeployer values → `make ocm-deploy` |

---

## Lessons Learned

### Infrastructure

| Issue | Root Cause | Fix |
|---|---|---|
| `vault-init` timed out waiting for `condition=Ready` | Vault readiness probe always fails when sealed | Wait for `status.phase=Running` instead |
| ESO `ClusterSecretStore` `InvalidProviderConfig` | `vault-token` secret didn't exist when ESO first validated | Run `make vault-token-secret` before `eso-apply-clusterstore` |
| ESO CRD `v1beta1` not served | Installed ESO version only serves `v1` | Use `apiVersion: external-secrets.io/v1` in all ESO manifests |
| RabbitMQ `Init:ImagePullBackOff` | Bitnami restricted free DockerHub pulls after Aug 2025 | Switch to plain Deployment with `rabbitmq:3.13-management` official image |
| RabbitMQ PVC stuck in `creating` | OpenStack Cinder volume creation flaky | Disable persistence (no PVC needed for test) |

### OCM

| Issue | Root Cause | Fix |
|---|---|---|
| `normalization algorithm "jsonNormalisation/v4alpha1" is unknown` | OCM controller supports only v1/v2/v3 | Re-sign with `--normalization jsonNormalisation/v3` |
| `ComponentVersion.metadata.labels: Invalid value: "keppel.eu-de-1.cloud.sap/..."` | OCM controller stores component descriptor as K8s CR; slashes in label values are invalid | Remove the `source` label from `component-constructor.yaml` |
| `Resource: keystone-chart not found` | Resource CR had `extraIdentity.helmChart: keystone` but component descriptor resource has no such identity | Remove `extraIdentity:` block from Resource CR `resourceRef` |
| OCM controller cached old chart content for same version | Controller caches by version string; re-pushing same version doesn't force re-fetch | Bump `KEYSTONE_VERSION` (e.g. `0.13.2` → `0.13.3`) whenever chart content changes |
| `ocm-registry-tls-certs secret not found` in `monsoon3` | FluxDeployer auto-sets `certSecretRef` on the OCIRepository it creates, but only the `ocm-system` copy exists | Copy secret to target namespace: `make ocm-tls-cert-secret` |

### Helm chart / Flux

| Issue | Root Cause | Fix |
|---|---|---|
| `Invalid Value: "keystone-0.13.3+f7345bba2a8c"` in K8s labels | Flux OCI appends `+<oci-digest>` to chart version; `+` is invalid in label values | Patch all chart templates to `\| replace "+" "_"` on `Chart.Version` usages |
| `artifact revision 0.13.3 does not match chart version 0.13.2` | Chart.yaml inside the tgz had old version | Update `Chart.yaml version:` before `helm package` |
| Pre-upgrade hook deadlock (`keystone-job-creds-migrate`) | Pre-upgrade job needs secrets that were never created by a failed previous install | Delete stuck job + clear Helm history secrets + restart helm-controller |
| HelmRelease stuck in `Running 'upgrade' action` past timeout | helm-controller goroutine frozen after many failed cycles | `make flux-restart-controller` |
| `keystone-keep-image-pulled` DaemonSet blocks `--wait` | One DaemonSet pod can't schedule due to insufficient memory on Node 2 | Add `install.disableWait: true` and `upgrade.disableWait: true` to FluxDeployer |
| `keystone-cron` stuck Pending — Insufficient memory | Default cron memory request (2Gi) exceeds available node memory | Override: `cron.resources.requests.memory: 200Mi` in FluxDeployer values |

---

## Troubleshooting

```bash
make -f Makefile.scikeystone status              # all components
make -f Makefile.scikeystone ocm-status          # OCM + HelmRelease status
make -f Makefile.scikeystone vault-status        # vault seal status
make -f Makefile.scikeystone eso-status          # ESO sync status
make -f Makefile.scikeystone flux-watch          # live HelmRelease reconciliation
make -f Makefile.scikeystone flux-restart-controller  # unfreeze stuck helm-controller
make -f Makefile.scikeystone ocm-fresh-install   # clear Helm history + re-apply OCM manifests
make -f Makefile.scikeystone logs-keystone       # keystone-api logs
```

| Symptom | Cause | Fix |
|---|---|---|
| ComponentVersion `READY=False`, `manifest unknown` | Package not yet pushed or push failed | `make ocm-push` to re-push |
| ComponentVersion `READY=False`, signature error | Wrong normalization algorithm or key mismatch | `make ocm-fresh-push` (rebuilds + re-signs) |
| OCIRepository `secret 'monsoon3/ocm-registry-tls-certs' not found` | TLS cert not in target namespace | `make ocm-tls-cert-secret` |
| HelmRelease stuck in `Running 'install/upgrade'` past timeout | helm-controller goroutine frozen | `make flux-restart-controller` |
| HelmRelease `READY=False` terminal error after failed install | Stale Helm history prevents fresh install | `make ocm-fresh-install` |
| `ClusterSecretStore` → `InvalidProviderConfig` | `vault-token` secret missing | `make vault-token-secret` then wait ~30s |
| `ExternalSecret` not syncing | Vault sealed or wrong path | `make vault-status`, check Vault is unsealed |
| `keystone-cron` Pending — Insufficient memory | Memory request too high for available nodes | Reduce `cron.resources.requests.memory` in FluxDeployer values |
| `Table 'keystone.project' doesn't exist` on token request | MariaDB uses ephemeral storage (`persistence_claim.enabled: false`) — schema is lost on pod restart | Re-run: `kubectl exec -c keystone-api -- keystone-manage db_sync`, then `keystone-manage bootstrap`, then `fix-immutable-roles`, then `seeder-restart` |
| `logs-keystone` / `seeder-logs` / `seeder-status` return no resources | Pod labels differ from selectors in Makefile targets | Use `kubectl get pods --show-labels` to find correct label; update Makefile |
