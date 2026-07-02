resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "control_plane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    yamlencode({
      cluster = {
        # No dedicated workers: control plane nodes run regular workloads.
        allowSchedulingOnControlPlanes = true
      }
      machine = {
        install = {
          disk = "/dev/sda"
        }
      }
    }),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = hcloud_server.control_plane[*].ipv4_address
}

resource "talos_machine_configuration_apply" "control_plane" {
  count = var.control_plane_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  node                        = hcloud_server.control_plane[count.index].ipv4_address

  # The generated config already contains a HostnameConfig document
  # (auto: stable); 'auto' and 'hostname' are mutually exclusive, so the
  # document must be deleted before adding one with an explicit hostname.
  config_patches = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      "$patch"   = "delete"
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = hcloud_server.control_plane[count.index].name
    }),
  ]

  timeouts = {
    create = "10m"
  }
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = hcloud_server.control_plane[0].ipv4_address

  depends_on = [talos_machine_configuration_apply.control_plane]

  timeouts = {
    create = "10m"
  }
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = hcloud_server.control_plane[0].ipv4_address

  depends_on = [talos_machine_bootstrap.this]
}

# Gates `tofu apply` on the cluster actually becoming healthy
# (etcd quorum, all nodes up, Kubernetes API reachable).
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = hcloud_server.control_plane[*].ipv4_address
  endpoints            = hcloud_server.control_plane[*].ipv4_address

  depends_on = [
    talos_machine_bootstrap.this,
    hcloud_load_balancer_service.kube_api,
    hcloud_load_balancer_target.control_plane,
  ]

  timeouts = {
    read = "15m"
  }
}
