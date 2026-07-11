# Longhorn distributed block storage (V1 data engine), backed by the per-node
# Hetzner volumes mounted at /var/mnt/longhorn (see volumes.tf and the
# UserVolumeConfig patch in talos.tf).

# Longhorn's pods are privileged; helm_release cannot label namespaces, so
# the namespace is managed explicitly.
resource "kubernetes_namespace" "longhorn_system" {
  metadata {
    name = "longhorn-system"

    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }

  # The nodes must be running the config that provisions the data volume
  # before Longhorn starts scanning disks.
  depends_on = [talos_machine_configuration_apply.control_plane]
}

resource "helm_release" "longhorn" {
  name       = "longhorn"
  repository = "https://charts.longhorn.io"
  chart      = "longhorn"
  version    = "1.12.0"
  namespace  = kubernetes_namespace.longhorn_system.metadata[0].name

  values = [
    yamlencode({
      defaultSettings = {
        defaultDataPath = "/var/mnt/longhorn"
      }
    })
  ]

  timeout = 600
}
