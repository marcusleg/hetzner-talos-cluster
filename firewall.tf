# Nothing but SSH is reachable on the nodes' public interfaces; all other
# external access goes through the load balancer. Hetzner firewalls do not
# filter private network traffic, so LB->node and node->node communication is
# unaffected. Talos has no SSH — port 22 serves the rescue-mode provisioning
# path and future recovery. Outbound traffic is unrestricted (no outbound
# rules defined).
resource "hcloud_firewall" "nodes" {
  name = "${var.cluster_name}-nodes"

  rule {
    description = "SSH (Hetzner rescue system only; Talos has no SSH)"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  labels = {
    cluster = var.cluster_name
  }
}
