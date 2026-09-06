# The smallest thing that produces a running DSS.
#
# Configuring what is inside it is a second root configuration; see the module
# README for why that cannot be the same apply.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "dss" {
  source = "../../"

  project_id = var.project_id
  region     = var.region
  zone       = var.zone

  # No default: DSS should not become reachable from the internet by accident.
  allowed_cidr_blocks = var.allowed_cidr_blocks
}

output "dss_url" {
  description = "Where DSS answers once it has finished installing, which takes several minutes on first boot."
  value       = module.dss.dss_url
}
