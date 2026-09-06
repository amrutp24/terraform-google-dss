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
