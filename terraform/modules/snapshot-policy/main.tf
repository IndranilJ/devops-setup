resource "google_compute_resource_policy" "snapshot_policy" {
  name    = var.name
  region  = var.region
  project = var.project_id

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "04:00" # 4 AM UTC
      }
    }
    retention_policy {
      max_retention_days    = var.retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      labels = {
        backup_type = "automated"
      }
      storage_locations = [var.region]
      guest_flush       = false
    }
  }
}

output "policy_name" {
  value = google_compute_resource_policy.snapshot_policy.name
}

output "policy_self_link" {
  value = google_compute_resource_policy.snapshot_policy.self_link
}

