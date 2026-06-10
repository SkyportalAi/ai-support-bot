terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # GCS backend — written by `make tf-migrate PROJECT_ID=xxx` (run once after tf-apply).
  # backend.tf is created automatically; do not edit versions.tf to enable it.
}
