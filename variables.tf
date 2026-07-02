variable "cluster_name" {
  description = "Name of the cluster; used as prefix for all Hetzner resources."
  type        = string
  default     = "talos"
}

variable "location" {
  description = "Hetzner location for servers and load balancer (cx23 is available in fsn1, nbg1, hel1)."
  type        = string
  default     = "fsn1"
}

variable "network_zone" {
  description = "Hetzner network zone for the private subnet; must contain var.location."
  type        = string
  default     = "eu-central"
}

variable "network_cidr" {
  description = "IP range of the private network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "IP range of the subnet for nodes and load balancer; must be within var.network_cidr."
  type        = string
  default     = "10.0.1.0/24"
}

variable "server_type" {
  description = "Hetzner server type for the control plane nodes."
  type        = string
  default     = "cx23"
}

variable "control_plane_count" {
  description = "Number of control plane nodes."
  type        = number
  default     = 3
}

variable "talos_version" {
  description = "Talos Linux version to install."
  type        = string
  default     = "v1.13.5"
}

variable "talos_schematic_id" {
  description = "Talos Image Factory schematic ID (default: stock image, no extensions)."
  type        = string
  default     = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
}

locals {
  # Talos disk image for the Hetzner Cloud platform, served by the Image Factory.
  talos_image_url = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/hcloud-amd64.raw.xz"
}
