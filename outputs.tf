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

output "load_balancer_ip" {
  description = "Public IPv4 of the load balancer (Kubernetes API 6443, Talos API 50000)."
  value       = hcloud_load_balancer.kube_api.ipv4
}

output "control_plane_public_ips" {
  description = "Public IPv4 addresses of the control plane nodes (firewalled: SSH only)."
  value       = hcloud_server.control_plane[*].ipv4_address
}

output "control_plane_private_ips" {
  description = "Private IPv4 addresses of the control plane nodes; use as node addresses with talosctl."
  value       = local.node_private_ips
}

output "kubeconfig" {
  description = "Kubeconfig for the cluster (also written to ./kubeconfig)."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client configuration, routed via the load balancer (also written to ./talosconfig)."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
