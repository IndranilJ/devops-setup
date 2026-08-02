data "google_compute_network" "vpc" {
  name = var.network_name
}

data "google_compute_subnetwork" "subnet" {
  name   = "${var.network_name}-subnet"
  region = var.region
}

data "google_service_account" "gke_sa" {
  account_id = "${var.cluster_name}-sa"
}

module "gke" {
  source                = "../../modules/gke"
  project_id            = var.project_id
  cluster_name          = var.cluster_name
  region                = var.region
  zone                  = var.zone
  network_id            = data.google_compute_network.vpc.id
  subnet_id             = data.google_compute_subnetwork.subnet.id
  service_account_email = data.google_service_account.gke_sa.email

  # Newly parameterized networking ranges
  pods_range_name       = "pods"
  services_range_name   = "services"
  
  # Optional overrides
  machine_type          = "e2-standard-4"
  node_disk_size        = 50
}
