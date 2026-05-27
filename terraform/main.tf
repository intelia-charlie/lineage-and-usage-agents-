locals {
  registry_url = "${var.region}-docker.pkg.dev/${var.project_id}/${var.registry_repo}-${var.env}"
}

module "project_setup" {
  source        = "./modules/project-setup"
  project_id    = var.project_id
  region        = var.region
  env           = var.env
  registry_repo = var.registry_repo
}

module "backend" {
  source         = "./modules/backend"
  project_id     = var.project_id
  region         = var.region
  env            = var.env
  registry_url   = local.registry_url
  image_tag      = var.image_tag
  results_bucket = module.project_setup.results_bucket_name
  frontend_url   = var.frontend_url

  depends_on = [module.project_setup]
}

module "frontend" {
  source       = "./modules/frontend"
  project_id   = var.project_id
  region       = var.region
  env          = var.env
  registry_url = local.registry_url
  image_tag    = var.image_tag
  backend_url  = module.backend.url

  depends_on = [module.backend]
}

output "backend_url" {
  value       = module.backend.url
  description = "Backend Cloud Run service URL."
}

output "frontend_url" {
  value       = module.frontend.url
  description = "Frontend Cloud Run service URL."
}
