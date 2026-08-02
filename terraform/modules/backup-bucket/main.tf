resource "google_storage_bucket" "backup" {
  name          = var.bucket_name
  location      = var.location
  project       = var.project_id
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.retention_days
    }
  }

  uniform_bucket_level_access = true
}

output "bucket_name" {
  value = google_storage_bucket.backup.name
}

output "bucket_url" {
  value = google_storage_bucket.backup.url
}
