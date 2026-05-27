terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # Backend bucket created by infra/setup-gcp-wif.sh (Terraform never creates its own backend).
  # Init: terraform init -backend-config="bucket=${STATE_BUCKET}" \
  #                      -backend-config="prefix=terraform/lineage-agents-state"
  backend "gcs" {
    prefix = "terraform/lineage-agents-state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
