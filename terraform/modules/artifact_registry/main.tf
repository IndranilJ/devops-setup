resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "jenkins_agents" {
  location      = var.region
  repository_id = var.repository_id
  description   = "Docker repository for Jenkins build agents"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]

  docker_config {
    immutable_tags = false
  }
}
