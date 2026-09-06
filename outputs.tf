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
