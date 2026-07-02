resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/talosconfig"
  file_permission = "0600"
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (load balancer)."
  value       = local.cluster_endpoint
}

output "control_plane_ips" {
  description = "Public IPv4 addresses of the control plane nodes."
  value       = hcloud_server.control_plane[*].ipv4_address
}

output "kubeconfig" {
  description = "Kubeconfig for the cluster (also written to ./kubeconfig)."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client configuration (also written to ./talosconfig)."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
