# Implementation Plan: Extreme Data Portability for DevOps Toolchain

## Situation

- **Nothing is currently deployed** — GCP project `devops-environment-488820` has no running GKE cluster, no disks, no K8s workloads.
- **Nexus**: Fresh — no custom repos configured yet.
- **SonarQube**: Fresh — using built-in "Sonar way" quality profile only.
- **Jenkins plugins**: No versions pinned, no running pod to extract versions from.

## Execution Order

```
Phase 0  →  Spin up everything, verify it works
Phase 1  →  Lock all config into Git (config as code)
Phase 2  →  Add automated backup + snapshot schedule
Phase 3  →  Migration script for new GCP projects
```

---

## Phase 0 — Infrastructure Bootstrap & Verification

**Goal**: Get the full stack running from scratch in the correct Terraform layer order. Verify all 4 pods are healthy before touching any portability work.

> [!IMPORTANT]
> This is a prerequisite for Phase 1. Plugin version pinning requires extracting versions from the running Jenkins pod. Nexus repo setup requires Nexus to be running. Nothing else can proceed until Phase 0 is complete.

### Step 0.1 — Terraform Layer 01: Network
```
cd terraform/layers/01-network
terraform init
terraform apply
```
Creates: VPC (`devops-vpc`), subnet, Cloud Router, Cloud NAT, GKE node service account.

### Step 0.2 — Terraform Layer 02: Storage
```
cd terraform/layers/02-storage
terraform init
terraform apply
```
Creates: 4 GCP Persistent Disks (`jenkins-home-disk`, `nexus-data-disk`, `sonarqube-data-disk`, `postgres-data-disk`).

### Step 0.3 — Terraform Layer 03: Secrets
Passwords passed as env vars — never stored in `tfvars`:
```
$env:TF_VAR_jenkins_password = "your-jenkins-pass"
$env:TF_VAR_nexus_password   = "your-nexus-pass"
$env:TF_VAR_sonar_password   = "your-sonar-pass"
$env:TF_VAR_db_password      = "your-db-pass"

cd terraform/layers/03-secrets
terraform init
terraform apply
```
Creates: 4 Google Secret Manager secrets.

### Step 0.4 — Terraform Layer 04: Compute
```
cd terraform/layers/04-compute
terraform init
terraform apply
```
Creates: GKE cluster (`devops-cluster`) with 1 node (`e2-standard-4`) in `us-central1-a`.

### Step 0.5 — Connect kubectl
```
gcloud container clusters get-credentials devops-cluster --region us-central1 --project devops-environment-488820
```

### Step 0.6 — Deploy K8s Workloads
```
$env:JENKINS_PASSWORD = "your-jenkins-pass"
$env:DB_PASSWORD      = "your-db-pass"
.\scripts\devops-env.ps1 -Action setup
```

### Step 0.7 — Verification Checklist
Run and confirm all 4 pods reach `Running` state:
```
kubectl get pods -n devops -w
```

| Pod | Expected Status | Ready Signal |
|---|---|---|
| `postgres-*` | Running | `pg_isready` readiness probe passes |
| `sonarqube-*` | Running | `/api/system/status` returns `UP` |
| `nexus-*` | Running | `/service/rest/v1/status` returns `200` |
| `jenkins-*` | Running | `/login` returns `200`, plugins installed |

Access via port-forward to confirm UIs load:
```
kubectl port-forward svc/jenkins   8080:8080 -n devops
kubectl port-forward svc/nexus     8081:8081 -n devops
kubectl port-forward svc/sonarqube 9000:9000 -n devops
```

---

## Phase 1 — Configuration as Code

**Goal**: Every config decision lives in Git. A brand-new empty deployment self-configures from code — no manual UI clicking.

**No GCP cost. No Terraform changes.**

---

### 1A — Jenkins: Pin Plugin Versions

#### Strategy
Since nothing is running yet, we **cannot** pin to "what's currently installed." Instead:
1. Deploy with current unpinned `plugins.txt` (Phase 0).
2. After Jenkins is running, extract the exact installed versions from the pod with one command:
   ```
   kubectl exec -n devops statefulset/jenkins -- \
     jenkins-plugin-cli --list 2>/dev/null | awk '{print $1":"$2}'
   ```
