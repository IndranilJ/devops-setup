variable "project_id" { type = string }
variable "secret_id" { type = string }
variable "region" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}

variable "secret_data" {
  type    = string
  default = ""
}
