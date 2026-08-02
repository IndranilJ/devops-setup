output "secret_id" {
  value = google_secret_manager_secret.secret.id
}

output "secret_name" {
  value = google_secret_manager_secret.secret.name
}
