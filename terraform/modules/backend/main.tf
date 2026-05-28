variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "registry_url" { type = string }
variable "image_tag" { type = string }
variable "results_bucket" { type = string }
variable "demo_bucket" { type = string }

variable "frontend_url" {
  type        = string
  description = "Frontend Cloud Run URL, added to CORS allowed origins."
  default     = ""
}

variable "secret_ids" {
  type        = list(string)
  description = "Secret Manager secret IDs this service reads. Created out-of-band; Terraform only grants access."
  default     = []
}

resource "google_service_account" "backend" {
  project      = var.project_id
  account_id   = "backend-sa-${var.env}"
  display_name = "Backend service account (${var.env})"
}

resource "google_project_iam_member" "vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_project_iam_member" "firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_project_iam_member" "bq_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_project_iam_member" "bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_storage_bucket_iam_member" "results_admin" {
  bucket = var.results_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_storage_bucket_iam_member" "demo_reader" {
  bucket = var.demo_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_secret_manager_secret_iam_member" "secret_access" {
  for_each  = toset(var.secret_ids)
  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.backend.email}"
}

resource "google_cloud_run_v2_service" "backend" {
  name     = "backend-${var.env}"
  location = var.region
  project  = var.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.backend.email

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      image = "${var.registry_url}/backend:${var.image_tag}"

      resources {
        limits = {
          cpu    = "2"
          memory = "2Gi"
        }
      }

      env {
        name  = "APP_CORS_ORIGINS"
        value = jsonencode(compact(["http://localhost:3000", "http://localhost:3001", var.frontend_url]))
      }
      env {
        name  = "APP_GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "APP_VERTEX_LOCATION"
        value = var.region
      }
      env {
        name  = "APP_RESULTS_BUCKET"
        value = var.results_bucket
      }
      env {
        name  = "APP_FIRESTORE_DATABASE"
        value = "(default)"
      }

      dynamic "env" {
        for_each = toset(var.secret_ids)
        content {
          name  = "SECRET_${replace(upper(env.value), "-", "_")}_ID"
          value = env.value
        }
      }

      ports {
        container_port = 8080
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_iam_member.vertex_user,
    google_project_iam_member.firestore_user,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "backend_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "url" {
  value       = google_cloud_run_v2_service.backend.uri
  description = "Backend Cloud Run service URL."
}

output "service_account_email" {
  value = google_service_account.backend.email
}
