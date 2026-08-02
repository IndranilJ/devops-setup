output "service_account_email" {
  value = google_service_account.sa.email
}

output "service_account_id" {
  value = google_service_account.sa.account_id
}
