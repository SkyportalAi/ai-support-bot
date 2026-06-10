variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the GKE cluster and Artifact Registry"
  type        = string
  default     = "us-central1"
}

variable "storage_region" {
  description = "GCS bucket region — kept stable across cluster region changes"
  type        = string
  default     = "US"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "skyportal-autopilot"
}
