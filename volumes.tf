# One dedicated block storage volume per node for Longhorn replicas. Talos
# provisions and mounts it via the UserVolumeConfig patch (talos.tf); Hetzner
# must not create a filesystem (automount = false, no format).
resource "hcloud_volume" "longhorn" {
  count = var.control_plane_count

  name     = "${var.cluster_name}-longhorn-${count.index + 1}"
  size     = var.longhorn_volume_size
  location = var.location

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_volume_attachment" "longhorn" {
  count = var.control_plane_count

  volume_id = hcloud_volume.longhorn[count.index].id
  server_id = hcloud_server.control_plane[count.index].id
  automount = false
}
