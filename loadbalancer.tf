# Load balancer in front of the Kubernetes API on all control plane nodes.
# Its IP is the stable cluster endpoint.
resource "hcloud_load_balancer" "kube_api" {
  name               = "${var.cluster_name}-kube-api"
  load_balancer_type = "lb11"
  location           = var.location

  labels = {
    cluster = var.cluster_name
  }
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

resource "hcloud_load_balancer_target" "control_plane" {
  count = var.control_plane_count

  type             = "server"
  load_balancer_id = hcloud_load_balancer.kube_api.id
  server_id        = hcloud_server.control_plane[count.index].id
}

locals {
  cluster_endpoint = "https://${hcloud_load_balancer.kube_api.ipv4}:6443"
}
