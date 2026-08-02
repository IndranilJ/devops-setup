# Jenkins Configuration as Code (JCasC) Guide

> **File location (single source of truth)**: `config/jenkins/jenkins-casc.yaml`
>
> JCasC lets you define Jenkins system configuration as a YAML file instead of clicking through the UI.
> Jenkins reads this file at startup via the **Configuration as Code** plugin. Any change to the file
> requires re-applying the ConfigMap and restarting Jenkins (or hot-reloading for JCasC-only changes).

---

## Table of Contents

1. [File Structure & Root Sections](#1-file-structure--root-sections)
2. [The 4 Golden Rules of JCasC Editing](#2-the-4-golden-rules-of-jcasc-editing)
3. [How to Apply Changes](#3-how-to-apply-changes)
4. [Safe Testing Without Restarting](#4-safe-testing-without-restarting)
5. [Common Configuration Examples](#5-common-configuration-examples)
6. [FAQ & Common Problems](#6-faq--common-problems)

---

## 1. File Structure & Root Sections

`jenkins-casc.yaml` is split into major root blocks. Each block maps to a different part of Jenkins:

| Root key | What it controls |
|---|---|
| `jenkins:` | Core system settings — security realm, authorization, number of executors, cloud agent templates |
| `credentials:` | All stored credentials — GitHub tokens, Docker registry passwords, SSH keys |
| `tool:` | Global tool installations — Maven, Node.js, Git paths |
| `jobs:` | Seed job definitions (prefer using `jenkins-jobs.groovy` via the Job DSL plugin instead) |
| `unclassified:` | **Catch-all for plugin settings** — Slack, SonarQube server URL, email, anything a plugin adds to "Configure System" |

> [!TIP]
> When you configure something in the Jenkins UI and then export JCasC, search the exported YAML for the specific plugin name to find which root section it lives under.

---

## 2. The 4 Golden Rules of JCasC Editing

### Rule 1 — Never Copy-Paste the Entire Export

When you click **Export** in `Manage Jenkins → Configuration as Code`, Jenkins dumps **every setting** — including hundreds of defaults you never touched. Copy-pasting the whole thing fills your file with noise and makes future diffs unreadable.

**Do this instead:** Act like a surgeon. Find only the block you changed and merge that specific block into your existing `jenkins-casc.yaml`.

```yaml
# BAD — entire exported blob pasted in
blueOcean: {}
folder: {}
ansiColorBuildWrapper:
  colorMaps:
  - black: "#000000"
  # ... 200 more lines of defaults you didn't configure

# GOOD — only the block you actually changed
unclassified:
  sonarGlobalConfiguration:
    buildWrapperEnabled: true
    installations:
    - name: "SonarQube"
      serverUrl: "http://sonarqube.devops.svc.cluster.local:9000"
```

---

### Rule 2 — Replace Encrypted Secrets with Environment Variable References (CRITICAL)

Jenkins encrypts credentials using a master key stored inside the pod. If you export and commit an encrypted hash, it **will break** on any cluster rebuild because the master key changes.

```yaml
# BAD — encrypted hash that only works with the current pod's master key
credentials:
  system:
    domainCredentials:
    - credentials:
      - string:
          secret: "{AQAAABAAAAAwWsZslCoj6XkcgHLR3I92...}"   # ← NEVER COMMIT THIS
          id: "github-token"
```

```yaml
# GOOD — environment variable reference resolved at runtime from the K8s Secret
credentials:
  system:
    domainCredentials:
    - credentials:
      - string:
          secret: "${GITHUB_TOKEN}"   # ← resolved from jenkins-secrets K8s Secret
          id: "github-token"
```

The Kubernetes Secret (`jenkins-secrets`) is created by `devops-env.ps1 -Action setup -Method Helm` (or `-Method Kubectl`) and the values are injected as environment variables into the Jenkins pod automatically.

---

### Rule 3 — Never Hardcode Infrastructure-Specific Values

The JCasC exporter fills in live values — your current GCP project ID, your LoadBalancer IP, your cluster name. These change when you rebuild or migrate.

```yaml
# BAD — hardcoded values that become stale after any infrastructure change
jenkins:
  clouds:
  - kubernetes:
      templates:
      - containers:
        - image: "us-central1-docker.pkg.dev/devops-environment-12345/devops-agents/jenkins-python-agent:2026.05.1"
```

```yaml
# GOOD — use environment variables for project IDs and dynamic values
jenkins:
  clouds:
  - kubernetes:
      templates:
      - containers:
        - image: "us-central1-docker.pkg.dev/${GCP_PROJECT}/devops-agents/jenkins-python-agent:${AGENT_IMAGE_VERSION}"
```

---

### Rule 4 — Ignore Default Noise

Over 60% of an exported file is empty blocks and default values Jenkins fills in automatically. These are safe to ignore completely — JCasC uses sensible defaults when a key is absent.

```yaml
# IGNORE THESE — they're all defaults, not your configuration
blueOcean: {}
folder: {}
ansiColorBuildWrapper:
  colorMaps:
  - black: "#000000"
  - blue: "#0000FF"
  # ... etc
```

---

## 3. How to Apply Changes

After editing `config/jenkins/jenkins-casc.yaml`:

**Step 1 — Re-apply the ConfigMap** (from project root):
```powershell
$root = "c:\myProjects\devops-setup"
kubectl create configmap jenkins-casc-config `
    --from-file="jenkins.yaml=$root\config\jenkins\jenkins-casc.yaml" `
    --from-file="plugins.txt=$root\config\jenkins\plugins.txt" `
    --from-file="jenkins_jobs.groovy=$root\config\jenkins\jenkins-jobs.groovy" `
    --namespace devops `
    --dry-run=client -o yaml | kubectl apply -f -
```

**Step 2 — Choose your restart method:**

| Method | Action Command | Downtime |
|---|---|---|
| **System Reload** | `.\scripts\devops-env.ps1 -Action reload-jcasc` | Zero |
| **Full Restart** | `.\scripts\devops-env.ps1 -Action reload-jenkins-plugins` | ~3 min |

**Hot-reload (JCasC only — no pod restart):**
```powershell
# Syncs local YAML to cluster and triggers live hot-reload
.\scripts\devops-env.ps1 -Action reload-jcasc
```

> [!TIP]
> After running `reload-casc`, if you changed `jenkins_jobs.groovy`, go to the Jenkins UI and build the `devops/seed-job`. This will apply your job changes without a restart.

> [!WARNING]
> Hot-reload applies JCasC changes only. It does NOT install new plugins. Always use a full restart after changing `plugins.txt`.

---

## 4. Safe Testing Without Restarting

You can validate a JCasC YAML snippet before committing it — without touching the real config file and without restarting the pod.

1. Go to **Manage Jenkins → Configuration as Code**
2. Find the **"Apply new configuration from text"** text box at the bottom
3. Paste your YAML snippet
4. Click **Apply New Configuration**

Jenkins validates the YAML immediately:
- ✅ **Valid**: applies the config live — you can verify it worked in the UI
- ❌ **Invalid**: shows an error with line number and reason — no damage done

Once verified, copy the working block into `config/jenkins/jenkins-casc.yaml` and follow the apply procedure above.

---

## 5. Common Configuration Examples

### Add a SonarQube server

```yaml
unclassified:
  sonarGlobalConfiguration:
    buildWrapperEnabled: true
    installations:
    - name: "SonarQube"
      serverUrl: "http://sonarqube.devops.svc.cluster.local:9000"
      credentialsId: "sonarqube-token"
```

### Add a new Kubernetes cloud agent template

```yaml
jenkins:
  clouds:
  - kubernetes:
      templates:
      - name: "dotnet-agent"
        label: "dotnet"
        showRawYaml: false
        nodeUsageMode: "EXCLUSIVE"
        containers:
        - name: "dotnet-agent"
          image: "us-central1-docker.pkg.dev/${GCP_PROJECT}/devops-agents/jenkins-dotnet-agent:${AGENT_IMAGE_VERSION}"
          resourceRequestCpu: "500m"
          resourceRequestMemory: "1Gi"
          resourceLimitCpu: "1000m"
          resourceLimitMemory: "2Gi"
```

### Add a global credential

```yaml
credentials:
  system:
    domainCredentials:
    - credentials:
      - string:
          id: "sonarqube-token"
          description: "SonarQube user token for Jenkins scanner"
          secret: "${SONAR_TOKEN}"
```

---

## 6. FAQ & Common Problems

### ❓ Jenkins fails to start — "error configuring from configuration-as-code"

**Cause**: YAML syntax error or an unknown key in `jenkins-casc.yaml`.

**Fix**:
```powershell
# Check logs from the failed container
kubectl logs -n devops statefulset/jenkins -c jenkins --previous | Select-String "casc|error|ERROR"
```
The error message includes the offending YAML key. Fix it in `config/jenkins/jenkins-casc.yaml`, re-apply the ConfigMap, and restart.

---

### ❓ My change appeared in the UI during hot-reload but disappeared after a restart

**Cause**: You used the hot-reload UI to test a change but forgot to write it back to `jenkins-casc.yaml`. The file is the source of truth — a restart re-reads the file and overwrites whatever was applied in-memory.

**Fix**: Always copy your validated YAML into `config/jenkins/jenkins-casc.yaml` and commit it.

---

### ❓ Environment variable `${MY_SECRET}` is showing as literal text in Jenkins

**Cause**: The K8s Secret that injects `MY_SECRET` as an env var is missing or has a wrong key name.

**Fix**:
```powershell
# List env vars available in the Jenkins pod
kubectl exec -n devops statefulset/jenkins -c jenkins -- env | Sort-Object

# Check what keys are in the jenkins-secrets K8s Secret
kubectl get secret jenkins-secrets -n devops -o jsonpath='{.data}' | ConvertFrom-Json
```
If the key is missing, add it via the idempotent `kubectl create secret` pattern in `devops-env.ps1`.

---

### ❓ Jenkins exports a `systemMessage` with a Kubernetes cluster address — should I keep it?

**No.** Remove infrastructure-specific values like `serverUrl`, LoadBalancer IPs, and cluster addresses from exported JCasC. Use the internal cluster DNS (`kubernetes.default.svc.cluster.local`) instead, which is stable across rebuilds.

---

### ❓ I configured a plugin in the UI but can't find it in the JCasC export

**Cause**: Some older or poorly maintained plugins don't expose their configuration via the JCasC API.

**Fix**: Check if the plugin has a JCasC schema by going to `Manage Jenkins → Configuration as Code → Documentation` and searching for the plugin name. If it's absent, the plugin doesn't support JCasC — you'll need to manage that setting manually or via a Groovy init script.

---

### ❓ "Unknown symbol" error for a plugin's JCasC key

**Cause**: The JCasC schema for that plugin version has a different key name than what you wrote.

**Fix**: Go to `Manage Jenkins → Configuration as Code → Documentation`. This page lists every supported key for your currently installed plugins. Use it as the authoritative reference.
