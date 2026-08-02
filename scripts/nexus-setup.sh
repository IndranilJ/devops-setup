#!/bin/bash
# =============================================================================
# scripts/nexus-setup.sh
# Idempotent bootstrap of Nexus Repository Manager repositories.
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Configures Nexus with the repositories needed by the app teams:
#     - docker-hosted       : Internal Docker image registry
#     - maven-central-proxy : Caches Maven Central artifacts (faster, offline-safe)
#     - npm-proxy           : Caches NPM registry artifacts
#
# PREREQUISITES:
#   1. Nexus pod must be running: kubectl get pods -n devops -l app.kubernetes.io/name=nexus
#   2. NEXUS_PASSWORD env var must be set (done by devops-env.ps1 before calling this)
#   3. kubectl and curl must be available on the machine running this script
#
# WHY PORT-FORWARD?
#   Nexus is exposed via a LoadBalancer Service on port 80 (external).
#   But this script runs from your LOCAL machine, not inside the cluster.
#   Port-forward creates a local tunnel: localhost:8081 -> nexus pod:8081
#   This avoids needing to know the external IP, and works even before
#   the LoadBalancer IP is assigned.
#
# WHY IDEMPOTENT?
#   This script is safe to re-run. The create_repo() function checks if
#   the repository already exists (HTTP 200) before creating it (POST).
#   Re-running will just print "already exists. Skipping." for each repo.
#
# HOW TO RUN:
#   Normally called automatically by devops-env.ps1 -Action setup.
#   To run manually: NEXUS_PASSWORD=<pwd> bash ./scripts/nexus-setup.sh
# =============================================================================

set -e   # Exit immediately if any command fails (prevents silent partial setup)

# ── PORT-FORWARD ──────────────────────────────────────────────────────────────
# Runs port-forward in the background (&) so this script can continue.
# PF_PID captures the background process ID so we can kill it when done.
# stdout/stderr redirected to /dev/null to avoid noise in the script output.
echo "Port-forwarding Nexus to localhost:8081..."
kubectl port-forward svc/nexus 8081:80 -n devops > /dev/null 2>&1 &
PF_PID=$!
sleep 5   # Give the tunnel time to establish before making API calls

NEXUS_URL="http://localhost:8081"
AUTH="-u admin:$NEXUS_PASSWORD"

echo "Configuring Nexus at $NEXUS_URL..."

# ── HELPER: create_repo() ─────────────────────────────────────────────────────
# Idempotent repository creator. Checks existence via GET before POST.
#
# Args:
#   $1 = REPO_NAME   : the unique name of the repository (used in URLs)
#   $2 = RECIPE_NAME : the Nexus format/type path (e.g. docker/hosted, maven/proxy)
#   $3 = REPO_JSON   : the full JSON body for the creation API call
#
# Nexus REST API reference: https://help.sonatype.com/en/rest-and-integration-api.html
create_repo() {
    local REPO_NAME=$1
    local RECIPE_NAME=$2
    local REPO_JSON=$3

    # Check if the repo already exists
    # -s: silent (no progress bar), -o /dev/null: discard body, -w: write HTTP status code
    local STATUS=$(curl -s -o /dev/null -w "%{http_code}" $AUTH "$NEXUS_URL/service/rest/v1/repositories/$REPO_NAME")

    if [ "$STATUS" == "200" ]; then
        echo "Repository '$REPO_NAME' already exists. Skipping."
    else
        echo "Creating repository '$REPO_NAME' (recipe: $RECIPE_NAME)..."
        curl -s -X POST "$NEXUS_URL/service/rest/v1/repositories/$RECIPE_NAME" \
            $AUTH \
            -H "accept: application/json" \
            -H "Content-Type: application/json" \
            -d "$REPO_JSON"
        echo ""
    fi
}

# ── 1. Docker Hosted Repository ───────────────────────────────────────────────
# "hosted" = Nexus stores the artifacts itself (not a proxy to upstream).
# httpPort 8082 is the Docker registry port (separate from the Nexus UI port 8081).
# v1Enabled: false = modern Docker clients only (v2 API).
# forceBasicAuth: true = require credentials for push/pull.
DOCKER_JSON='{
  "name": "docker-hosted",
  "online": true,
  "storage": { "blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "allow_once" },
  "component": { "proprietaryComponents": true },
  "docker": { "v1Enabled": false, "forceBasicAuth": true, "httpPort": 8082 }
}'
create_repo "docker-hosted" "docker/hosted" "$DOCKER_JSON"

# ── 2. Maven Proxy Repository (Maven Central) ─────────────────────────────────
# "proxy" = Nexus fetches from upstream on first request, then caches locally.
# contentMaxAge / metadataMaxAge = how long (minutes) before rechecking upstream.
# Setting to 1440 (24h) means Nexus won't re-download unchanged artifacts daily.
# This makes builds faster and resilient to Maven Central outages.
MAVEN_JSON='{
  "name": "maven-central-proxy",
  "online": true,
  "storage": { "blobStoreName": "default", "strictContentTypeValidation": true },
  "proxy": { "remoteUrl": "https://repo1.maven.org/maven2/", "contentMaxAge": 1440, "metadataMaxAge": 1440 },
  "negativeCache": { "enabled": true, "timeToLive": 1440 },
  "httpClient": { "blocked": false, "autoBlock": true, "connection": { "retries": 0, "userAgentSuffix": "", "timeout": 60, "enableCircularRedirects": false, "enableCookies": false } },
  "maven": { "versionPolicy": "RELEASE", "layoutPolicy": "PERMISSIVE" }
}'
create_repo "maven-central-proxy" "maven/proxy" "$MAVEN_JSON"

# ── 3. NPM Proxy Repository ───────────────────────────────────────────────────
# Proxies the public NPM registry. Same caching benefits as Maven proxy above.
# App teams set their .npmrc to point to this Nexus URL instead of npmjs.org.
NPM_JSON='{
  "name": "npm-proxy",
  "online": true,
  "storage": { "blobStoreName": "default", "strictContentTypeValidation": true },
  "proxy": { "remoteUrl": "https://registry.npmjs.org/", "contentMaxAge": 1440, "metadataMaxAge": 1440 },
  "negativeCache": { "enabled": true, "timeToLive": 1440 },
  "httpClient": { "blocked": false, "autoBlock": true, "connection": { "retries": 0, "userAgentSuffix": "", "timeout": 60, "enableCircularRedirects": false, "enableCookies": false } }
}'
create_repo "npm-proxy" "npm/proxy" "$NPM_JSON"

# ── Enable Docker Bearer Token Realm ─────────────────────────────────────────
# WHY? Docker clients use token-based auth (Bearer tokens) when pushing/pulling.
# Without the DockerToken realm enabled, 'docker login' to Nexus fails with 401.
# This PUT replaces the active realm list — must include the default auth realms
# or all logins will break. Order matters: Nexus evaluates realms in list order.
echo "Enabling Docker Bearer Token Realm..."
curl -s -X PUT "$NEXUS_URL/service/rest/v1/security/realms/active" \
    $AUTH \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d '["NexusAuthenticatingRealm","NexusAuthorizingRealm","DockerToken"]'
echo ""

echo "Nexus setup complete."

# ── CLEANUP ───────────────────────────────────────────────────────────────────
# Kill the background port-forward process now that we're done.
# Without this, the tunnel stays open until the terminal session ends.
kill $PF_PID

