# Jenkins Plugins Management Guide

> **File location (single source of truth)**: `config/jenkins/plugins.txt`
>
> Jenkins installs all plugins listed in this file at pod startup via the `jenkins-plugin-cli` init container.
> Changes require re-applying the ConfigMap and restarting Jenkins to take effect.

---

## Table of Contents

1. [How plugins.txt Works](#1-how-pluginstxt-works)
2. [File Format](#2-file-format)
3. [Adding a New Plugin](#3-adding-a-new-plugin)
4. [Updating Existing Plugins](#4-updating-existing-plugins)
5. [Applying Changes](#5-applying-changes)
6. [Checking What's Currently Installed](#6-checking-whats-currently-installed)
7. [FAQ & Common Problems](#7-faq--common-problems)

---

## 1. How plugins.txt Works

At pod startup, the Jenkins init container runs `jenkins-plugin-cli` and installs every plugin listed in `plugins.txt`. The process:

1. Init container reads `plugins.txt` from the `jenkins-casc-config` ConfigMap (mounted as a volume)
2. `jenkins-plugin-cli` resolves dependencies automatically and downloads all required `.jar` files
3. Plugin jars are written to `JENKINS_HOME/plugins/`
4. The main Jenkins container starts — JCasC reads `jenkins.yaml`, seed job reads `jenkins-jobs.groovy`

> [!IMPORTANT]
> **Always pin versions.** Never add a plugin without a version number. Unpinned plugins (`git` instead of `git:5.10.1`) will always download the absolute latest version on every restart. A breaking update will silently break your environment.

> [!WARNING]
> **UI-installed plugins are ephemeral.** If you install a plugin via the Jenkins UI (`Manage Jenkins → Plugins → Available`), it lives only in the pod's memory. On the next restart, it will be gone. **Always add it to `config/jenkins/plugins.txt` and commit to Git.**

---

## 2. File Format

```text
# Format: plugin-short-name:version
# Find the short name on https://plugins.jenkins.io/ (the "ID" field on the plugin page)

git:5.10.1
kubernetes:4423.vb_59f230b_ce53
workflow-job:1571.1580.v18e46842c125
configuration-as-code:1967.va_968bd25d1eb_
job-dsl:1.90
```

**Rules:**
- One plugin per line: `id:version`
- Use the exact version string from [plugins.jenkins.io](https://plugins.jenkins.io/) — they can look unusual (e.g., `4423.vb_59f230b_ce53`)
- Comments are allowed with `#`
- Keep the file alphabetically sorted — makes diffs and reviews much cleaner

---

## 3. Adding a New Plugin

1. **Find the plugin** on [plugins.jenkins.io](https://plugins.jenkins.io/)
   - Note the **"ID"** field — this is the short name you put in `plugins.txt`
   - Note the **latest stable release version**

2. **Check compatibility** — confirm the plugin supports your Jenkins LTS version (listed on the plugin page)

3. **Check for security advisories** — visit [jenkins.io/security/advisories](https://www.jenkins.io/security/advisories/) and search the plugin name

4. **Add to `plugins.txt`** (keep alphabetical order):
   ```text
   slack:783.v0a_748b_3b_0313
   ```

5. **Add any required JCasC configuration** if the plugin needs system-level setup — edit `config/jenkins/jenkins-casc.yaml` under `unclassified:`

6. **Apply and verify** (see section 5)

---

## 4. Updating Existing Plugins

### Routine update (single plugin)

1. Find the new version on [plugins.jenkins.io](https://plugins.jenkins.io/) — click the plugin → "Releases" tab
2. Check the changelog for breaking changes or new required dependencies
3. Update the version string in `config/jenkins/plugins.txt`:
   ```diff
   -git:5.10.1
   +git:5.11.0
   ```
4. Apply the change (see section 5)

### Batch update

```powershell
# Check what updates are available for currently installed plugins
# (run this while Jenkins is running)
kubectl exec -n devops statefulset/jenkins -c jenkins -- \
    jenkins-plugin-cli --list | Where-Object { $_ -match "Update available" }
```

> [!CAUTION]
> When updating multiple plugins at once, do it in a maintenance window. Plugin interactions can cause unexpected failures. Update one plugin at a time in production if you haven't tested in staging.

### Handling dependency updates

`jenkins-plugin-cli` resolves dependencies automatically at install time. However, if Jenkins UI shows a warning like "Plugin X is disabled — requires Y:2.0+ but Y:1.9 is installed", you must manually add or update the dependency in `plugins.txt`.

---

## 5. Applying Changes

Plugin updates **always require a full restart** to be installed by the init container.

```powershell
# Syncs plugins.txt and performs a safe rollout restart
.\scripts\devops-env.ps1 -Action reload-jenkins-plugins
```

**What the script does:**
1. Updates the `jenkins-casc-config` ConfigMap with your new `plugins.txt`.
2. Triggers a `kubectl rollout restart` of the Jenkins StatefulSet.
3. Waits for the new pod to become "Ready" (this is when the init container actually installs the plugins).

**Step 3 — Verify the plugin installed:**
```powershell
# Check Jenkins logs during startup for plugin installation messages
kubectl logs -n devops statefulset/jenkins -c jenkins -f | Select-String "Installing|Failed|ERROR"
```

**Step 4 — Commit to Git:**
```bash
git add config/jenkins/plugins.txt
git commit -m "feat(jenkins): add slack plugin 783.v0a_748b_3b_0313"
git push
```

---

## 6. Checking What's Currently Installed

```powershell
# List all installed plugins and their versions (running pod)
kubectl exec -n devops statefulset/jenkins -c jenkins -- \
    jenkins-plugin-cli --list

# Export a snapshot of current plugins (useful as rollback reference before a batch update)
kubectl exec -n devops statefulset/jenkins -c jenkins -- \
    jenkins-plugin-cli --list > plugins-snapshot-$(Get-Date -Format 'yyyy-MM-dd').txt

# Check if a specific plugin is installed
kubectl exec -n devops statefulset/jenkins -c jenkins -- \
    jenkins-plugin-cli --list | Select-String "git"
```

---

## 7. FAQ & Common Problems

### ❓ Jenkins fails to start — "No such plugin: X" or "Failed to install plugin"

**Cause 1**: The version string in `plugins.txt` is wrong — it doesn't exist on the update center.

**Fix**: Go to [plugins.jenkins.io](https://plugins.jenkins.io/), find the plugin, and copy the exact version string from the "Releases" page.

**Cause 2**: The update center is unreachable from inside the cluster (network policy or firewall issue).

**Fix**:
```powershell
# Check if the Jenkins pod can reach the update center
kubectl exec -n devops statefulset/jenkins -c jenkins -- \
    curl -I https://updates.jenkins.io/update-center.json
```

---

### ❓ "Plugin is disabled because of missing dependencies"

**Cause**: A plugin you have listed depends on another plugin that isn't in `plugins.txt` or is at too old a version.

**Fix**: Jenkins tells you the missing dependency in the UI (`Manage Jenkins → Plugins → Installed`). Add the missing plugin (or update its version) in `plugins.txt` and restart.

```powershell
# Quick way to see disabled plugins and why
kubectl exec -n devops statefulset/jenkins -c jenkins -- \
    jenkins-plugin-cli --list | Select-String "disabled|requires"
```

---

### ❓ I installed a plugin via the UI — how do I make it permanent?

1. Find its short name: go to `Manage Jenkins → Plugins → Installed` → look at the plugin's page URL or ID
2. Find the exact version: `Manage Jenkins → Plugins → Installed` shows the installed version
3. Add `id:version` to `config/jenkins/plugins.txt`
4. Re-apply the ConfigMap and commit

The next pod restart will now reinstall it from `plugins.txt` instead of losing it.

---

### ❓ Plugin was working yesterday, now Jenkins crashes on startup

**Cause**: A plugin auto-updated itself (this shouldn't happen with pinned versions, but can happen if you accidentally removed the version pin).

**Fix**:
```powershell
# Roll back to the previous Jenkins pod state
kubectl rollout undo statefulset/jenkins -n devops

# Check which plugin was at a different version:
kubectl logs -n devops statefulset/jenkins -c jenkins --previous | Select-String "plugin|install"
```
Then downgrade the plugin version in `plugins.txt` to the last known good version and restart.

---

### ❓ How do I know which plugins are needed for my pipeline?

Look at your `Jenkinsfile` directives:

| `Jenkinsfile` directive | Plugin needed |
|---|---|
| `withSonarQubeEnv()` | `sonar` |
| `docker.build()` | `docker-workflow` |
| `kubernetes { ... }` agent block | `kubernetes` |
| `git url: ...` | `git` |
| `junit ...` | `junit` |
| `publishHTML(...)` | `htmlpublisher` |
| `withCredentials([...])` | `credentials-binding` |
| `input 'Approve?'` | `pipeline-input-step` (part of workflow-aggregator) |

---

### ❓ The version string for a plugin looks strange (e.g., `4423.vb_59f230b_ce53`)

This is normal for Jenkins plugins that follow the [Incrementals](https://www.jenkins.io/blog/2018/05/15/incremental-builds/) versioning scheme. The `v` prefix and the hash after it are part of the official version string — copy it exactly from the plugin page.
### ❓ JCasC fails to load — "Failed Loading plugin Configuration as Code"

**Symptoms:**
- You cannot log in with the admin password defined in JCasC.
- Pod logs show `SEVERE: Failed Loading plugin Configuration as Code Plugin`.
- Multiple other plugins (analysis-model-api, prism-api, warnings-ng) also report failures.

**Cause:**
This is often a "Cascading Dependency Failure." A low-level dependency (like **Prism API**) now requires a newer Jenkins controller version than you are running. Because Prism API fails, every plugin that depends on it (including JCasC) also fails to load.

**Fix:**
1. Check the logs for `Jenkins (X.XXX) or higher required`.
2. Update the `tag` in `helm/devops-platform/values.yaml` to match or exceed the required version (e.g., `2.555-jdk21`).
3. Re-deploy with `devops-env.ps1 -Action setup -Method Helm`.
