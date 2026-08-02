terraform {
  backend "gcs" {
    bucket = "devops-tf-state-488820"
    prefix = "terraform/state/network"
  }
}
