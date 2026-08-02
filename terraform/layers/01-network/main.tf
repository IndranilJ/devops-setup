module "vpc_subnet" {
  source       = "../../modules/vpc-subnet"
  network_name = var.network_name
  region       = var.region
  project_id   = var.project_id
}

module "router_nat" {
  source      = "../../modules/router-nat"
  router_name = "${var.network_name}-router"
  nat_name    = "${var.network_name}-nat"
  region      = var.region
  network_id  = module.vpc_subnet.network_id
}

module "iam" {
  source       = "../../modules/iam"
  project_id   = var.project_id
  account_id   = "${var.cluster_name}-sa"
  display_name = "Dedicated Service Account for GKE Cluster ${var.cluster_name}"
  
  roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
    "roles/secretmanager.secretAccessor"
  ]
}
