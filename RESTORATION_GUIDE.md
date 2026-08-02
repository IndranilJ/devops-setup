# DevOps Cluster — Restoration & Disaster Recovery Guide

> **Audience**: Platform Admins
> **Purpose**: Step-by-step instructions for restoring data from backups.
> **Prerequisites**: Access to the `devops-backups` GCS bucket and GKE cluster.

---

## 1. Restoration Strategy Overview

| Component | Backup Source | Recovery Method |
|---|---|---|
| **Jenkins** | GCS (tarball) | Extract to `/var/jenkins_home` via sidecar |
| **Nexus** | GCS (tarball) | Extract to `/nexus-data` via sidecar |
| **SonarQube** | GCS (SQL dump) | `psql` restore into Postgres sidecar |
| **GCP Disks** | GCP Snapshots | Create new disk → Update `values.yaml` → Helm deploy |

---

## 2. Restoring from GCS Backups (Logical Restore)

Use this when the cluster is running but data (jobs, artifacts, rule sets) has been lost or corrupted.

### 2.1 Restore Jenkins Home
1. Find your backup in GCS: `gsutil ls gs://devops-environment-488820-devops-backups/jenkins/`
2. Exec into the `gcloud-backup` sidecar:
   ```powershell
   $BACKUP_FILE = "jenkins-backup-YYYYMMDD.tar.gz"
   kubectl exec -it jenkins-0 -c gcloud-backup -n devops -- sh -c "
     gsutil cp gs://devops-environment-488820-devops-backups/jenkins/$BACKUP_FILE /tmp/restore.tar.gz
     tar -xzf /tmp/restore.tar.gz -C /var/jenkins_home
     rm /tmp/restore.tar.gz
   "
   ```
3. **Important**: Reload config from disk in Jenkins UI or restart the pod.

### 2.2 Restore Nexus Data
```powershell
$BACKUP_FILE = "nexus-backup-YYYYMMDD.tar.gz"
kubectl exec -it nexus-0 -c gcloud-backup -n devops -- sh -c "
  gsutil cp gs://devops-environment-488820-devops-backups/nexus/$BACKUP_FILE /tmp/restore.tar.gz
  tar -xzf /tmp/restore.tar.gz -C /nexus-data
  rm /tmp/restore.tar.gz
"
# Restart Nexus to pick up files
kubectl delete pod nexus-0 -n devops
```

### 2.3 Restore SonarQube (Postgres)
```powershell
$BACKUP_FILE = "postgres-backup-YYYYMMDD.sql.gz"
kubectl exec -it deployment/postgres -c gcloud-backup -n devops -- sh -c "
  gsutil cp gs://devops-environment-488820-devops-backups/postgres/$BACKUP_FILE /tmp/restore.sql.gz
  gunzip -c /tmp/restore.sql.gz > /tmp/restore.sql
  apk add --no-cache postgresql-client
  psql -h localhost -U sonar -d sonar -f /tmp/restore.sql
  rm /tmp/restore.sql /tmp/restore.sql.gz
"
```

---

## 3. Restoring from GCP Snapshots (Physical Restore)

Use this if a Persistent Disk is corrupted or unreadable.

### Step 1: Create a new disk from the snapshot
```powershell
gcloud compute disks create jenkins-home-restored `
    --source-snapshot=jenkins-home-snapshot-YYYYMMDD `
    --zone=us-central1-a
```

### Step 2: Update the Helm Configuration
1. Open `helm/devops-platform/values.yaml`.
2. Locate the `diskHandle` for the affected service (e.g., `jenkins.storage.diskHandle`).
3. Update the handle to point to your new disk name:
   ```yaml
   jenkins:
     storage:
       diskHandle: "jenkins-home-restored"  # Update this
   ```

### Step 3: Deploy and Remount
```powershell
# 1. Preview the change
.\scripts\helm-deploy.ps1 -Action diff

# 2. Apply change (Helm will update the PV and trigger a pod restart)
.\scripts\helm-deploy.ps1 -Action deploy
```

---

## 4. Full Disaster Recovery (Total Project Loss)

1. **Rebuild Infrastructure**: Run Terraform in the target project.
2. **Move Backups**: Copy the GCS bucket contents if the old bucket is accessible.
3. **Bootstrap Platform**:
   ```powershell
   .\scripts\devops-env.ps1 -Action setup -Method Helm
   ```
4. **Restore Data**: Follow Sections 2 or 3 above to inject data into the fresh disks.
