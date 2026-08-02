module "jenkins_disk" {
  source     = "../../modules/persistent-disk"
  name       = "jenkins-home-disk"
  size       = 20
  zone       = var.zone
  labels     = { app = "jenkins" }
  project_id = var.project_id
}

module "nexus_disk" {
  source     = "../../modules/persistent-disk"
  name       = "nexus-data-disk"
  size       = 20
  zone       = var.zone
  labels     = { app = "nexus" }
  project_id = var.project_id
}

module "sonar_disk" {
  source     = "../../modules/persistent-disk"
  name       = "sonarqube-data-disk"
  size       = 10
  zone       = var.zone
  labels     = { app = "sonarqube" }
  project_id = var.project_id
}

module "postgres_disk" {
  source     = "../../modules/persistent-disk"
  name       = "postgres-data-disk"
  size       = 5
  zone       = var.zone
  labels     = { app = "postgres" }
  project_id = var.project_id
}

module "artifact_registry" {
  source        = "../../modules/artifact_registry"
  project_id    = var.project_id
  region        = var.region
  repository_id = "devops-agents"
}

# --- BACKUP CONFIGURATION ---

module "snapshot_policy" {
  source     = "../../modules/snapshot-policy"
  project_id = var.project_id
  region     = var.region
  name       = "devops-disk-backup-policy"
}

resource "google_compute_disk_resource_policy_attachment" "jenkins_attachment" {
  name   = module.snapshot_policy.policy_name
  disk   = module.jenkins_disk.disk_name
  zone   = var.zone
}

resource "google_compute_disk_resource_policy_attachment" "nexus_attachment" {
  name   = module.snapshot_policy.policy_name
  disk   = module.nexus_disk.disk_name
  zone   = var.zone
}

resource "google_compute_disk_resource_policy_attachment" "sonar_attachment" {
  name   = module.snapshot_policy.policy_name
  disk   = module.sonar_disk.disk_name
  zone   = var.zone
}

resource "google_compute_disk_resource_policy_attachment" "postgres_attachment" {
  name   = module.snapshot_policy.policy_name
  disk   = module.postgres_disk.disk_name
  zone   = var.zone
}

module "backup_bucket" {
  source      = "../../modules/backup-bucket"
  project_id  = var.project_id
  bucket_name = "${var.project_id}-devops-backups"
  location    = var.region
}

# --- IAM FOR BACKUPS ---

data "google_service_account" "gke_sa" {
  account_id = "${var.cluster_name}-sa"
  project    = var.project_id
}

resource "google_storage_bucket_iam_member" "backup_manager" {
  bucket = module.backup_bucket.bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_service_account.gke_sa.email}"
}