3. Replace `plugins.txt` with the output. This locks the versions forever.

#### [MODIFY] [plugins.txt](file:///c:/myProjects/devops-setup/k8s/manifests/jenkins/plugins.txt)
Add the `job-dsl` plugin (needed for Phase 1B seed job) to the existing list **before** first deploy:
```
# Add to existing list:
job-dsl
```
Then after Phase 0, replace with version-pinned output.

---

### 1B — Jenkins: Job DSL Seed Job

#### [MODIFY] [jenkins.yaml](file:///c:/myProjects/devops-setup/k8s/manifests/jenkins/jenkins.yaml)
Add a `jobs:` block to auto-create a seed pipeline on first boot. Also parametrize the hardcoded Artifact Registry project reference (`devops-environment-488820`) using an env var so the config is portable.

**Changes**:
1. Replace all hardcoded `devops-environment-488820` image references with `${ARTIFACT_REGISTRY_PROJECT}` 
2. Add `jobs:` block pointing to a seed Groovy script in this repo

#### [NEW] [jenkins/seed/jenkins_jobs.groovy](file:///c:/myProjects/devops-setup/jenkins/seed/jenkins_jobs.groovy)
Job DSL script that auto-declares all pipelines. Example pattern:
```groovy
pipelineJob('my-app-pipeline') {
  definition {
    cpsScm {
      scm { git { remote { url('https://github.com/your-org/my-app') } } }
      scriptPath('Jenkinsfile')
    }
  }
}
```

#### [MODIFY] [k8s/manifests/jenkins/statefulset.yaml](file:///c:/myProjects/devops-setup/k8s/manifests/jenkins/statefulset.yaml)
Add `ARTIFACT_REGISTRY_PROJECT` as an env var (sourced from a ConfigMap or env) so `jenkins.yaml` can reference it portably.

---

### 1C — Nexus: Idempotent REST API Setup Script

#### [NEW] [scripts/nexus-setup.sh](file:///c:/myProjects/devops-setup/scripts/nexus-setup.sh)
A bash script using `curl` against the Nexus REST API v1 that:
- Waits for Nexus to be ready (polls `/service/rest/v1/status`)
- Creates blob stores: `default` (file, already exists), `docker-blobs`, `npm-blobs`
- Creates repositories:
  - `maven-releases` (hosted)
  - `maven-snapshots` (hosted)
  - `maven-central` (proxy → `https://repo1.maven.org/maven2/`)
  - `maven-public` (group: releases + snapshots + central)
  - `docker-hosted` (hosted, port 5000)
  - `npm-hosted` (hosted)
  - `npm-proxy` (proxy → `https://registry.npmjs.org`)
  - `npm-group` (group)
- Creates a `ci-deploy` user with deploy role
- Sets cleanup policy: delete snapshots older than 30 days
- All calls use `--fail-with-body` and check for `200/201` — safe to re-run idempotently

#### [MODIFY] [scripts/devops-env.ps1](file:///c:/myProjects/devops-setup/scripts/devops-env.ps1) and [devops-env.sh](file:///c:/myProjects/devops-setup/scripts/devops-env.sh)
Add a `[6/6] Configuring Nexus repositories...` step after applying manifests:
```bash
# Wait for Nexus readiness then run setup
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nexus \
  -n devops --timeout=300s
./scripts/nexus-setup.sh
```

---

### 1D — SonarQube: Quality Profile Import/Export Scripts

Since SonarQube ships with the built-in "Sonar way" profile and you're not customizing it yet, the approach is:

#### [NEW] [scripts/sonarqube-export.sh](file:///c:/myProjects/devops-setup/scripts/sonarqube-export.sh)
Run this **after** you've customized quality profiles/gates to save them to Git.
```bash
# Usage: SONAR_URL=http://localhost:9000 SONAR_TOKEN=xxx ./sonarqube-export.sh
```
Exports all non-built-in quality profiles to `k8s/config/sonarqube/profiles/`.
Exports all quality gates to `k8s/config/sonarqube/gates/`.

