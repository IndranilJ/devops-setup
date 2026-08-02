module "jenkins_secret" {
  source      = "../../modules/secrets"
  secret_id   = "jenkins-admin-password"
  region      = var.region
  project_id  = var.project_id
  secret_data = var.jenkins_password
}

module "nexus_secret" {
  source      = "../../modules/secrets"
  secret_id   = "nexus-admin-password"
  region      = var.region
  project_id  = var.project_id
  secret_data = var.nexus_password
}

module "sonar_secret" {
  source      = "../../modules/secrets"
  secret_id   = "sonar-admin-password"
  region      = var.region
  project_id  = var.project_id
  secret_data = var.sonar_password
}

module "db_secret" {
  source      = "../../modules/secrets"
  secret_id   = "db-password"
  region      = var.region
  project_id  = var.project_id
  secret_data = var.db_password
}

module "github_secret" {
  source      = "../../modules/secrets"
  secret_id   = "github-token"
  region      = var.region
  project_id  = var.project_id
  secret_data = var.github_token
}
