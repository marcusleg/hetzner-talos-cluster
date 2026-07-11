resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# One configuration per node (they differ only in hostname). Delivered to the
# node via Hetzner user_data on first boot; the firewall blocks the Talos API
# on the public interfaces, so there is no network path (and no need) to apply
# the initial config over the wire.
data "talos_machine_configuration" "control_plane" {
  count = var.control_plane_count

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
        apiServer = {
          certSANs = [
            hcloud_load_balancer.kube_api.ipv4,
            hcloud_load_balancer.kube_api.ipv6,
          ]
        }
        etcd = {
          # Peer over the private network.
          advertisedSubnets = [var.subnet_cidr]
        }
      }
      machine = {
        install = {
          disk = "/dev/sda"
        }
        # Talos API access goes through the load balancer.
        certSANs = [
          hcloud_load_balancer.kube_api.ipv4,
          hcloud_load_balancer.kube_api.ipv6,
        ]
        kubelet = {
          nodeIP = {
            validSubnets = [var.subnet_cidr]
          }
        }
        network = {
          # Hetzner metadata only covers the public eth0; the private
          # interface gets its assigned IP via hcloud DHCP.
          interfaces = [
            {
              interface = "eth1"
              dhcp      = true
            },
          ]
        }
      }
    }),
    # The generated config contains a HostnameConfig document (auto: stable);
    # 'auto' and 'hostname' are mutually exclusive, so replace the document.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      "$patch"   = "delete"
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = local.control_plane_names[count.index]
    }),
    # Provision the attached Hetzner volume for Longhorn. Hetzner block
    # storage volumes attach as SCSI disks with model "Volume"; Talos
    # partitions and formats (xfs) the disk and mounts it, as user volume
    # "longhorn", at /var/mnt/longhorn.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "longhorn"
      provisioning = {
        diskSelector = {
          match = "disk.model == 'Volume' && !system_disk"
        }
        # Talos requires an explicit size bound; grow to fill the disk so the
        # volume tracks longhorn_volume_size.
        minSize = "1GiB"
        grow    = true
      }
    }),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [hcloud_load_balancer.kube_api.ipv4]
  nodes                = local.node_private_ips
}

# The nodes come up on their own after booting the config from user_data;
# bootstrap must wait until the Talos API is reachable through the load
# balancer. Polls the Hetzner API until all targets are healthy on port 50000.
resource "terraform_data" "wait_for_talos_api" {
  input = hcloud_server.control_plane[*].id

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      timeout 600 bash -c '
        while true; do
          healthy=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
            "https://api.hetzner.cloud/v1/load_balancers/${hcloud_load_balancer.kube_api.id}" \
            | jq "[.load_balancer.targets[].health_status[] | select(.listen_port == 50000 and .status == \"healthy\")] | length")
          [ "$healthy" = "${var.control_plane_count}" ] && exit 0
          sleep 10
        done'
    EOT
  }

  depends_on = [
    hcloud_load_balancer_service.talos_api,
    hcloud_load_balancer_target.control_plane,
  ]
}

# All Talos API operations connect to the load balancer; apid routes the
# request to the node given by its private IP.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = hcloud_load_balancer.kube_api.ipv4
  node                 = local.node_private_ips[0]

  depends_on = [terraform_data.wait_for_talos_api]

  timeouts = {
    create = "10m"
  }
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoint             = hcloud_load_balancer.kube_api.ipv4
  node                 = local.node_private_ips[0]

  depends_on = [talos_machine_bootstrap.this]
}

# Gates `tofu apply` on the cluster actually becoming healthy
# (etcd quorum, all nodes up, Kubernetes API reachable).
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = local.node_private_ips
  endpoints            = [hcloud_load_balancer.kube_api.ipv4]

  depends_on = [talos_machine_bootstrap.this]

  timeouts = {
    read = "15m"
  }
}

# Day-2 configuration channel: the nodes already booted with this exact config
# from user_data (initially a no-op); later changes to the config patches are
# applied through the load balancer. Sequenced after the health gate so the
# apid request routing is fully available.
resource "talos_machine_configuration_apply" "control_plane" {
  count = var.control_plane_count

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane[count.index].machine_configuration
  endpoint                    = hcloud_load_balancer.kube_api.ipv4
  node                        = local.node_private_ips[count.index]

  depends_on = [data.talos_cluster_health.this]

  timeouts = {
    create = "10m"
  }
}
