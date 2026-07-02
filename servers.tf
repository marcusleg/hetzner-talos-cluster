# SSH key used only for the Hetzner rescue system while writing the Talos image.
# Talos itself has no SSH access.
resource "tls_private_key" "rescue" {
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "rescue" {
  name       = "${var.cluster_name}-rescue"
  public_key = tls_private_key.rescue.public_key_openssh
}

# Spread the control plane nodes over distinct physical hosts.
resource "hcloud_placement_group" "control_plane" {
  name = "${var.cluster_name}-control-plane"
  type = "spread"
}

# Each node boots into the Hetzner rescue system first; the provisioner streams
# the Talos hcloud disk image onto /dev/sda and reboots. Talos then reads its
# machine configuration from user_data via the Hetzner metadata service and
# joins the cluster on its own — the firewall (SSH only) is active from
# creation, and the Talos/Kubernetes APIs are only reachable through the load
# balancer.
resource "hcloud_server" "control_plane" {
  count = var.control_plane_count

  name               = local.control_plane_names[count.index]
  server_type        = var.server_type
  location           = var.location
  placement_group_id = hcloud_placement_group.control_plane.id
  firewall_ids       = [hcloud_firewall.nodes.id]

  # Never boots: the rescue system overwrites the disk with Talos.
  image  = "debian-12"
  rescue = "linux64"

  ssh_keys  = [hcloud_ssh_key.rescue.id]
  user_data = data.talos_machine_configuration.control_plane[count.index].machine_configuration

  network {
    network_id = hcloud_network.private.id
    ip         = local.node_private_ips[count.index]
  }

  labels = {
    cluster = var.cluster_name
    role    = "controlplane"
  }

  connection {
    type        = "ssh"
    host        = self.ipv4_address
    user        = "root"
    private_key = tls_private_key.rescue.private_key_openssh
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "echo 'Writing Talos ${var.talos_version} image to /dev/sda ...'",
      "wget -q -O- '${local.talos_image_url}' | xz -dc | dd of=/dev/sda bs=4M conv=fsync status=none",
      "sync",
      "echo 'Done, rebooting into Talos'",
      # Detached via PID 1: an in-session background reboot does not survive
      # the SSH session teardown when the provisioner disconnects.
      "systemd-run --on-active=2 systemctl reboot",
    ]
  }

  lifecycle {
    # rescue/image only matter for the very first boot; user_data carries the
    # initial machine config — later config changes are applied via the Talos
    # API (talos_machine_configuration_apply) and must not replace the server.
    ignore_changes = [rescue, image, ssh_keys, user_data]
  }

  depends_on = [hcloud_network_subnet.nodes]
}
