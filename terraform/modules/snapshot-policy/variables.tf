variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name" {
  type    = string
  default = "daily-backup-policy"
}

variable "retention_days" {
  type    = number
  default = 14
}
