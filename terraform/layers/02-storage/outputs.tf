output "jenkins_disk_name" {
  value = module.jenkins_disk.disk_name
}

output "nexus_disk_name" {
  value = module.nexus_disk.disk_name
}

output "sonar_disk_name" {
  value = module.sonar_disk.disk_name
}

output "postgres_disk_name" {
  value = module.postgres_disk.disk_name
}

output "backup_bucket_name" {
  value = module.backup_bucket.bucket_name
}
