output "repository_id" {
  value = google_artifact_registry_repository.jenkins_agents.repository_id
}

output "repository_name" {
  value = google_artifact_registry_repository.jenkins_agents.name
}
