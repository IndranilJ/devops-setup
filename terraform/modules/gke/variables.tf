variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "cluster_name" {
  description = "The name of the GKE cluster."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources to."
  type        = string
}

variable "zone" {
  description = "The GCP zone to deploy resources to."
  type        = string
}

variable "network_id" {
  description = "The VPC network ID."
  type        = string
}

variable "subnet_id" {
  description = "The VPC subnet ID."
  type        = string
}

variable "service_account_email" {
  description = "The email of the dedicated service account for the GKE nodes."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods"
  type        = string
  default     = "pods"
}

variable "services_range_name" {
  description = "Secondary range name for services"
  type        = string
  default     = "services"
}

variable "machine_type" {
  description = "Node machine type"
  type        = string
  default     = "e2-standard-4"
}

variable "node_disk_size" {
  description = "Node disk size in GB"
  type        = number
  default     = 50
}

variable "node_disk_type" {
  description = "Node disk type"
  type        = string
  default     = "pd-standard"
}

variable "node_labels" {
  description = "Labels to apply to the nodes"
  type        = map(string)
  default     = {
    environment = "devops"
  }
}
