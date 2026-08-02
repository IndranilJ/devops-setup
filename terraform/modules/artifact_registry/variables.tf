variable "region" {
  description = "The GCP region to deploy the repository to."
  type        = string
}

variable "repository_id" {
  description = "The ID of the repository."
  type        = string
}

variable "project_id" {
  description = "The GCP project ID."
  type        = string
}
