resource "hcloud_network" "private" {
  name     = var.cluster_name
  ip_range = var.network_cidr

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.private.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_cidr
}

locals {
  # .1 is the hcloud network gateway; keep low addresses for infrastructure.
  lb_private_ip       = cidrhost(var.subnet_cidr, 5)
  node_private_ips    = [for i in range(var.control_plane_count) : cidrhost(var.subnet_cidr, 11 + i)]
  control_plane_names = [for i in range(var.control_plane_count) : "${var.cluster_name}-cp-${i + 1}"]
}
