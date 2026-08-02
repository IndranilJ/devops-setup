variable "network_name" {
  type = string
}

variable "region" {
  type = string
}

variable "ip_cidr_range" {
  type    = string
  default = "10.0.0.0/16"
}

variable "pods_cidr_range" {
  type    = string
  default = "10.1.0.0/16"
}

variable "services_cidr_range" {
  type    = string
  default = "10.2.0.0/16"
}

variable "project_id" {
  type = string
}
