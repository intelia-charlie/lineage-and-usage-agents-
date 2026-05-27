variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "registry_repo" { type = string }

locals {
  services = [
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "firestore.googleapis.com",
    "aiplatform.googleapis.com",
    "bigquery.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
  ]

  results_bucket = "${var.project_id}-lineage-results-${var.env}"
  demo_bucket    = "${var.project_id}-lineage-demo-${var.env}"
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.services)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.registry_repo}-${var.env}"
  format        = "DOCKER"
  description   = "Container images (${var.env})"

  depends_on = [google_project_service.enabled]
}

resource "google_storage_bucket" "results" {
  project                     = var.project_id
  name                        = local.results_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.env != "prod"

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.enabled]
}

resource "google_storage_bucket" "demo" {
  project                     = var.project_id
  name                        = local.demo_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.env != "prod"

  depends_on = [google_project_service.enabled]
}

resource "google_firestore_database" "default" {
  project     = var.project_id
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_dataset" "raw" {
  project    = var.project_id
  dataset_id = "migration_raw"
  location   = var.region

  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_dataset" "demo" {
  project    = var.project_id
  dataset_id = "migration_demo"
  location   = var.region

  depends_on = [google_project_service.enabled]
}

output "results_bucket_name" {
  value = google_storage_bucket.results.name
}

output "demo_bucket_name" {
  value = google_storage_bucket.demo.name
}