#### [NEW] [scripts/sonarqube-import.sh](file:///c:/myProjects/devops-setup/scripts/sonarqube-import.sh)
Called during `setup` on a fresh deploy. Imports all XML files from `k8s/config/sonarqube/`.
Skips gracefully if directory is empty (handles the "no custom profiles yet" state).

#### [NEW] [k8s/config/sonarqube/.gitkeep](file:///c:/myProjects/devops-setup/k8s/config/sonarqube/.gitkeep)
Empty placeholder directory in Git. Populated by `sonarqube-export.sh` once you start customizing.

---

## Phase 2 — Automated Backup

**Goal**: Daily GCP Disk Snapshots + nightly Postgres dump to GCS. Even catastrophic disk loss has a recovery path.

**Terraform changes required. Estimated GCP cost: ~$1–2/month.**

---

### 2A — Terraform: Disk Snapshot Schedule

#### [MODIFY] [terraform/layers/02-storage/main.tf](file:///c:/myProjects/devops-setup/terraform/layers/02-storage/main.tf)
Add:
```hcl
resource "google_compute_resource_policy" "daily_backup" {
  name    = "devops-daily-backup"
  region  = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "02:00"
      }
    }
    retention_policy {
      max_retention_days    = 14
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      storage_locations = ["us"]
      guest_flush       = false
    }
  }
}

# Attach to all 4 disks
resource "google_compute_disk_resource_policy_attachment" "jenkins"   { ... }
resource "google_compute_disk_resource_policy_attachment" "nexus"     { ... }
resource "google_compute_disk_resource_policy_attachment" "sonarqube" { ... }
resource "google_compute_disk_resource_policy_attachment" "postgres"  { ... }
```

#### [MODIFY] [terraform/layers/02-storage/variables.tf](file:///c:/myProjects/devops-setup/terraform/layers/02-storage/variables.tf)
Add `region` variable (currently missing — only `zone` and `project_id` exist).

#### [MODIFY] [terraform/layers/02-storage/terraform.tfvars](file:///c:/myProjects/devops-setup/terraform/layers/02-storage/terraform.tfvars)
Add `region = "us-central1"`.

---

### 2B — Terraform: GCS Backup Bucket

#### [NEW] [terraform/modules/backup-bucket/main.tf](file:///c:/myProjects/devops-setup/terraform/modules/backup-bucket/main.tf)
New reusable module:
```hcl
resource "google_storage_bucket" "backup" {
  name          = "${var.project_id}-devops-backups"
  location      = "US"
  force_destroy = false

  versioning { enabled = true }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 90 }
  }

  uniform_bucket_level_access = true
}
```

#### [MODIFY] [terraform/layers/02-storage/main.tf](file:///c:/myProjects/devops-setup/terraform/layers/02-storage/main.tf)
Call the `backup-bucket` module and grant the GKE node service account `roles/storage.objectCreator` on the bucket (for Workload Identity).

---

### 2C — Kubernetes: Postgres Backup CronJob

#### [NEW] [k8s/manifests/postgres/cronjob-backup.yaml](file:///c:/myProjects/devops-setup/k8s/manifests/postgres/cronjob-backup.yaml)
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: devops
spec:
  schedule: "0 1 * * *"   # 1 AM UTC daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:15
            command:
            - /bin/sh
            - -c
            - |
              TIMESTAMP=$(date +%Y%m%d_%H%M%S)
              pg_dump -h postgres -U $POSTGRES_USER $POSTGRES_DB \
                | gzip > /tmp/sonar-${TIMESTAMP}.sql.gz
              gsutil cp /tmp/sonar-${TIMESTAMP}.sql.gz \
                gs://${BACKUP_BUCKET}/postgres/
```
Uses the GKE node's Workload Identity — no extra credentials needed.

---

### 2D — Jenkins Backup Pipeline

#### [NEW] [pipelines/Jenkinsfile.backup](file:///c:/myProjects/devops-setup/pipelines/Jenkinsfile.backup)
A Jenkins pipeline (triggered weekly via cron) that:
1. `tar -czf /tmp/jenkins-backup-TIMESTAMP.tar.gz` of `/var/jenkins_home` (excluding `workspace/` and `*.log`)
2. `gsutil cp` to `gs://${BACKUP_BUCKET}/jenkins/`
3. Keeps only last 4 weekly backups (cleans older GCS objects)

