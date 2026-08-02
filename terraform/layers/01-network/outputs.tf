output "network_id" {
  value = module.vpc_subnet.network_id
}

output "subnet_id" {
  value = module.vpc_subnet.subnet_id
}

output "service_account_email" {
  value = module.iam.service_account_email
}
