# Hetzner Talos Kubernetes Cluster — Design

**Date:** 2026-07-02

## Goal

A three-node Kubernetes cluster on Hetzner Cloud running Talos Linux, provisioned
entirely with OpenTofu. All three nodes are control plane nodes of type CX23 and
are schedulable for regular workloads (no dedicated workers).

## Constraints

- Pure OpenTofu: `hetznercloud/hcloud` + `siderolabs/talos` providers (plus
  `hashicorp/tls` and `hashicorp/local` as helpers). No Packer, no shell-outs to
  `hcloud`/`talosctl` CLIs for provisioning.
- Hetzner API token supplied via `HCLOUD_TOKEN` env var.

## Key decision: getting Talos onto Hetzner disks

Hetzner offers no Talos image. The official guide builds a snapshot with Packer,
which the pure-OpenTofu constraint rules out. Approaches considered:

1. **Rescue mode + dd per node (chosen).** Each `hcloud_server` is created with
   `rescue = "linux64"`; a `remote-exec` provisioner streams the Talos Image
   Factory `hcloud-amd64.raw.xz` image onto `/dev/sda` and reboots. The node
   comes up in Talos maintenance mode, ready for machine config. No extra
   resources, no snapshot management. Trade-off: image download happens once per
   node instead of once per cluster, and a node replacement re-runs the dd step —
   acceptable for 3 nodes.
2. Builder server + `hcloud_snapshot`: leaves a permanently billed builder
   server in state, or requires manual cleanup outside OpenTofu. Rejected.
3. Mounting a Talos ISO: Talos is not in Hetzner's public ISO list, and ISO
   boots don't install to disk. Rejected.

## Architecture

- **3× `hcloud_server`** `cx23` (2 vCPU, 4 GB, 40 GB, x86) in `fsn1`, named
  `<cluster>-cp-{1..3}`, in a *spread* placement group (distinct physical hosts).
- **`hcloud_load_balancer`** (lb11) with a TCP 6443 → 6443 service targeting all
  three nodes; the cluster endpoint is `https://<lb-ip>:6443`. Talos includes
  the endpoint host in the API server cert SANs automatically.
- **Talos provisioning flow** (siderolabs/talos provider):
  `talos_machine_secrets` → `data.talos_machine_configuration` (controlplane,
  patched with `cluster.allowSchedulingOnControlPlanes: true`) →
  `talos_machine_configuration_apply` per node (with per-node hostname patch) →
  `talos_machine_bootstrap` on node 1 → `talos_cluster_kubeconfig` →
  `data.talos_cluster_health` gate.
- **Outputs/files:** `kubeconfig` and `talosconfig` written to the module dir
  (mode 0600, gitignored) and exposed as sensitive outputs; node IPs and LB IP
  as plain outputs. `talosconfig` endpoints point at the node IPs directly.
- Talos version v1.13.5, stock Image Factory schematic (no extensions),
  Kubernetes version left to the Talos default for that release.

## Error handling / operational notes

- `talos_machine_configuration_apply` waits (create timeout 10m) for the node to
  reboot from rescue into Talos maintenance mode.
- `data.talos_cluster_health` makes `tofu apply` fail unless etcd, all three
  control plane nodes, and Kubernetes come up healthy; it re-verifies on later
  plans.
- State contains cluster secrets (machine secrets, kubeconfig) — state stays
  local and gitignored.

## Revision 2 (same day): private network, SSH-only firewall

Requirements update: nodes and LB communicate over a private network; nodes
keep dual-stack public IPs (IPv6-only was considered but rejected: ghcr.io,
which hosts Talos system images, has no IPv6); a Hetzner firewall allows
nothing but SSH from the public internet; all other external access goes
through the load balancer.

Key consequences and decisions:

- **Config via user_data instead of Talos API.** The firewall blocks public
  port 50000, so the initial machine config cannot be applied over the
  network. Talos' hcloud platform reads the machine config from Hetzner
  user_data (official guide pattern). This also removes the unauthenticated
  maintenance-mode window entirely — the firewall is attached at creation.
- **Private network** 10.0.0.0/16, subnet 10.0.1.0/24; nodes 10.0.1.11+,
  LB 10.0.1.5. Hetzner metadata only configures the public eth0, so the
  machine config adds `eth1` with DHCP (hcloud serves the assigned private
  IP). `etcd.advertisedSubnets` and `kubelet.nodeIP.validSubnets` pin
  inter-node traffic to the private subnet. LB targets use private IPs.
- **All operator access via the LB**: services 6443 (Kubernetes API) and
  50000 (Talos API, mTLS; LB IPs added to `machine.certSANs`). Talos
  operations set `endpoint = <LB>` and `node = <private IP>`, using apid's
  request routing. Bootstrap waits until the Hetzner API reports all LB
  targets healthy on port 50000.
- **Day-2 config changes** flow through `talos_machine_configuration_apply`
  resources pointed at the LB (initially a no-op — nodes already booted with
  the same config). `user_data` is in `ignore_changes` so config edits do not
  force server replacement.
- Firewalls don't filter private network traffic, so LB→node and node→node
  traffic is unaffected. Port 22 stays open for the rescue-mode provisioning
  path and future recovery; Talos itself has no SSH.

## Testing / verification

- `tofu fmt`, `tofu validate`, `tofu plan` before apply.
- `tofu apply` succeeds only if cluster health passes (see above).
- Post-apply: `talosctl --talosconfig ./talosconfig health`, `kubectl
  --kubeconfig ./kubeconfig get nodes -o wide` shows 3 Ready control plane
  nodes, and a scheduling smoke test confirms workloads land on control planes.
