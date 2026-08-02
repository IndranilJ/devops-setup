<#
.SYNOPSIS
    First-time SonarQube configuration: changes the default admin password.

.DESCRIPTION
    WHY THIS SCRIPT EXISTS:
    SonarQube ships with a default admin password of "admin". On first startup,
    any API call using the real password will fail because SonarQube still
    expects the default. This script changes it to the value in SONAR_PASSWORD
    before any other configuration runs.

    ORDER IN THE SETUP SEQUENCE:
      devops-env.ps1 calls: sonarqube-setup.ps1  (this script — change password)
                       then: sonarqube-import.ps1  (import quality profiles/gates)
    Setup MUST run first. Import uses the new password; if setup is skipped,
    import will fail with 401 Unauthorized.

    WHY PORT-FORWARD?
    SonarQube is exposed via LoadBalancer but this script runs locally.
    Port-forward tunnels localhost:9000 → sonarqube pod:9000 without needing
    to know the external IP. The process is started in the background and
    killed at the end of the script.

    IDEMPOTENCY:
    The password-change API call is wrapped in try/catch. If the password was
    already changed on a previous run, the API returns an error which is caught
    and logged as a warning — the script does not fail.

    PREREQUISITE:
    $env:SONAR_PASSWORD must be set. devops-env.ps1 sets this from GCP Secret
    Manager before calling this script. To run manually:
      $env:SONAR_PASSWORD = "your-password"
      .\scripts\sonarqube-setup.ps1

.EXAMPLE
    # Normally called by devops-env.ps1 automatically. To run manually:
    $env:SONAR_PASSWORD = (gcloud secrets versions access latest --secret=sonar-admin-password)
    .\scripts\sonarqube-setup.ps1
#>
param ()


$ErrorActionPreference = "Stop"

if (-not $env:SONAR_PASSWORD) {
    Write-Host "WARNING: SONAR_PASSWORD environment variable is not set. Skipping SonarQube setup." -ForegroundColor Yellow
    exit 0
}

Write-Host "Port-forwarding SonarQube..."
$pfProcess = Start-Process -FilePath "kubectl" -ArgumentList "port-forward deployment/sonarqube 9000:9000 -n devops" -PassThru -NoNewWindow
Start-Sleep -Seconds 5

$SonarUrl = "http://localhost:9000"
$Auth = "admin:admin"
$EncodedAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($Auth))
$Headers = @{
    "Authorization" = "Basic $EncodedAuth"
}

Write-Host "Attempting to change default SonarQube password..."

try {
    $Body = @{
        login = "admin"
        previousPassword = "admin"
        password = $env:SONAR_PASSWORD
    }
    Invoke-RestMethod -Uri "$SonarUrl/api/users/change_password" -Headers $Headers -Method Post -Body $Body | Out-Null
    Write-Host "SonarQube default password successfully changed to SONAR_PASSWORD." -ForegroundColor Green
} catch {
    Write-Host "Failed to change SonarQube password. It may have already been changed." -ForegroundColor Yellow
}

if ($pfProcess) {
    Stop-Process -Id $pfProcess.Id -Force -ErrorAction SilentlyContinue
}
Write-Host "SonarQube setup complete."
