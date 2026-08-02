# DevOps Cluster — Admin Operations Runbook

> **Audience**: Platform/DevOps admin responsible for keeping the tooling cluster healthy for app teams.
> **Cluster**: GKE `devops-cluster` | Namespace: `devops`
> **Single source of truth for versions**: [`helm/devops-platform/values.yaml`](./helm/devops-platform/values.yaml)

---

## Table of Contents

1. [Version Management Philosophy](#1-version-management-philosophy)
2. [Compatibility Matrix](#2-compatibility-matrix)
3. [Routine Maintenance Tasks](#3-routine-maintenance-tasks)
4. [Updating Jenkins Configuration](#4-updating-jenkins-configuration)
5. [Upgrading Platform Tools](#5-upgrading-platform-tools)
6. [Upgrading Jenkins Agent Images](#6-upgrading-jenkins-agent-images)
7. [Jenkins Plugin Management](#7-jenkins-plugin-management)
8. [Cluster Health Monitoring](#8-cluster-health-monitoring)
9. [Backup & Recovery](#9-backup--recovery)
10. [Incident Response Runbooks](#10-incident-response-runbooks)
11. [Cost Management (Hibernate / Wake)](#11-cost-management-hibernate--wake)
12. [Onboarding App Teams](#12-onboarding-app-teams)
13. [Security & Access Control](#13-security--access-control)
14. [Quarterly Admin Checklist](#14-quarterly-admin-checklist)
15. [One-Time Cluster Setup](#15-one-time-cluster-setup)

---

## 15. One-Time Cluster Setup

After a fresh Terraform apply or when migrating to a new project, use `devops-env.ps1` to bootstrap the environment.

### Choice of Method

The platform supports two deployment methods via the `-Method` flag:

| Method | Script | Description |
|---|---|---|
| **Helm (Standard)** | `helm-deploy.ps1` | **Recommended.** Uses Helm charts for revision history, atomic upgrades, and state management. |
| **Kubectl (Fallback)** | `k8s-deploy.ps1` | Applies raw YAML manifests from `k8s/manifests/`. Use for disaster recovery if Helm is corrupted. |

### Bootstrapping with Helm (Recommended)

```powershell
# Bootstraps Namespace, ResourceQuotas, Secrets, ConfigMaps, and Helm Release
.\scripts\devops-env.ps1 -Action setup -Method Helm
```

### Fast Updates (Jenkins Maintenance)
When you are only updating Jenkins configuration (JCasC) or Job DSL scripts, you can skip the long SonarQube and Nexus initialization steps to save time:

```powershell
# Bypasses Tool API configuration (saves ~5-10 minutes)
.\scripts\devops-env.ps1 -Action setup -SkipSonar -SkipNexus
```

### Why two scripts?
We decouple the logic to ensure that infrastructure pre-requisites (like GCP Secrets and Namespaces) are handled correctly before the application workloads start. The `setup` action in `devops-env.ps1` orchestrates the secret fetching from GCP Secret Manager and passes them into these specialized deployment scripts.

---

## 1. Version Management Philosophy

All image and tool versions are **centrally governed** in [`helm/devops-platform/values.yaml`](./helm/devops-platform/values.yaml).

**Rules:**
- Never use `:latest` in any manifest or Dockerfile
- Every change to a platform tool version is made in `values.yaml` only — no other file needs editing
- Every change to an agent image version requires a bump to `agentImageVersion` in `values.yaml` (format: `YYYY.MM.N`)
- All Dockerfiles accept versions via `ARG` — the build script passes them from `versions.env` (agent builds only)
- After editing `values.yaml`, run `helm-deploy.ps1 -Action deploy` to apply changes

> [!NOTE]
> `versions.env` and `sync-versions.ps1` are **legacy tools** kept for reference and troubleshooting. They are no longer part of the normal upgrade workflow. See the strikethrough sections below.

**Version flow (current — Helm):**

```
helm/devops-platform/values.yaml
     ↑                    ↓
  (edit here)    .\scripts\helm-deploy.ps1 -Action deploy
                          ↓
               helm upgrade --atomic → rolling pod restart
```

~~**Version flow (legacy — deprecated):**~~

```
~~versions.env  →  sync-versions.ps1  →  K8s manifests + Dockerfiles~~
~~     ↑                                         ↓~~
~~  (edit here)                         kubectl apply / docker build~~
```

**Version naming:**

| Asset | Format | Example |
|---|---|---|
| Platform tools | Upstream semver | `2.504.1-lts-jdk21` |
| Agent images | `YYYY.MM.N` | `2026.05.1` |
| Tools inside agents | Upstream semver | `1.9.8` |

---

## 2. Compatibility Matrix

> **Critical**: The Jenkins controller and ALL inbound agents MUST run the same Java version.
> Java version is encoded in class file version: Java 17 = 61.0, Java 21 = 65.0.

| Component | Image | Tag | Java | Notes |
|---|---|---|---|---|
| Jenkins Controller | `jenkins/jenkins` | `2.555.1-jdk21` | **21** | Required for Prism API/JCasC |
| Jenkins Agents | `jenkins/inbound-agent` | `3301.v4363ddcca_4e7-1` | **21** | Must match controller |
| Nexus | `sonatype/nexus3` | `3.68.0` | Bundled 11 | No external JRE dependency |
| SonarQube | `sonarqube` | `10.5.1-community` | Bundled 17 | Requires Postgres 13-16 |
| PostgreSQL | `postgres` | `15.7` | n/a | Supported by SonarQube 10.x |
| gcloud Sidecar | `google/cloud-sdk` | `502.0.0-alpine` | n/a | Backup sidecar |
| busybox init | `busybox` | `1.36.1` | n/a | Init containers |

**Tool versions inside agents:**

| Tool | Version | Compatibility notes |
|---|---|---|
| Terraform | `1.9.8` | Last OSS 1.x before BSL |
| AWS CLI | `2.27.0` | v2 only |
| Sonar Scanner CLI | `6.2.1.4610` | Must match SonarQube 10.x server |
| gcloud SDK (apt) | `502.0.0` | Match sidecar image |
| Trivy | `0.61.0` | Security scanner |
| Docker CLI | `28.1.0` | DinD builds |
| Python | `3.12` | |
| OpenJDK | `21` | Maven agent only; matches agent base |
| Maven | `3.9.9` | |
| Node.js | `22 LTS` | Via NodeSource |
| .NET SDK | `8.0 LTS` | Via Microsoft apt |

---

## 3. Routine Maintenance Tasks

### 3.1 Daily

```powershell
# Check all pods are healthy
kubectl get pods -n devops

# Check node resource usage
kubectl top nodes
kubectl top pods -n devops
```

### 3.2 Weekly

```powershell
# Check for stuck/pending pods
kubectl get pods -n devops --field-selector=status.phase!=Running

# Verify backups ran (check GCS bucket)
gsutil ls gs://<your-backup-bucket>/jenkins/
gsutil ls gs://<your-backup-bucket>/nexus/
gsutil ls gs://<your-backup-bucket>/postgres/

# Review Jenkins build queue and executor health
# UI: http://<jenkins-url>/computer/
```

### 3.3 Monthly

- [ ] Check upstream release notes for Jenkins LTS, Nexus, SonarQube, Postgres
- [ ] Review Trivy CVE scan results on agent images
- [ ] Rotate GCP service account keys if applicable
- [ ] Review Jenkins plugin update suggestions (see section 7)
- [ ] Review GKE node pool version against available upgrades
- [ ] Review GCS backup retention policy

### 3.4 After Any SonarQube Quality Rule Change

Unlike Jenkins (which has JCasC), SonarQube Community Edition has no native config-as-code support. Quality Profiles and Quality Gates are stored only in SonarQube's Postgres database. The export script bridges this gap — it pulls the rules via REST API and saves them as files you can commit to Git.

**Prerequisite** — set the SonarQube admin password in your session:
```powershell
$env:SONAR_PASSWORD = (gcloud secrets versions access latest --secret=sonar-admin-password)
```

**Run the export:**
```powershell
# Exports all custom quality profiles and gates to config/sonarqube/
.\scripts\devops-env.ps1 -Action export-sonar-config
```

**Run the import:**
```powershell
# Restores profiles and gates from local files to the cluster
.\scripts\devops-env.ps1 -Action import-sonar-config
```

### 3.5 Managing SonarQube Plugins

If you install new plugins via the Marketplace or add `.jar` files locally:

```powershell
# Download .jar files from the pod to your local Git repo
.\scripts\devops-env.ps1 -Action export-sonar-plugins

# Push local .jar files to a new pod + Clean Sync + Restart
.\scripts\devops-env.ps1 -Action import-sonar-plugins
```

**What the export script does internally:**
1. Calls `/api/qualityprofiles/search` — lists all profiles, filters out built-in ones
2. For each custom profile: calls `/api/qualityprofiles/backup` — downloads the full XML rule definition
3. Calls `/api/qualitygates/list` — lists all gates, filters out built-in "Sonar way" gate
4. For each custom gate: downloads every metric threshold as JSON

**What gets exported:**

| File pattern | Contents |
|---|---|
| `config/sonarqube/<lang>_<name>.xml` | Quality profile — rules + severity overrides |
| `config/sonarqube/gate_<name>.json` | Quality gate — metric name + operator + threshold |

> [!IMPORTANT]
> Always commit the exported files to Git. If your cluster is destroyed, these files are the only record of your custom rules.

```powershell
git diff config/sonarqube/           # review changes
git add config/sonarqube/
git commit -m "chore: export SonarQube quality config snapshot"
git push
```

**What is NOT exported** (known limitations):
- Built-in "Sonar way" profiles — SonarQube rebuilds these automatically
- Project scan history and vulnerability reports — covered by GCS backup
- User accounts and permission assignments — must be recreated manually after a full cluster rebuild

> [!TIP]
> **Import is automatic.** `devops-env.ps1 -Action setup` calls `sonarqube-import.ps1` automatically after SonarQube is ready. On a new cluster you don't need to run it manually.
>
> **Idempotency:** The import script is safe to re-run. If a Quality Profile or Gate already exists, it skips it with a yellow warning — it will not crash or duplicate rules.

**What happens during import (for reference):**
1. `devops-env.ps1` boots SonarQube and changes the default admin password
2. It calls `sonarqube-import.ps1` automatically
3. The script scans `config/sonarqube/` for `.xml` and `.json` files
4. **Profiles:** uploads each XML via `multipart/form-data` to `/api/qualityprofiles/restore`
5. **Gates:** creates the gate, wipes the default conditions, then calls `/api/qualitygates/create_condition` for every threshold individually

---

## 4. Updating Jenkins Configuration

> **Config file location (single source of truth)**: `config/jenkins/`
>
> | File | Purpose |
> |---|---|
> | `config/jenkins/jenkins-casc.yaml` | JCasC — Jenkins system config, cloud agents, credentials |
> | `config/jenkins/plugins.txt` | Pinned plugin list loaded at container startup |
> | `config/jenkins/jenkins-jobs.groovy` | Seed job DSL — defines all Jenkins pipelines |

> **Deep-dive guides:**
> - 📖 [`JCASC_GUIDE.md`](./JCASC_GUIDE.md) — JCasC golden rules, safe testing, config examples, FAQ
> - 📖 [`JENKINS_PLUGINS_GUIDE.md`](./JENKINS_PLUGINS_GUIDE.md) — adding/updating plugins, dependency resolution, FAQ
> - 📖 [`JENKINS_SEED_JOBS_GUIDE.md`](./JENKINS_SEED_JOBS_GUIDE.md) — job types, folder structure, apply methods, FAQ

> [!IMPORTANT]
> The `jenkins-casc-config` ConfigMap is **not managed by Helm**. Helm cannot read files outside its chart directory, so this ConfigMap is pre-created from `config/jenkins/` and managed manually. After editing any of these files, you must re-apply the ConfigMap and restart Jenkins.

### 4.1 Applying Changes

The platform now supports modular "hot" reloads and safe restarts via the primary orchestration script.

| Change Type | File | Action Command |
|---|---|---|
| **System Settings** | `jenkins-casc.yaml` | `.\scripts\devops-env.ps1 -Action reload-jcasc` |
| **Pipelines** | `jenkins-jobs.groovy` | `.\scripts\devops-env.ps1 -Action reload-seed-job` |
| **Plugins** | `plugins.txt` | `.\scripts\devops-env.ps1 -Action reload-jenkins-plugins` |

> [!TIP]
> **Hot Reloads:** `reload-jcasc` and `reload-seed-job` do NOT restart the Jenkins pod. They use a live API call for zero-downtime updates.
>
> **Safe Restarts:** `reload-jenkins-plugins` will perform a rollout restart, which is required to install new `.jpi` files.
---

```powershell
# Port-forward Jenkins
kubectl port-forward svc/jenkins 8080:8080 -n devops &

# Trigger JCasC reload via API (replace <password> with admin password)
$creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:<password>"))
Invoke-RestMethod -Uri "http://localhost:8080/configuration-as-code/reload" `
    -Method Post `
    -Headers @{ Authorization = "Basic $creds" }
```

> [!WARNING]
> Hot-reload applies JCasC changes only — it does NOT reload plugins or seed jobs. Always use a full restart (Step 3 above) after changing `plugins.txt` or `jenkins-jobs.groovy`.

---

## 5. Upgrading Platform Tools

> **Script**: `.\scripts\helm-deploy.ps1`  
> **Config**: `helm/devops-platform/values.yaml`

All platform tool upgrades are now a two-step process: edit `values.yaml`, deploy.

**Upgrade flow:**
1. Check upstream release notes and compatibility (see section 2)
2. Edit the version tag in `helm/devops-platform/values.yaml`
3. Preview: `helm-deploy.ps1 -Action diff` — shows exactly what will change
4. Deploy: `helm-deploy.ps1 -Action deploy` — atomic upgrade with auto-rollback on failure
5. Verify pods are healthy: `kubectl get pods -n devops`
6. Commit the updated `values.yaml`

### Example: Upgrade Jenkins

```powershell
# Step 1: Check https://www.jenkins.io/changelog-stable/ — verify Java version unchanged
# Step 2: Edit values.yaml
#   jenkins:
#     tag: "2.555-jdk21"   ← ensure version satisfies plugin requirements

# Step 3: Preview changes
.\scripts\helm-deploy.ps1 -Action diff

# Step 4: Deploy
.\scripts\helm-deploy.ps1 -Action deploy

# Rollback if needed (N = revision number from 'helm history devops-platform')
helm history devops-platform -n devops
.\scripts\helm-deploy.ps1 -Action rollback -Revision N
```

### Example: Upgrade Nexus

```yaml
# In values.yaml:
nexus:
  tag: "3.69.0"   # ← change this
```
```powershell
.\scripts\helm-deploy.ps1 -Action deploy
```
> [!WARNING]
> Never skip more than one Nexus minor version. Check the [Nexus upgrade path](https://help.sonatype.com/en/upgrade-compatibility-matrix.html) first.

### Example: Upgrade SonarQube

```yaml
# In values.yaml:
sonarqube:
  tag: "10.6.0-community"   # ← change this
```
```powershell
.\scripts\helm-deploy.ps1 -Action deploy
```
> [!WARNING]
> SonarQube upgrades may run DB migrations on first startup. Wait for `/api/system/status` → `{"status":"UP"}` before declaring success. Allow up to 10 min.

### Example: Upgrade Postgres (minor only)

```yaml
# In values.yaml:
postgres:
  tag: "15.8"   # ← minor bump only
```
```powershell
# TAKE A BACKUP FIRST
.\scripts\helm-deploy.ps1 -Action deploy
```
> [!CAUTION]
> **Major Postgres upgrades** (e.g., 15 → 16) require `pg_dump` / `pg_upgrade` — NOT a simple tag change. See `RESTORATION_GUIDE.md` for the major upgrade procedure.

---

<details>
<summary>⚠️ Legacy upgrade method (deprecated — kept for reference/troubleshooting)</summary>

> These scripts are disabled with throw-guards. Do not run them in production. They are preserved for reference only.

~~The upgrade flow:~~
1. ~~Update the version tag in `versions.env`~~
2. ~~Run `sync-versions.ps1 -DryRun` to preview all file changes~~
3. ~~Run `sync-versions.ps1` to write the changes~~
4. ~~`upgrade-tool.ps1` validates the new image is pullable~~
5. ~~Applies the new image via `kubectl set image` (rolling update)~~

```powershell
# DEPRECATED — do not run
# .\scripts\upgrade-tool.ps1 -Tool jenkins -NewVersion 2.504.2-lts-jdk21
# .\scripts\upgrade-tool.ps1 -Tool jenkins -Action rollback -RollbackToVersion 2.504.1-lts-jdk21
# .\scripts\upgrade-tool.ps1 -Tool nexus -NewVersion 3.69.0
# .\scripts\upgrade-tool.ps1 -Tool sonarqube -NewVersion 10.6.0-community
# .\scripts\upgrade-tool.ps1 -Tool postgres -NewVersion 15.8
```

</details>

---

## 6. Upgrading Jenkins Agent Images

Agent images are custom-built and stored in GCP Artifact Registry.

### Full upgrade workflow

```powershell
# 1. Edit values.yaml — bump agentImageVersion and any tool versions
#    e.g. jenkins.agentImageVersion: "2026.06.1", agents.terraform: "1.10.0"

# 2. Build and push all agents (reads versions from versions.env via --build-arg)
.\scripts\build-agents.ps1

# 3. Update agentImageVersion in values.yaml then deploy
#    (Helm restarts Jenkins StatefulSet to pick up the new image tag)
.\scripts\helm-deploy.ps1 -Action deploy

# 4. Trigger a test build to verify agents start correctly
#    Jenkins UI -> pick any pipeline -> Build Now
```

<details>
<summary>~~Legacy step 4 (deprecated)~~</summary>

```powershell
# DEPRECATED — upgrade-tool.ps1 is disabled
# .\scripts\upgrade-tool.ps1 -Tool agents -NewVersion 2026.06.1
# .\scripts\sync-versions.ps1 -Target agents
```
</details>

### Build a single agent (faster for targeted upgrades)

```powershell
# Filter to one agent type; version override for one-off builds
.\scripts\build-agents.ps1 -AgentFilter python -AgentVersion 2026.06.1

# Dry run - see what would be built without actually building
.\scripts\build-agents.ps1 -DryRun
```

### Verify an agent image locally before deploying

```powershell
# The --verify flag runs the entrypoint in check-only mode and prints all tool versions
docker run --rm \
  us-central1-docker.pkg.dev/devops-environment-488820/devops-agents/jenkins-python-agent:2026.06.1 \
  --verify
```

### Java version mismatch quick reference

| Controller image | Required agent base tag |
|---|---|
| `jenkins/jenkins:*-jdk17` | `jenkins/inbound-agent:*jdk17*` |
| `jenkins/jenkins:*-jdk21` | `jenkins/inbound-agent:3301.v4363ddcca_4e7-1` |

---

<details>
<summary>~~5a. Version Sync Tool (deprecated — legacy reference only)~~</summary>

> **Script**: ~~`.\scripts\sync-versions.ps1`~~
>
> This was the bridge between `versions.env` and all files that consumed versions.
> **Replaced by**: editing `values.yaml` and running `helm-deploy.ps1 -Action deploy`.
> The script is preserved (disabled with throw-guard) for troubleshooting reference.

~~### Auto mode — sync everything from versions.env~~

```powershell
# DEPRECATED — do not run (throws on execution)
# .\scripts\sync-versions.ps1 -DryRun
# .\scripts\sync-versions.ps1
# .\scripts\sync-versions.ps1 -Target jenkins
# .\scripts\sync-versions.ps1 -Target agents
# .\scripts\sync-versions.ps1 -ShowStatus   # drift detection
```

~~### Manual override mode — troubleshooting a single service~~

~~When you pass any `-Override*` param, only that specific value is updated. No versions.env is read.~~

```powershell
# DEPRECATED — use 'helm-deploy.ps1 -Action rollback' instead
# .\scripts\sync-versions.ps1 -OverrideNexusTag "3.67.0"
# .\scripts\sync-versions.ps1 -OverrideAgentBaseTag "latest-jdk17"
# .\scripts\sync-versions.ps1 -OverrideJenkinsTag "2.503.1-lts-jdk21"
```

~~### Available override params~~

| ~~Param~~ | ~~Affects~~ |
|---|---|
| ~~`-OverrideJenkinsTag`~~ | ~~Jenkins controller image~~ |
| ~~`-OverrideAgentBaseTag`~~ | ~~`JENKINS_AGENT_BASE_TAG` ARG in all 4 Dockerfiles~~ |
| ~~`-OverrideAgentImageVersion`~~ | ~~`AGENT_IMAGE_VERSION` env var in jenkins statefulset~~ |
| ~~`-OverrideNexusTag`~~ | ~~Nexus image~~ |
| ~~`-OverrideSonarQubeTag`~~ | ~~SonarQube image~~ |
| ~~`-OverridePostgresTag`~~ | ~~Postgres image~~ |
| ~~`-OverrideGcloudTag`~~ | ~~gcloud-sdk sidecar~~ |
| ~~`-OverrideBusyboxTag`~~ | ~~busybox init containers~~ |

</details>

## 7. Jenkins Plugin Management

> 📖 **Full guide**: [`JENKINS_PLUGINS_GUIDE.md`](./JENKINS_PLUGINS_GUIDE.md) — format reference, dependency resolution, all troubleshooting FAQs

### Update plugins safely

```powershell
# 1. Review plugin changelogs in Jenkins UI: Manage Jenkins -> Plugins -> Updates
# 2. Export current plugin list for rollback reference
kubectl exec -n devops statefulset/jenkins -c jenkins -- \
  jenkins-plugin-cli --list > plugins-backup-$(Get-Date -Format 'yyyy-MM-dd').txt

# 3. Edit config/jenkins/plugins.txt with new pinned versions (single source)
# 4. Re-apply the ConfigMap and restart Jenkins (see section 4 for full procedure)
$root = "c:\myProjects\devops-setup"
kubectl create configmap jenkins-casc-config `
    --from-file="jenkins.yaml=$root\config\jenkins\jenkins-casc.yaml" `
    --from-file="plugins.txt=$root\config\jenkins\plugins.txt" `
    --from-file="jenkins_jobs.groovy=$root\config\jenkins\jenkins-jobs.groovy" `
    --namespace devops --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart statefulset/jenkins -n devops
```

> [!IMPORTANT]
> All plugin entries in `config/jenkins/plugins.txt` must include an explicit version (e.g., `job-dsl:1.90`). Never leave entries unpinned.

### Add a new plugin

1. Find the plugin on [plugins.jenkins.io](https://plugins.jenkins.io) and note its latest stable version
2. Add `plugin-name:version` to `config/jenkins/plugins.txt`
3. Re-apply the ConfigMap and restart (commands above) — the init container installs it on next pod start

---

## 8. Cluster Health Monitoring

### Key checks

```powershell
# Pod health
kubectl get pods -n devops -o wide

# Events (last 1h, sorted)
kubectl get events -n devops --sort-by='.lastTimestamp' | tail -30

# Resource usage
kubectl top pods -n devops

# PVC utilization
kubectl get pvc -n devops
```

### Recommended GCP Alerts

| Alert | Condition | Action |
|---|---|---|
| Pod crash loop | restartCount > 3 in 10min | Page on-call |
| PVC > 80% full | Cloud Monitoring disk alert | Expand PVC or run cleanup |
| Jenkins build queue > 20 | Build backlog | Add agents / scale node pool |
| Backup job failure | GCS object not updated in 25h | Investigate CronJob |

---

## 9. Backup & Recovery

### Backup locations

| Type | Location | Contains |
|---|---|---|
| **GCS Logical Backups** | `gs://devops-environment-488820-devops-backups/` | `jenkins/` — JENKINS_HOME tarballs<br>`nexus/` — nexus-data tarballs<br>`postgres/` — pg_dump SQL dumps |
| **GCP Disk Snapshots** | GCP Console → Compute Engine → Storage → Snapshots | Full disk state for each PV |

### Verify backups are running

```powershell
# Check most recent backup files in GCS
gsutil ls -lh gs://devops-environment-488820-devops-backups/jenkins/ | tail -5
gsutil ls -lh gs://devops-environment-488820-devops-backups/nexus/   | tail -5
gsutil ls -lh gs://devops-environment-488820-devops-backups/postgres/ | tail -5

# Check that backup CronJobs ran without error
kubectl get cronjobs -n devops
kubectl get jobs -n devops --sort-by=.metadata.creationTimestamp | tail -10
```

| Component | RPO | RTO | Method |
|---|---|---|---|
| Jenkins config | 24h | 30min | Restore from GCS + helm deploy |
| Jenkins job history | 24h | 30min | Included in JENKINS_HOME backup |
| Nexus artifacts | 24h | 45min | Restore from GCS |
| Postgres (SonarQube DB) | 24h | 20min | pg_restore from GCS dump |

> [!IMPORTANT]
> For detailed, step-by-step recovery procedures for all scenarios above, see the 📖 [**RESTORATION_GUIDE.md**](./RESTORATION_GUIDE.md).

---

### Scenario 1: Data Corruption (Logical Recovery)
> See [**RESTORATION_GUIDE.md Section 2**](./RESTORATION_GUIDE.md#2-restoring-from-gcs-backups-logical-restore)

---

### Scenario 2: Disk Failure (Physical Recovery)
> See [**RESTORATION_GUIDE.md Section 3**](./RESTORATION_GUIDE.md#3-restoring-from-gcp-snapshots-physical-restore)

---

### Scenario 3: Complete GCP Project Loss (Full Disaster Recovery)

> Use this if the entire GCP project is deleted or corrupted.

1. **Re-run Terraform** in a new GCP project to recreate VPC, GKE cluster, disks, and GCS bucket
2. **Copy the backup bucket** to the new project:
   ```bash
   gsutil -m cp -r gs://devops-environment-488820-devops-backups gs://<new-bucket-name>/
   ```
3. **Restore disks** from snapshots (Scenario 2 above) for each service
4. **Re-bootstrap the cluster:**
   ```powershell
   .\scripts\devops-env.ps1 -Action setup -Method Helm
   # This creates namespace, secrets, ConfigMaps, deploys via Helm,
   # and auto-runs sonarqube-import.ps1 to restore quality rules
   ```
5. **Re-configure Nexus** repositories:
   ```powershell
   .\scripts\nexus-setup.ps1
   ```

> [!CAUTION]
> **Test your restores!** A backup is only as good as your last successful restore test. Run Scenario 1 against a staging cluster at least quarterly.

---

## 10. Incident Response Runbooks

### IR-1: Agent Java Version Mismatch

**Symptom**: `UnsupportedClassVersionError: class file version 65.0` in agent logs

**Cause**: The Jenkins controller and agent base images are on different Java versions.

**Fix**:
```powershell
# 1. Confirm Java version in the controller
kubectl exec -n devops statefulset/jenkins -c jenkins -- java -version

# 2. Edit the agent Dockerfile base tag — update JENKINS_AGENT_BASE_TAG ARG
#    in agents/Dockerfile.*-agent (must match controller Java version)

# 3. Rebuild agents with the corrected base image
.\scripts\build-agents.ps1

# 4. Bump agentImageVersion in values.yaml and deploy
#    (This restarts Jenkins StatefulSet with the new agent image tag)
.\scripts\helm-deploy.ps1 -Action deploy
```

<details>
<summary>~~Legacy fix using sync-versions (deprecated)~~</summary>

```powershell
# DEPRECATED
# .\scripts\sync-versions.ps1 -Target dockerfiles
# .\scripts\sync-versions.ps1 -OverrideAgentBaseTag "3301.v4363ddcca_4e7-1"
# .\scripts\upgrade-tool.ps1 -Tool agents -NewVersion <new-AGENT_IMAGE_VERSION>
```
</details>

### IR-2: Jenkins Fails to Start (Config Error)

**Symptom**: Jenkins pod restarts, CasC error in logs

**Fix**:
```powershell
# Check logs from previous (failed) container
kubectl logs -n devops statefulset/jenkins -c jenkins --previous

# Roll back the StatefulSet if a recent change caused it
kubectl rollout undo statefulset/jenkins -n devops
```

### IR-3: Nexus Out of Disk

**Symptom**: Nexus errors, HTTP 500, PVC at 100%

**Fix**:
```powershell
# Resize PVC online (GKE SSD supports this without downtime)
kubectl edit pvc nexus-pvc -n devops
# Change storage: 50Gi -> 100Gi, then save

# Then clean up old artifacts via Nexus Admin UI
# Admin -> Tasks -> "Delete unused components"
```

### IR-4: SonarQube DB Migration Stuck

**Symptom**: SonarQube status = `MIGRATION_RUNNING` for > 30 min

**Fix**:
```powershell
kubectl logs -n devops deployment/sonarqube -c sonarqube

# If migration failed, restore Postgres from backup then roll back SonarQube via Helm:
helm history devops-platform -n devops   # find the last good revision
.\scripts\helm-deploy.ps1 -Action rollback -Revision <N>
```

### IR-5: Full Cluster Restore

See [RESTORATION_GUIDE.md](./RESTORATION_GUIDE.md).

---

## 11. Cost Management (Hibernate / Wake)

```powershell
# Hibernate - scales all workloads to 0 and shrinks node pool (costs only storage)
.\scripts\devops-env.ps1 -Action stop

# Wake up - restores node pool and scales workloads back to 1
.\scripts\devops-env.ps1 -Action start
```

**Cost when hibernating:**
- Compute: $0 (0 GKE nodes)
- Persistent Disks: ~$0.04/GB/month
- GCS backups: ~$0.02/GB/month

---

## 12. Onboarding App Teams

When a new team wants to use the DevOps cluster pipelines:

1. **GitHub Integration**: Add their repo URL to `config/jenkins/jenkins-jobs.groovy` seed job config, then re-apply ConfigMap + restart (see section 4)
2. **Nexus Access**: Create a Nexus role + user via `.\scripts\nexus-setup.ps1`
3. **SonarQube Project**: Create project in SonarQube UI and generate a token for the team
4. **Agent Selection** — advise which label to use in their `Jenkinsfile`:

| Language / Stack | Jenkins label |
|---|---|
| Python | `python` |
| Java / Maven | `maven` |
| Node.js / React | `nodejs` |
| .NET | `dotnet` |

5. **Pipeline Template**: Point them to the sample `Jenkinsfile` in the `pipelines/` directory
6. **Seed Job Reference**: Share [`JENKINS_SEED_JOBS_GUIDE.md`](./JENKINS_SEED_JOBS_GUIDE.md) with the team — it explains how to add their pipeline to `jenkins-jobs.groovy` and all available agent labels

---

## 13. Security & Access Control

### Credential rotation schedule

| Secret | Rotation Cadence | How |
|---|---|---|
| `jenkins-admin-password` | Every 90 days | Update GCP Secret Manager, re-run setup |
| `github-token` | On expiry or leak | Regenerate in GitHub, update GCP Secret |
| `db-password` | Every 180 days | Update Postgres + SonarQube env |
| `nexus-admin-password` | Every 90 days | Nexus UI + GCP Secret |

### Rotate a secret

```powershell
# Update value in GCP Secret Manager
echo "new-password" | gcloud secrets versions add jenkins-admin-password --data-file=-

# Re-create the K8s secret (idempotent)
.\scripts\devops-env.ps1 -Action setup
```

### Image CVE scanning

```powershell
# Scan via GCP Artifact Registry (requires Container Analysis API)
gcloud artifacts docker images scan \
  us-central1-docker.pkg.dev/devops-environment-488820/devops-agents/jenkins-python-agent:2026.05.1 \
  --remote --format=json | jq '.response.scan.name'
```

---

## 14. Quarterly Admin Checklist

- [ ] Review all versions in `helm/devops-platform/values.yaml` against latest upstream releases
- [ ] Update `values.yaml`, run `helm-deploy.ps1 -Action diff` to preview, then `helm-deploy.ps1 -Action deploy`
- [ ] Rebuild agent images if tool versions changed: `build-agents.ps1`
- [ ] Check Jenkins LTS roadmap for upcoming EOL or Java requirement changes
- [ ] Scan all agent images with Trivy; resolve HIGH/CRITICAL CVEs before next build
- [ ] Run `sonarqube-export.ps1` and commit any new quality profile/gate snapshots to `config/sonarqube/`
- [ ] Test full backup-and-restore cycle (see `RESTORATION_GUIDE.md`)
- [ ] Review GKE node pool version — upgrade if more than 2 minor versions behind
- [ ] Rotate all credentials per rotation schedule (section 12)
- [ ] Audit Jenkins user access — remove stale accounts
- [ ] Audit Nexus role assignments
- [ ] Prune GCS backup retention — delete backups older than 90 days
- [ ] Verify disaster recovery RTO/RPO targets are still achievable
- [ ] Update this runbook if any procedures have changed

<details>
<summary>~~Legacy quarterly items (deprecated)~~</summary>

- ~~Run `.\scripts\sync-versions.ps1 -ShowStatus` — check for drift between `versions.env` and manifests~~
- ~~Review all versions in `versions.env` against latest upstream releases~~
- ~~Update `versions.env`, run `sync-versions.ps1`, rebuild agents, apply manifests~~

</details>
