resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_secret_manager_secret" "secret" {
  secret_id  = var.secret_id
  labels     = var.labels
  depends_on = [google_project_service.secretmanager]

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "version" {
  count = var.secret_data != "" ? 1 : 0
  
  secret      = google_secret_manager_secret.secret.id
  secret_data = var.secret_data
}
