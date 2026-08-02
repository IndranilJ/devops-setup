<#
.SYNOPSIS
    Imports SonarQube Quality Profiles and Quality Gates from backup files.

.DESCRIPTION
    WHAT THIS SCRIPT IMPORTS:
    1. Quality Profiles (.xml files) — define which code analysis rules apply
       per language (Java, Python, JS, etc.). Exported with sonarqube-export.ps1.
    2. Quality Gates (.json files)   — define pass/fail thresholds for builds
       (e.g. "fail if coverage < 80%"). Only custom gates are imported;
       built-in gates (Sonar way) are left untouched.

    WHERE ARE THE BACKUP FILES?
    They live in: k8s/config/sonarqube/
      *.xml         → Quality Profile backups (one per language/profile)
      gate_*.json   → Quality Gate backups (one per gate)
    If this directory is empty or missing, the script skips gracefully.

    QUALITY GATE IMPORT LOGIC (4 steps per gate):
      1. Create the gate (or note it already exists)
      2. Clear all existing conditions (removes SonarQube's auto-populated rules)
      3. Re-add conditions from the JSON backup exactly as they were
      4. Set as default if the backup flags isDefault: true

    WHY CLEAR CONDITIONS BEFORE RE-ADDING?
    SonarQube auto-populates new quality gates with "Clean as You Code" (CAyC)
    rules. If we just add our conditions on top, we get duplicates. Clearing
    first gives us a clean slate matching the exported state exactly.

    PREREQUISITE:
    sonarqube-setup.ps1 must have run first (password must already be changed).
    $env:SONAR_PASSWORD must be set to the current admin password.

    WHEN TO RUN:
    - Automatically during 'devops-env.ps1 -Action setup' (after sonarqube-setup)
    - Manually after restoring a cluster from scratch to re-apply config
    - After sonarqube-export.ps1 has captured a new config snapshot

.EXAMPLE
    # Run manually after cluster restore:
    $env:SONAR_PASSWORD = (gcloud secrets versions access latest --secret=sonar-admin-password)
    .\scripts\sonarqube-import.ps1
#>
param ()


$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $PSScriptRoot "..\config\sonarqube"
if (-not (Test-Path $ConfigDir)) {
    Write-Host "No config directory found at $ConfigDir"
    exit 0
}

Write-Host "Port-forwarding SonarQube..."
$pfProcess = Start-Process -FilePath "kubectl" -ArgumentList "port-forward deployment/sonarqube 9000:9000 -n devops" -PassThru -NoNewWindow
Start-Sleep -Seconds 5

$SonarUrl = "http://localhost:9000"
$Auth = "admin:$env:SONAR_PASSWORD"
$EncodedAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($Auth))
$Headers = @{
    "Authorization" = "Basic $EncodedAuth"
}

Write-Host "Importing Custom SonarQube Quality Profiles..."
$xmlFiles = Get-ChildItem -Path $ConfigDir -Filter "*.xml"

if (-not $xmlFiles -or $xmlFiles.Count -eq 0) {
    Write-Host "No custom Quality Profile XML backups found. Skipping profile import."
} else {
    foreach ($file in $xmlFiles) {
        Write-Host "Importing profile: $($file.Name)"
        $filepath = $file.FullName
        # Using curl to natively handle multipart/form-data upload
        $curlCmd = "curl.exe -s -X POST -u `"admin:$($env:SONAR_PASSWORD)`" -F `"backup=@$filepath`" `"$SonarUrl/api/qualityprofiles/restore`""
        $output = Invoke-Expression $curlCmd
        if ($output -match "errors") {
            Write-Host "Warning/Error importing $($file.Name): $output" -ForegroundColor Yellow
        } else {
            Write-Host "Successfully imported $($file.Name)" -ForegroundColor Green
        }
    }
}

Write-Host "Importing Custom SonarQube Quality Gates..."
$gateFiles = Get-ChildItem -Path $ConfigDir -Filter "gate_*.json"

if (-not $gateFiles -or $gateFiles.Count -eq 0) {
    Write-Host "No custom Quality Gate JSON backups found. Skipping gate import."
} else {
    foreach ($file in $gateFiles) {
        Write-Host "Importing gate: $($file.Name)"
        $gateJson = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $name = $gateJson.name
        $escapedName = [uri]::EscapeDataString($name)
        
        try {
            # 1. Attempt to Create the Gate
            try {
                Invoke-RestMethod -Uri "$SonarUrl/api/qualitygates/create?name=$escapedName" -Headers $Headers -Method Post | Out-Null
                Write-Host "  -> Created gate: $name" -ForegroundColor Green
            } catch {
                Write-Host "  -> Gate '$name' exists. Updating it..." -ForegroundColor Cyan
            }
            
            # 2. Get current conditions (to clear auto-populated CAyC rules or old rules)
            $currentGate = Invoke-RestMethod -Uri "$SonarUrl/api/qualitygates/show?name=$escapedName" -Headers $Headers -Method Get
            if ($currentGate.conditions) {
                foreach ($c in $currentGate.conditions) {
                    Invoke-RestMethod -Uri "$SonarUrl/api/qualitygates/delete_condition?id=$($c.id)" -Headers $Headers -Method Post | Out-Null
                }
            }
            
            # 3. Add conditions from JSON
            if ($gateJson.conditions) {
                foreach ($cond in $gateJson.conditions) {
                    $metric = [uri]::EscapeDataString($cond.metric)
                    $op = [uri]::EscapeDataString($cond.op)
                    $errorVal = [uri]::EscapeDataString($cond.error)
                    Invoke-RestMethod -Uri "$SonarUrl/api/qualitygates/create_condition?gateName=$escapedName&metric=$metric&op=$op&error=$errorVal" -Headers $Headers -Method Post | Out-Null
                }
                Write-Host "  -> Rebuilt $($gateJson.conditions.Count) conditions" -ForegroundColor Green
            }

            # 4. Set as default if needed
            if ($gateJson.isDefault -eq $true) {
                Invoke-RestMethod -Uri "$SonarUrl/api/qualitygates/set_as_default?name=$escapedName" -Headers $Headers -Method Post | Out-Null
                Write-Host "  -> Set as default" -ForegroundColor Green
            }
        } catch {
            Write-Host "Warning/Error importing gate '$name': $_" -ForegroundColor Yellow
        }
    }
}

if ($pfProcess) {
    Stop-Process -Id $pfProcess.Id -Force -ErrorAction SilentlyContinue
}
Write-Host "SonarQube import complete."

