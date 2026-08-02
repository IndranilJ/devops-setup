#!/bin/bash
set -e

echo "======================================"
echo " Standardized DevOps Agent Starting..."
echo " Agent Type: ${AGENT_TYPE:-Unknown}"
echo "======================================"

echo "--- Core Tools ---"
printf "Terraform: " && terraform -version | head -n 1 || echo "Not Found"
printf "AWS CLI:   " && aws --version || echo "Not Found"
printf "Azure CLI: " && az --version | head -n 1 || echo "Not Found"
printf "GCloud:    " && gcloud version | head -n 1 || echo "Not Found"
printf "Sonar:     " && sonar-scanner --version | grep "SonarScanner" || echo "Not Found"
printf "Trivy:     " && trivy --version | head -n 1 || echo "Not Found"
printf "Docker:    " && docker --version || echo "Not Found"

echo "--- Runtime Tools ---"
if command -v python3 &> /dev/null; then printf "Python:    " && python3 --version; fi
if command -v mvn &> /dev/null; then printf "Maven:     " && mvn --version | head -n 1; fi
if command -v node &> /dev/null; then printf "Node:      " && node --version; fi
if command -v dotnet &> /dev/null; then printf "Dotnet:    " && dotnet --version; fi

echo "======================================"

# Check if we are in verification mode
if [ "$1" == "--verify" ]; then
    echo "Verification complete. Exiting..."
    exit 0
fi

exec /usr/local/bin/jenkins-agent "$@"
