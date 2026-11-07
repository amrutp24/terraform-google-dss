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
  source = "amrutp24/dss-bootstrap/null"
  # 0.3 is the real floor now, because license_fetch_command below arrived in
  # 0.3.0. The old "~> 0.1" already resolved to it, since a two-component
  # pessimistic constraint means >= 0.1, < 1.0, but it did not say so.
  version = "~> 0.3"

  dss_version  = var.dss_version
  dss_port     = var.dss_port
  data_dir     = var.data_dir
  license_json = var.license_json

  # Read on the instance, so no licence material reaches Terraform state or
  # instance metadata. Only the project and the secret id travel, and the IAM
  # member below grants the instance that one secret and nothing else.
  #
  # Nothing but python3 and the metadata server, deliberately. The obvious
  # version of this shells out to gcloud, and the sibling AWS module was
  # burned by exactly that assumption: it used the AWS CLI, Ubuntu 24.04 has
  # no awscli package in any component, and the fetch failed in a way that is
  # indistinguishable from success: a healthy instance that is simply
  # unlicensed. gcloud is the same class of bet. It is not a deb in the
  # Ubuntu 24.04 cloud image package manifest at all; where the GCE image
  # carries it, it carries it as a snap, which the bootstrap module already
  # found refuses component installs with "this Google Cloud CLI installation
  # is managed by an external package manager", and which additionally
  # depends on snapd having finished seeding before a startup script runs.
  #
  # So: ask the metadata server for an OAuth token and call the Secret
  # Manager REST API directly. python3 is in the image manifest, urllib and
  # base64 are standard library, and the instance already has the
  # cloud-platform scope, so this depends on nothing that could be absent.
  #
  # One command, not a list: the bootstrap does "if <command> > file 2> log",
  # so a list would redirect only its last part. The project and secret id
  # arrive as argv, which keeps them out of the Python source, so a secret id
  # cannot terminate a string literal. payload.data comes back base64; the
  # two replaces cover Google emitting the URL-safe alphabet.
  license_fetch_command = var.license_secret_id == null ? "" : join(" ", [
    "python3 -c 'import base64,json,sys,urllib.request as u;t=json.load(u.urlopen(u.Request(\"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token\",headers={\"Metadata-Flavor\":\"Google\"}),timeout=10))[\"access_token\"];v=json.load(u.urlopen(u.Request(\"https://secretmanager.googleapis.com/v1/projects/\"+sys.argv[1]+\"/secrets/\"+sys.argv[2]+\"/versions/latest:access\",headers={\"Authorization\":\"Bearer \"+t}),timeout=30));sys.stdout.write(base64.b64decode(v[\"payload\"][\"data\"].replace(\"-\",\"+\").replace(\"_\",\"/\")).decode())'",
    var.project_id,
    var.license_secret_id,
  ])

  containerized_execution = var.containerized_execution
  kubectl_version         = var.kubectl_version
  gcloud_registry_host    = var.gcloud_registry_host
  gke_cluster_name        = var.gke_cluster_name
  gke_cluster_zone        = var.gke_cluster_zone
  build_base_image        = var.build_base_image
}

# The firewall rule applies to instances carrying this tag rather than to the
# whole network, so it cannot accidentally open a port on something else.
locals {
  network_tag = "${var.name}-dss"

  # Published and fixed: every IAP TCP forwarding connection arrives from
  # inside Google's network at one of these addresses, never from the
  # client's own. That is the whole reason this is narrower than an SSH rule
  # of your own, which has to admit wherever you happen to be sitting.
  iap_forwarding_range = "35.235.240.0/20"

  # The instance needs an identity of its own only to read a licence secret.
  # IAP and OS Login need none: they are governed by IAM on the human who
  # connects, not by anything the instance holds. That is the one place this
  # module's two features diverge from the AWS module's, where Session
  # Manager and the licence read share an instance profile.
  #
  # Three cases, and the middle one is the interesting choice:
  #
  #  - service_account_email given: use it, create nothing. The caller owns
  #    the identity and the grant lands on it.
  #  - null and a licence secret named: create a dedicated account. The
  #    alternative is granting secretAccessor to the project's default
  #    compute account, which every other instance in the project also runs
  #    as, so a licence would quietly widen their access too.
  #  - null and no secret named: create nothing, same as before. The instance
  #    runs as the project default, which is what this module has always done.
  create_service_account = var.service_account_email == null && var.license_secret_id != null

  # Null here means "let GCP use the project default", which is what the
  # instance's service_account block takes for that. Not coalesce: with both
  # sides null, which is the default configuration, coalesce is an error
  # rather than null.
  service_account_email = var.service_account_email != null ? var.service_account_email : one(google_service_account.dss[*].email)
}

resource "google_compute_firewall" "iap_ssh" {
  count = var.enable_iap_ssh ? 1 : 0

  name    = "${var.name}-iap-ssh"
  network = var.network

  description = "SSH from IAP TCP forwarding only"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [local.iap_forwarding_range]
  target_tags   = [local.network_tag]
}

resource "google_service_account" "dss" {
  count = local.create_service_account ? 1 : 0

  project      = var.project_id
  account_id   = var.name
  display_name = "Dataiku DSS instance ${var.name}"
  description  = "Identity for the Dataiku DSS instance: reading its licence secret"

  lifecycle {
    # A service account id is stricter than an instance name, and GCP rejects
    # a bad one partway through an apply. Say so at plan time instead.
    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.name))
      error_message = "To let this module create a service account, name must be a valid account id: 6 to 30 characters, lowercase letters, digits and dashes, starting with a letter. Otherwise pass service_account_email and make the account yourself."
    }
  }
}

# Scoped to the one secret named, rather than to the project. A licence is not
# worth broader access than that.
#
# An iam_member and not an iam_binding: a binding is authoritative for the
# role and would delete anyone else who already had secretAccessor on this
# secret, which for a secret shared with other instances is a quiet outage.
resource "google_secret_manager_secret_iam_member" "license" {
  count = var.license_secret_id == null ? 0 : 1

  project   = var.project_id
  secret_id = var.license_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.service_account_email}"
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
    # needs a route of your own: a VPN, or Cloud NAT plus IAP.
    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {}
    }
  }

  metadata_startup_script = module.bootstrap.install_script

  # Empty by default, so nothing about the instance changes unless IAP access
  # was asked for. With OS Login on, who may log in is a project or instance
  # IAM question rather than a question of whose key is in metadata, which is
  # what makes this the counterpart of Session Manager rather than just a
  # different route to the same key pair.
  metadata = var.enable_iap_ssh ? { enable-oslogin = "TRUE" } : {}

  service_account {
    email  = local.service_account_email
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
