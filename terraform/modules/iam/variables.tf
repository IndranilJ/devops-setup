variable "project_id" {
  type = string
}

variable "account_id" {
  type = string
}

variable "display_name" {
  type = string
}

variable "roles" {
  type    = list(string)
  default = []
}
