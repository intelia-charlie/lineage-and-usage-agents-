variable "project_id" {
  type        = string
  description = "GCP project ID for this environment (the env boundary)."
}

variable "project_number" {
  type        = string
  description = "GCP project number."
  default     = ""
}

variable "region" {
  type        = string
  description = "Default region for regional resources."
  default     = "australia-southeast1"
}

variable "env" {
  type        = string
  description = "Environment name: dev | sit | prod."
  validation {
    condition     = contains(["dev", "sit", "prod"], var.env)
    error_message = "env must be one of: dev, sit, prod."
  }
}

variable "image_tag" {
  type        = string
  description = "Container image tag (git SHA). 'latest' for local plans."
  default     = "latest"
}

variable "registry_repo" {
  type        = string
  description = "Artifact Registry repository short name (env suffix added automatically)."
  default     = "lineage-agents"
}

variable "backend_url" {
  type        = string
  description = "Cloud Run URL of the backend service, passed as NEXT_PUBLIC_API_BASE to the frontend image build. Set as a GitHub Environment var (BACKEND_URL) after first backend deploy."
  default     = ""
}

variable "frontend_url" {
  type        = string
  description = "Cloud Run URL of the frontend service, added to backend CORS allowed origins. Set as a GitHub Environment var (FRONTEND_URL) after first frontend deploy."
  default     = ""
}
