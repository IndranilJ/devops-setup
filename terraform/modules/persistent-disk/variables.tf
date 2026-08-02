variable "project_id" { type = string }
variable "name" { type = string }
variable "zone" { type = string }
variable "size" { type = number }
variable "type" {
  type    = string
  default = "pd-standard"
}
variable "labels" {
  type    = map(string)
  default = {}
}
