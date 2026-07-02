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
# the Talos hcloud disk image onto /dev/sda and reboots into Talos maintenance
# mode, where the machine configuration is then applied over the Talos API.
resource "hcloud_server" "control_plane" {
  count = var.control_plane_count

  name               = "${var.cluster_name}-cp-${count.index + 1}"
  server_type        = var.server_type
  location           = var.location
  placement_group_id = hcloud_placement_group.control_plane.id

  # Never boots: the rescue system overwrites the disk with Talos.
  image  = "debian-12"
  rescue = "linux64"

  ssh_keys = [hcloud_ssh_key.rescue.id]

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
      "echo 'Done, rebooting into Talos maintenance mode'",
      # Detached via PID 1: an in-session background reboot does not survive
      # the SSH session teardown when the provisioner disconnects.
      "systemd-run --on-active=2 systemctl reboot",
    ]
  }

  # The Talos provider fails immediately on "connection refused", so hold the
  # resource until the node has rebooted into Talos and the machine API is up.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "timeout 300 bash -c 'until (exec 3<>/dev/tcp/${self.ipv4_address}/50000) 2>/dev/null; do sleep 5; done'"
  }

  lifecycle {
    # The rescue flag is only relevant for the very first boot.
    ignore_changes = [rescue, image, ssh_keys]
  }
}
