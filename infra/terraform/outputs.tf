output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_location" {
  value = google_container_cluster.primary.location
}

output "registry_url" {
  description = "Artifact Registry base URL — use this in deployment.yaml image field"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/ai-support-bot"
}

output "workload_identity_provider" {
  description = "Workload Identity provider — paste into GitHub secret GCP_WORKLOAD_IDENTITY_PROVIDER"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "cicd_service_account" {
  description = "CI/CD service account email — paste into GitHub secret GCP_SERVICE_ACCOUNT"
  value       = google_service_account.cicd.email
}

output "tfstate_bucket" {
  description = "GCS bucket for Terraform state — use in backend block after tf-migrate"
  value       = google_storage_bucket.tfstate.name
}

output "vllm_logs_bucket" {
  description = "GCS bucket name for vLLM logs — set as VLLM_LOGS_BUCKET in SkyPortal"
  value       = google_storage_bucket.vllm_logs.name
}
