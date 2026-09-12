variable "project_id" {
  description = "GCP project to create everything in."
  type        = string
}

variable "name" {
  description = "Name applied to the instance and its firewall rules."
  type        = string
  default     = "dataiku-dss"
}

variable "region" {
  description = "GCP region."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zone within the region."
  type        = string
  default     = "europe-west1-b"
}

variable "machine_type" {
  description = <<-EOT
    Machine type. DSS drops into a low-memory mode below roughly 16 GB and says
    so in its logs, so n2-standard-4 is about the smallest that behaves
    normally.
  EOT
  type        = string
  default     = "n2-standard-4"
}

variable "allowed_cidr_blocks" {
  description = <<-EOT
    Who may reach the DSS port. Deliberately has no default: DSS holds your
    data and its login page would otherwise be open to the internet.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidr_blocks) > 0
    error_message = "Name at least one CIDR block that should reach DSS."
  }

  validation {
    condition     = !contains(var.allowed_cidr_blocks, "0.0.0.0/0")
    error_message = "0.0.0.0/0 exposes DSS to the whole internet. Use your own range, or edit this validation if you genuinely mean it."
  }
}

variable "ssh_cidr_blocks" {
  description = "Who may reach SSH. Null creates no SSH rule at all, which is right if you use IAP."
  type        = list(string)
  default     = null
}

variable "network" {
  description = "Network to attach to."
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "Subnetwork to attach to. Null lets GCP pick the one for the region, which is fine for a trial and not for production."
  type        = string
  default     = null
}

variable "assign_public_ip" {
  description = "Give the instance an external address. False needs a route of your own."
  type        = bool
  default     = true
}

variable "disk_size_gb" {
  description = "Boot disk size. DSS itself is about 10 GB unpacked; the rest is your projects and code environments."
  type        = number
  default     = 100
}

variable "service_account_email" {
  description = "Service account for the instance. Null uses the project's default compute account, which is broader than it should be for anything lasting."
  type        = string
  default     = null
}

variable "dss_version" {
  description = "DSS version to install."
  type        = string
  default     = "15.0.0"
}

variable "dss_port" {
  description = "Port DSS listens on."
  type        = number
  default     = 10000
}

variable "data_dir" {
  description = "DSS data directory on the instance."
  type        = string
  default     = "/data/dataiku/dss_data"
}

variable "license_json" {
  description = "Contents of a DSS licence file, applied at install time. Reaches instance metadata and Terraform state, so pass it from a secret store."
  type        = string
  default     = ""
  sensitive   = true
}

variable "labels" {
  description = "Labels applied to the instance."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Containerized execution ("Elastic AI")
#
# Passed straight through to the bootstrap module, which does the work. They
# live here because that module is called from inside this one, so without a
# passthrough there is no way for a caller to reach them.
#
# All default to off, so an existing configuration is unaffected.
# ---------------------------------------------------------------------------

variable "containerized_execution" {
  description = <<-EOT
    Install a Docker daemon and kubectl on the instance and put the DSS service
    user in the docker group, so DSS can build and run container images. On its
    own this prepares the host; it configures nothing inside DSS, which is the
    dataiku provider's job.
  EOT
  type        = bool
  default     = false
}

variable "kubectl_version" {
  description = "Pin kubectl, for example v1.31.0. Empty resolves the current stable release. kubectl tolerates one minor version of skew from the control plane, so pin this against your cluster."
  type        = string
  default     = ""
}

variable "gcloud_registry_host" {
  description = "Artifact Registry host to configure Docker credentials for, for example us-central1-docker.pkg.dev. Installs the gcloud CLI if the image does not carry it."
  type        = string
  default     = ""
}

variable "gke_cluster_name" {
  description = "GKE cluster to fetch credentials for at boot. Must be set together with gke_cluster_zone."
  type        = string
  default     = ""
}

variable "gke_cluster_zone" {
  description = "Zone or region of the GKE cluster. Must be set together with gke_cluster_name."
  type        = string
  default     = ""
}

variable "build_base_image" {
  description = <<-EOT
    Build the DSS container-exec base image at the end of the install. Slow: it
    pulls a base OS image, layers the DSS code environment on top and pushes the
    result. Requires containerized_execution, since the build needs the Docker
    socket. Dataiku requires this image to be rebuilt after every DSS upgrade.
  EOT
  type        = bool
  default     = false
}
