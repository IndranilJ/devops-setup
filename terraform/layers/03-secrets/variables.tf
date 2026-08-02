variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
}

variable "jenkins_password" {
  description = "Jenkins admin password — pass via TF_VAR_jenkins_password env var, never in tfvars"
  type        = string
  sensitive   = true
}

variable "nexus_password" {
  description = "Nexus admin password — pass via TF_VAR_nexus_password env var, never in tfvars"
  type        = string
  sensitive   = true
}

variable "sonar_password" {
  description = "SonarQube admin password — pass via TF_VAR_sonar_password env var, never in tfvars"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub API token for Jenkins"
  type        = string
  sensitive   = true
}
