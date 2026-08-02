output "jenkins_secret_id" {
  value = module.jenkins_secret.secret_id
}

output "nexus_secret_id" {
  value = module.nexus_secret.secret_id
}

output "sonar_secret_id" {
  value = module.sonar_secret.secret_id
}

output "github_secret_id" {
  value = module.github_secret.secret_id
}
