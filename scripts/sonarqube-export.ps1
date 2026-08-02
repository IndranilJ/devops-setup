<#
.SYNOPSIS
    Exports custom SonarQube Quality Profiles and Quality Gates to backup files.

.DESCRIPTION
    WHAT THIS SCRIPT EXPORTS:
    1. Quality Profiles — only CUSTOM profiles (built-in "Sonar way" profiles
       are skipped because they are rebuilt automatically by SonarQube itself).
       Saved as: config/sonarqube/<language>_<name>.xml
    2. Quality Gates — only CUSTOM gates (built-in "Sonar way" gate skipped).
       Saved as: config/sonarqube/gate_<name>.json

    WHY EXPORT?
    SonarQube stores its configuration in its own Postgres database, not in
    files you can check into Git. Exporting produces files that can be committed
    to Git so quality standards survive cluster rebuilds and disasters.

    THE BACKUP / RESTORE CYCLE:
      After making changes in SonarQube UI  →  run sonarqube-export.ps1
      Then commit the new .xml/.json files  →  git commit config/sonarqube/
      On a new cluster / after restore      →  run sonarqube-import.ps1

    WHEN TO RUN:
    - After any change to quality profiles or gates in the SonarQube UI
    - As part of a quarterly backup/audit cycle
    - Before a major SonarQube version upgrade (take a snapshot first)

    PREREQUISITE:
    $env:SONAR_PASSWORD must be set to the current SonarQube admin password.

.EXAMPLE
    $env:SONAR_PASSWORD = (gcloud secrets versions access latest --secret=sonar-admin-password)
    .\scripts\sonarqube-export.ps1

    # Then commit the exported files:
    git add config/sonarqube/
    git commit -m "chore: export SonarQube quality config snapshot"
#>
param ()


$ErrorActionPreference = "Stop"

$ConfigDir = Join-Path $PSScriptRoot "..\config\sonarqube"
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
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

Write-Host "Exporting Custom SonarQube Quality Profiles..."
try {
    $profilesResponse = Invoke-RestMethod -Uri "$SonarUrl/api/qualityprofiles/search" -Headers $Headers -Method Get
    $customProfiles = $profilesResponse.profiles | Where-Object { $_.isBuiltIn -ne $true }

    if (-not $customProfiles -or $customProfiles.Count -eq 0) {
        Write-Host "No custom Quality Profiles found. Skipping profile export."
    }
    else {
        foreach ($sonarProfile in $customProfiles) {
            $lang = $sonarProfile.language
            $name = $sonarProfile.name
            $safeName = $name -replace '[^a-zA-Z0-9]', '_'
            $filename = "${lang}_${safeName}.xml"
            $filepath = Join-Path $ConfigDir $filename
            
            Write-Host "Exporting profile: $name ($lang) -> $filename"
            $escapedName = [uri]::EscapeDataString($name)
            $curlCmd = "curl.exe -s -u `"admin:$($env:SONAR_PASSWORD)`" `"$SonarUrl/api/qualityprofiles/backup?language=$lang&qualityProfile=$escapedName`" -o `"$filepath`""
            Invoke-Expression $curlCmd
        }
    }
}
catch {
    Write-Host "Failed to export profiles: $_" -ForegroundColor Red
}

Write-Host "Exporting Custom SonarQube Quality Gates..."
try {
    $gatesResponse = Invoke-RestMethod -Uri "$SonarUrl/api/qualitygates/list" -Headers $Headers -Method Get
    $customGates = $gatesResponse.qualitygates | Where-Object { $_.isBuiltIn -ne $true }

    if (-not $customGates -or $customGates.Count -eq 0) {
        Write-Host "No custom Quality Gates found. Skipping gate export."
    }
    else {
        foreach ($gate in $customGates) {
            $name = $gate.name
            $safeName = $name -replace '[^a-zA-Z0-9]', '_'
            $filename = "gate_${safeName}.json"
            $filepath = Join-Path $ConfigDir $filename
            
            Write-Host "Exporting gate: $name -> $filename"
            $escapedName = [uri]::EscapeDataString($name)
            $gateDetails = Invoke-RestMethod -Uri "$SonarUrl/api/qualitygates/show?name=$escapedName" -Headers $Headers -Method Get
            $gateDetails | ConvertTo-Json -Depth 10 | Out-File $filepath
        }
    }
}
catch {
    Write-Host "Failed to export gates: $_" -ForegroundColor Red
}

if ($pfProcess) {
    Stop-Process -Id $pfProcess.Id -Force -ErrorAction SilentlyContinue
}
Write-Host "SonarQube export complete."

