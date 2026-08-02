# Jenkins Seed Jobs (Job DSL) Guide

> **File location (single source of truth)**: `config/jenkins/jenkins-jobs.groovy`
>
> All Jenkins jobs are defined as code using the **Job DSL** plugin. A "seed job" reads this Groovy file
> and automatically creates, updates, or deletes other jobs. If Jenkins is ever destroyed, all pipelines
> can be recreated by running the seed job once.

---

## Table of Contents

1. [What is a Seed Job?](#1-what-is-a-seed-job)
2. [Anatomy of a Job Definition](#2-anatomy-of-a-job-definition)
3. [Job Types & Templates](#3-job-types--templates)
4. [Applying Changes](#4-applying-changes)
5. [Folder Structure & Organization](#5-folder-structure--organization)
6. [Key Concepts Reference](#6-key-concepts-reference)
7. [Maintenance Checklist](#7-maintenance-checklist)
8. [FAQ & Common Problems](#8-faq--common-problems)

---

## 1. What is a Seed Job?

A **seed job** is a single Jenkins job that reads a Groovy script (your `jenkins-jobs.groovy`) and automatically generates other jobs from it using the [Job DSL plugin](https://plugins.jenkins.io/job-dsl/).

**Why it matters:**
- Avoids clicking "New Item" in the UI for every project
- Pipelines are version-controlled — they live in Git, not in Jenkins' internal XML
- If Jenkins is deleted, run the seed job once to recreate everything
- Changes to job configs are reviewed via pull requests, not UI clicks

The flow:**
```
config/jenkins/jenkins-jobs.groovy
        ↓  (mounted into pod via ConfigMap)
   Seed Job runs the Groovy script
        ↓
   Jenkins creates/updates/deletes pipeline jobs
```

### Locating the Seed Job
Once Jenkins is started, you will find the seed job at:
**`admin-tasks` → `Seed-Job` → `seed-job`**

If it's not there, run `.\scripts\devops-env.ps1 -Action setup -Method Helm` to force Jenkins to read the Job DSL script for the first time.

---

## 2. Anatomy of a Job Definition

```groovy
// Basic pipeline job template
pipelineJob('devops/my-new-job') {              // <folder>/<job-name>
    description('What this job does')
    displayName('My New Job (Human Readable)')

    // Poll SCM or trigger via webhook
    triggers {
        githubPush()                             // triggers on GitHub push event
        // cron('H/15 * * * *')                 // poll every 15 minutes (alternative)
    }

    // Keep build history manageable
    logRotator {
        numToKeep(30)
        daysToKeep(60)
    }

    definition {
        cpsScm {                                 // "Pipeline script from SCM"
            scm {
                git {
                    remote {
                        url(repoUrl)             // pre-defined variable — your GitHub repo URL
                        credentials('github-token')  // ID must match credentials in jenkins-casc.yaml
                    }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile.my-new-job')  // path within the Git repo
            lightweight(true)                    // fetch only Jenkinsfile, not the full repo (faster)
        }
    }
}
```

---

## 3. Job Types & Templates

### Pipeline job (recommended)

Reads a `Jenkinsfile` from your SCM repository. All our pipelines use this pattern.

```groovy
pipelineJob('devops/deploy-app') {
    description('Deploys the application to GKE')
    definition {
        cpsScm {
            scm {
                git {
                    remote { url(repoUrl); credentials('github-token') }
                    branch('main')
                }
            }
            scriptPath('pipelines/Jenkinsfile.deploy')
        }
    }
}
```

### Folder (grouping jobs)

```groovy
folder('devops') {
    description('DevOps platform maintenance pipelines')
    displayName('DevOps')
}

folder('app-teams') {
    description('Application team CI/CD pipelines')
}
```

> [!IMPORTANT]
> Always define a `folder()` block **before** any `pipelineJob()` that lives inside it. Job DSL processes blocks in order — trying to create a job in a folder that doesn't exist yet will fail.

### Multibranch pipeline

Automatically discovers branches and creates one pipeline per branch.

```groovy
multibranchPipelineJob('app-teams/my-service') {
    description('CI for my-service — builds all branches automatically')
    branchSources {
        github {
            id('my-service-source')
            repoOwner('my-github-org')
            repository('my-service')
            credentialsId('github-token')
        }
    }
    orphanedItemStrategy {
        discardOldItems { numToKeep(5) }
    }
}
```

### Inline pipeline script (quick tests only)

Defines the pipeline script inline rather than from SCM. Useful for admin/maintenance jobs.

```groovy
pipelineJob('devops/cleanup-old-builds') {
    description('Cleans up builds older than 90 days')
    definition {
        cps {
            script('''
                pipeline {
                    agent { label 'python' }
                    stages {
                        stage('Cleanup') {
                            steps {
                                sh 'echo Cleaning up...'
                            }
                        }
                    }
                }
            '''.stripIndent())
            sandbox(true)
        }
    }
}
```

---

## 4. Applying Changes

## 4. Applying Changes

### Method A — Modular Sync & Build (Preferred, no restart)

This is the fastest method. It syncs your local files to the cluster and triggers the seed job in one go.

```powershell
# Syncs jenkins-jobs.groovy and triggers the seed job via API
.\scripts\devops-env.ps1 -Action reload-seed-job
```

### Method B — Full restart (use when also changing plugins)

```powershell
# Syncs all files and restarts Jenkins
.\scripts\devops-env.ps1 -Action reload-jenkins-plugins
```

### Commit your changes

```bash
git add config/jenkins/jenkins-jobs.groovy
git commit -m "feat(jenkins): add deploy-app pipeline"
git push
```

---

## 5. Folder Structure & Organization

Our repository uses this folder hierarchy in Jenkins:

```
Jenkins/
├── devops/                        # Platform maintenance jobs
│   ├── seed-job                   # THE seed job — runs jenkins-jobs.groovy
│   ├── test-agents                # Tests all agent types are working
│   └── cleanup-old-builds         # Housekeeping
└── app-teams/                     # Application CI/CD pipelines
    ├── service-a/
    │   ├── build                  # Build & test
    │   └── deploy                 # Deploy to GKE
    └── service-b/
        └── build
```

**Naming conventions:**
- Folder names: `kebab-case` (e.g., `app-teams`, not `App Teams`)
- Job names: `kebab-case` (e.g., `deploy-app`, not `Deploy App`)
- Full job path: `folder/job-name` (e.g., `devops/test-agents`)

---

## 6. Key Concepts Reference

| Concept | Detail |
|---|---|
| `repoUrl` | Pre-defined variable set in `jenkins-casc.yaml` → points to your GitHub repo URL |
| `credentials('github-token')` | Credential ID — must match an ID defined in `jenkins-casc.yaml` under `credentials:` |
| `scriptPath(...)` | Path to the `Jenkinsfile` **within the Git repository** (not on disk) |
| `lightweight(true)` | Fetches only the Jenkinsfile instead of the full repo — much faster checkout |
| `githubPush()` | Requires the **GitHub plugin** and a GitHub webhook pointed at Jenkins |
| `sandbox(true)` | Runs inline scripts in the Groovy sandbox (safer — limited API access) |

### Available agent labels

| Label | Image | Use for |
|---|---|---|
| `python` | `jenkins-python-agent` | Python, Terraform, gcloud |
| `maven` | `jenkins-maven-agent` | Java, Maven, OpenJDK 21 |
| `nodejs` | `jenkins-nodejs-agent` | Node.js, npm, React |
| `dotnet` | `jenkins-dotnet-agent` | .NET 8, C# |

---

## 7. Maintenance Checklist

- [ ] **Never hardcode credentials** — always use `credentials('id')`. Hardcoded tokens end up in Git history
- [ ] **Define folders before jobs** — Job DSL processes in order; a missing parent folder causes creation to fail
- [ ] **Use kebab-case names** — spaces in job names cause URL encoding issues in webhook payloads
- [ ] **Clean up removed jobs** — removing a `pipelineJob()` block from the Groovy file does NOT delete the job in Jenkins. Either delete it manually from the UI or configure the seed job option **"Delete Removed Jobs"** in the seed job's advanced settings
- [ ] **Validate the `scriptPath`** — ensure the `Jenkinsfile` you reference actually exists at that path in the Git repo
- [ ] **Commit the file** — the seed job reads from the ConfigMap, not from your local disk

> [!WARNING]
> **Never configure jobs through the Jenkins UI.** Any manual UI changes will be **overwritten** the next time the seed job runs. The Groovy file is the source of truth — all changes must go through it.

---

## 8. FAQ & Common Problems

### ❓ Seed job fails — "Script not approved" error

**Cause**: The Job DSL Groovy script uses a sensitive method (like `new File()`) that requires admin approval.

**Fix**: Our infrastructure automates this in `jenkins-casc.yaml` by disabling the sandbox for Job DSL. Ensure your JCasC includes:
```yaml
jenkins:
  globalJobDslSecurityConfiguration:
    useSandbox: false
```

### ❓ Seed job fails — "FATAL: Expecting Ant GLOB pattern"

**Cause**: The Job DSL plugin is attempting to resolve an absolute path (like `/var/jenkins_config/...`) as a relative search pattern.

**Fix**: Never use the `file:` method in JCasC for Job DSL. Instead, use the **`script:`** method with the **`text()`** block as implemented in our `jenkins-casc.yaml`. This injects the Groovy code directly into the job definition, bypassing path resolution logic.

---

### ❓ Job was deleted from the Groovy file but still appears in Jenkins

**Cause**: The seed job does not delete orphaned jobs by default.

**Fix**: Edit the seed job configuration in Jenkins UI:
- Job DSL build step → **Advanced** → **Removed Jobs** → set to `Delete` (not `Ignore`)

Or delete the orphaned job manually: Jenkins UI → right-click job → Delete.

---

### ❓ `repoUrl` variable is empty / null

**Cause**: `repoUrl` is a variable that must be defined somewhere in the Groovy script or passed in as a parameter.

**Fix**: Ensure your `jenkins-jobs.groovy` defines it at the top:
```groovy
def repoUrl = 'https://github.com/your-org/your-repo.git'
```
Or check that the seed job is passing it as a parameter via JCasC.

---

### ❓ Pipeline job says "No such DSL method 'pipelineJob'" on the seed job run

**Cause**: The **Job DSL plugin** is not installed, or is at a version that doesn't support the method.

**Fix**: Confirm `job-dsl:1.90` (or later) is in `config/jenkins/plugins.txt`. Restart Jenkins after adding it.

---

### ❓ GitHub push webhook doesn't trigger the pipeline

**Cause**: Either the webhook isn't configured in GitHub, or Jenkins isn't receiving the payload.

**Checklist:**
1. GitHub repository → Settings → Webhooks → verify the Jenkins URL is set (`http://<jenkins-url>/github-webhook/`)
2. Verify the webhook shows a green checkmark for recent deliveries
3. In Jenkins: `Manage Jenkins → System Log` → look for "GitHub push event received"
4. Confirm the job has `triggers { githubPush() }` in the Groovy definition
5. Confirm the **GitHub plugin** is installed (`github` in `plugins.txt`)

---

### ❓ A job I removed from the Groovy file keeps getting recreated

**Cause**: The seed job is configured to **Keep** removed jobs but you expect them to be deleted.

**Fix**: In the seed job's Job DSL build step:
- **Removed Jobs** → change from `Keep` to `Delete`
- **Removed Views** → change from `Keep` to `Delete`

Re-run the seed job — the orphaned jobs will now be cleaned up.

---

### ❓ Job DSL "access denied" building the seed job

**Cause**: The Jenkins security matrix doesn't grant the seed job permission to create or modify jobs.

**Fix**: In `jenkins-casc.yaml`, ensure the `admin` user (or the service account running the seed job) has `Overall/Administer` or at minimum `Job/Create`, `Job/Configure`, `Job/Delete` permissions.

---

### ❓ How do I test a new job definition without running it in production?

Use the **Job DSL API Viewer** and the seed job's **dry-run** option:

1. Go to your seed job → **Build with Parameters** (if configured)
2. Or use the Job DSL playground: `Manage Jenkins → Job DSL → Script Console`
3. Paste your new Groovy block and click **Run** — it will show what jobs would be created without actually creating them