---

## Phase 3 — Cross-Project Migration Script

**Goal**: One script to migrate the entire toolchain to a new GCP project.

#### [NEW] [scripts/migrate-to-project.sh](file:///c:/myProjects/devops-setup/scripts/migrate-to-project.sh)
```bash
./scripts/migrate-to-project.sh \
  --source-project devops-environment-488820 \
  --target-project new-project-id \
  --zone us-central1-a
```

Script steps:
1. `--dry-run` mode by default (prints plan, changes nothing)
2. Creates point-in-time snapshots of all 4 source disks
3. Creates new disks in target project from those snapshots
4. Patches `k8s/manifests/storage/pv.yaml` — replaces `volumeHandle` project ID
5. Patches `k8s/manifests/jenkins/jenkins.yaml` — replaces Artifact Registry project reference
6. Prints the next steps:
   ```
   ✅ Migration prep complete.
   Next steps:
     1. cd terraform/layers/02-storage && terraform apply
     2. cd terraform/layers/04-compute && terraform apply
     3. gcloud container clusters get-credentials devops-cluster ...
     4. ./scripts/devops-env.ps1 -Action setup
   ```

---

## Complete File Change List

| Phase | Action | File |
|---|---|---|
| 0 | VERIFY | All 4 Terraform layers apply cleanly |
| 0 | VERIFY | All 4 K8s pods reach Running state |
| 1A | MODIFY | `k8s/manifests/jenkins/plugins.txt` — add `job-dsl`, then pin all versions after boot |
| 1B | MODIFY | `k8s/manifests/jenkins/jenkins.yaml` — add seed job block, parametrize registry |
| 1B | MODIFY | `k8s/manifests/jenkins/statefulset.yaml` — add `ARTIFACT_REGISTRY_PROJECT` env var |
| 1B | NEW | `jenkins/seed/jenkins_jobs.groovy` |
| 1C | NEW | `scripts/nexus-setup.sh` |
| 1C | MODIFY | `scripts/devops-env.ps1` + `devops-env.sh` — add Nexus config step |
| 1D | NEW | `scripts/sonarqube-export.sh` |
| 1D | NEW | `scripts/sonarqube-import.sh` |
| 1D | NEW | `k8s/config/sonarqube/.gitkeep` |
| 2A | MODIFY | `terraform/layers/02-storage/main.tf` — snapshot policy + attachments |
| 2A | MODIFY | `terraform/layers/02-storage/variables.tf` — add `region` |
| 2A | MODIFY | `terraform/layers/02-storage/terraform.tfvars` — add `region` |
| 2B | NEW | `terraform/modules/backup-bucket/` (main.tf, variables.tf, outputs.tf) |
| 2B | MODIFY | `terraform/layers/02-storage/main.tf` — call backup-bucket module |
| 2C | NEW | `k8s/manifests/postgres/cronjob-backup.yaml` |
| 2D | NEW | `pipelines/Jenkinsfile.backup` |
| 3  | NEW | `scripts/migrate-to-project.sh` |

---

## Verification Plan

### Phase 0
- `terraform plan` on each layer before `apply` — no unexpected resources
- `kubectl get pods -n devops` — all 4 pods `Running`
- Port-forward and confirm each UI loads at its expected URL

### Phase 1
- Re-apply Jenkins kustomization — pod restarts, all jobs appear from seed job
- Run `nexus-setup.sh` against running Nexus — confirm repos visible in UI
- Run `sonarqube-import.sh` with empty `k8s/config/sonarqube/` — confirm it skips gracefully
- Extract plugin versions from running pod, update `plugins.txt`, redeploy — confirm same plugins

### Phase 2
- `terraform plan` on `02-storage` — verify 5 new resources (1 policy + 4 attachments) + bucket
- `terraform apply` — confirm snapshot policy visible in GCP Console
- Manually trigger CronJob: `kubectl create job --from=cronjob/postgres-backup manual-test -n devops`
- Verify `.sql.gz` file appears in `gs://${PROJECT_ID}-devops-backups/postgres/`

### Phase 3
- Run `migrate-to-project.sh --dry-run` — verify output plan is correct
- Verify `pv.yaml` is patched with new project ID after live run
