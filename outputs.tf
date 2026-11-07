output "instance_name" {
  description = "Compute Engine instance name."
  value       = google_compute_instance.dss.name
}

output "public_ip" {
  description = "External address, when one was assigned."
  value       = try(google_compute_instance.dss.network_interface[0].access_config[0].nat_ip, null)
}

output "private_ip" {
  description = "Address within the network."
  value       = google_compute_instance.dss.network_interface[0].network_ip
}

output "dss_url" {
  description = "Where DSS will answer once it has finished installing. Allow several minutes on first boot: the installer downloads about two gigabytes."
  value = format("http://%s:%d",
    coalesce(
      try(google_compute_instance.dss.network_interface[0].access_config[0].nat_ip, null),
      google_compute_instance.dss.network_interface[0].network_ip,
    ),
  var.dss_port)
}

output "data_dir" {
  description = "DSS data directory on the instance. This is what to back up."
  value       = var.data_dir
}

output "session_command" {
  description = <<-EOT
    How to get a shell on the instance, when enable_iap_ssh is on. Null
    otherwise, which is the signal that nothing can reach the host: neither
    this nor ssh_cidr_blocks was asked for.

    A command rather than a hint, unlike the AWS module's equivalent, because
    everything it needs, the project and the zone, is a variable of this
    module. Running it also needs roles/iap.tunnelResourceAccessor and
    roles/compute.osAdminLogin on whoever runs it.
  EOT
  value = var.enable_iap_ssh ? join(" ", [
    "gcloud compute ssh ${google_compute_instance.dss.name}",
    "--project ${var.project_id}",
    "--zone ${var.zone}",
    "--tunnel-through-iap",
  ]) : null
}

output "service_account_email" {
  description = <<-EOT
    The account the instance runs as. Null means the project's default
    compute account, which is what you get unless you passed
    service_account_email or named a licence secret.

    This is the identity to grant anything else the instance needs. An
    account the module created carries the licence read and nothing more.
  EOT
  value       = local.service_account_email
}

output "api_key_path" {
  description = <<-EOT
    Where the bootstrap wrote the admin API key, which is what the dataiku
    provider needs. Reading it takes a shell on the host, so this is null
    unless enable_iap_ssh is on or you set ssh_cidr_blocks.

    The file is root-owned and mode 0600, so reading it needs sudo.
  EOT
  value       = var.enable_iap_ssh || var.ssh_cidr_blocks != null ? "/var/lib/dataiku-terraform-key.json" : null
}
