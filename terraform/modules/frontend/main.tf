variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "registry_url" { type = string }
variable "image_tag" { type = string }
variable "backend_url" {
  type        = string
  description = "Backend Cloud Run URL. Passed as API_URL env var for server-side Next.js routes."
}

resource "google_service_account" "frontend" {
  project      = var.project_id
  account_id   = "frontend-sa-${var.env}"
  display_name = "Frontend service account (${var.env})"
}

resource "google_cloud_run_v2_service" "frontend" {
  name     = "frontend-${var.env}"
  location = var.region
  project  = var.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.frontend.email

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      image = "${var.registry_url}/frontend:${var.image_tag}"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      # Server-side API URL (used by Next.js server components and API routes).
      # NEXT_PUBLIC_API_BASE is baked into the image at build time via Docker --build-arg.
      # API_URL here is a runtime fallback for server-side fetch calls.
      env {
        name  = "API_URL"
        value = var.backend_url
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
}

resource "google_cloud_run_v2_service_iam_member" "frontend_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "url" {
  value       = google_cloud_run_v2_service.frontend.uri
  description = "Frontend Cloud Run service URL."
}
