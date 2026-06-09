provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
locals {
  required_apis = toset([
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
  ])

  # Shared baseline for all GCS buckets in this project
  bucket_defaults = {
    location                    = var.region
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
  }
}

resource "google_project_service" "apis" {
  for_each           = local.required_apis
  service            = each.value
  disable_on_destroy = false
}

# GCS bucket for Terraform state — created first pass, backend migrated second pass
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  location                    = local.bucket_defaults.location
  force_destroy               = local.bucket_defaults.force_destroy
  uniform_bucket_level_access = local.bucket_defaults.uniform_bucket_level_access
  public_access_prevention    = local.bucket_defaults.public_access_prevention

  versioning { enabled = true }

  lifecycle { prevent_destroy = true }

  depends_on = [google_project_service.apis]
}

# GCS bucket for vLLM log exports
resource "google_storage_bucket" "vllm_logs" {
  name                        = "${var.project_id}-vllm-logs"
  location                    = local.bucket_defaults.location
  force_destroy               = local.bucket_defaults.force_destroy
  uniform_bucket_level_access = local.bucket_defaults.uniform_bucket_level_access
  public_access_prevention    = local.bucket_defaults.public_access_prevention

  versioning { enabled = true }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 90 }
  }

  depends_on = [google_project_service.apis]
}

# Grant the log sink service account write access to the bucket
resource "google_storage_bucket_iam_member" "log_sink_writer" {
  bucket = google_storage_bucket.vllm_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.vllm.writer_identity
}

# Log sink — exports vLLM container stdout to GCS
resource "google_logging_project_sink" "vllm" {
  name        = "vllm-logs-to-gcs"
  destination = "storage.googleapis.com/${google_storage_bucket.vllm_logs.name}"

  filter = <<-EOT
    resource.type="k8s_container"
    resource.labels.namespace_name="vllm"
    resource.labels.container_name="vllm"
  EOT

  unique_writer_identity = true

  depends_on = [google_project_service.apis]
}

# Artifact Registry repository
resource "google_artifact_registry_repository" "images" {
  repository_id = "ai-support-bot"
  location      = var.region
  format        = "DOCKER"
  description   = "Container images for ai-support-bot and vLLM"

  depends_on = [google_project_service.apis]
}

# GKE Autopilot cluster
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region

  enable_autopilot = true

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  release_channel { channel = "REGULAR" }

  node_pool_auto_config {
    node_kubelet_config {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  depends_on = [google_project_service.apis]
}
