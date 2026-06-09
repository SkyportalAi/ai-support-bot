resource "google_service_account" "cicd" {
  account_id   = "ai-support-bot-cicd"
  display_name = "ai-support-bot GitHub Actions CI/CD"
}

# Workload Identity Federation — GitHub Actions authenticates via OIDC, no JSON key needed
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC provider"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.repository_id" = "assertion.repository_id"
    "attribute.ref"           = "assertion.ref"
  }

  # Numeric IDs are immutable — names can be reclaimed after org deletion (cybersquatting risk)
  # repo_id=1242712667 (SkyportalAi/ai-support-bot), owner_id=180767655 (SkyportalAi)
  attribute_condition = "assertion.repository_id == '1242712667' && assertion.repository_owner_id == '180767655' && assertion.ref == 'refs/heads/main'"
}

resource "google_service_account_iam_member" "cicd_wif_binding" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/1242712667"
}

# Scoped to Artifact Registry only — container.developer removed (too broad)
resource "google_project_iam_member" "cicd_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# Scoped helm deploy permission — imageBuilder + targeted deploy access
resource "google_project_iam_member" "cicd_container_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}
