# Load balancer in front of the control plane nodes: the only public entry
# point to the cluster. Forwards the Kubernetes API (6443) and the Talos API
# (50000, mTLS) to the nodes over the private network.
resource "hcloud_load_balancer" "kube_api" {
  name               = "${var.cluster_name}-kube-api"
  load_balancer_type = "lb11"
  location           = var.location

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_load_balancer_network" "kube_api" {
  load_balancer_id = hcloud_load_balancer.kube_api.id
  subnet_id        = hcloud_network_subnet.nodes.id
  ip               = local.lb_private_ip
}

resource "hcloud_load_balancer_service" "kube_api" {
  load_balancer_id = hcloud_load_balancer.kube_api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 5
    timeout  = 3
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "talos_api" {
  load_balancer_id = hcloud_load_balancer.kube_api.id
  protocol         = "tcp"
  listen_port      = 50000
  destination_port = 50000

  health_check {
    protocol = "tcp"
    port     = 50000
    interval = 5
    timeout  = 3
    retries  = 3
  }
}

resource "hcloud_load_balancer_target" "control_plane" {
  count = var.control_plane_count

  type             = "server"
  load_balancer_id = hcloud_load_balancer.kube_api.id
  server_id        = hcloud_server.control_plane[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.kube_api]
}

locals {
  cluster_endpoint = "https://${hcloud_load_balancer.kube_api.ipv4}:6443"
}
