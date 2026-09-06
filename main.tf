# Stands up a DSS instance on Compute Engine and leaves it ready to configure.
#
# This is layer one only. Configuring what is on the instance is a separate
# apply, because Terraform builds a provider's configuration during planning
# and the dataiku provider needs a reachable instance and an API key before
# that. See README.md.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Resolved rather than pinned: image names carry a build date that changes
# whenever Canonical publishes.
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

module "bootstrap" {
  source = "github.com/amrutp24/terraform-null-dss-bootstrap?ref=v0.1.0"

  dss_version  = var.dss_version
  dss_port     = var.dss_port
  data_dir     = var.data_dir
  license_json = var.license_json
}

# The firewall rule applies to instances carrying this tag rather than to the
# whole network, so it cannot accidentally open a port on something else.
locals {
  network_tag = "${var.name}-dss"
}

resource "google_compute_firewall" "dss" {
  name    = "${var.name}-dss"
  network = var.network

  description = "Dataiku DSS web interface and public API"

  allow {
    protocol = "tcp"
    ports    = [tostring(var.dss_port)]
  }

  # No default on allowed_cidr_blocks, so reaching DSS is always a decision
  # somebody made rather than something that happened.
  source_ranges = var.allowed_cidr_blocks
  target_tags   = [local.network_tag]
}

resource "google_compute_firewall" "ssh" {
  count = var.ssh_cidr_blocks == null ? 0 : 1

  name    = "${var.name}-ssh"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_cidr_blocks
  target_tags   = [local.network_tag]
}

resource "google_compute_instance" "dss" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [local.network_tag]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      # The data directory holds every project and all configuration, so this
      # is what you back up. It lives on the boot disk here for simplicity;
      # see the note in README.md about giving it its own persistent disk.
      size = var.disk_size_gb
      type = "pd-balanced"
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork

    # Without an access config the instance has no public address, which
    # needs a route of your own -- a VPN, or Cloud NAT plus IAP.
    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {}
    }
  }

  metadata_startup_script = module.bootstrap.install_script

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = var.labels

  # DSS keeps everything in the data directory on this disk, so a replacement
  # is a rebuild. Terraform will say so rather than doing it quietly.
  allow_stopping_for_update = true
}
