resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_disk" "disk" {
  name       = var.name
  type       = var.type
  zone       = var.zone
  size       = var.size
  labels     = var.labels
  depends_on = [google_project_service.compute]

  lifecycle {
    prevent_destroy = true
  }
}
