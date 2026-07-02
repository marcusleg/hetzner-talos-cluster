# Talos Kubernetes Cluster on Hetzner Cloud

Pure OpenTofu provisioning of a three-node Talos Linux Kubernetes cluster on
Hetzner Cloud. All three nodes are control plane nodes (CX23) and are
schedulable for regular workloads — there are no dedicated workers.

## Architecture

- 3× `cx23` servers in `fsn1` in a spread placement group, running Talos
  (v1.13.5, stock Image Factory image)
- Hetzner Load Balancer (`lb11`) as the highly available Kubernetes API
  endpoint (TCP 6443)
- `cluster.allowSchedulingOnControlPlanes: true` — no control plane taints

Because Hetzner offers no Talos image (and Packer is out of scope), each server
first boots the Hetzner rescue system, where a `remote-exec` provisioner
streams the Talos disk image onto `/dev/sda` and schedules a reboot via
`systemd-run` (an in-session background reboot would be killed on SSH
disconnect). A `local-exec` provisioner then holds the resource until the Talos
machine API answers on port 50000, because the Talos provider fails immediately
on "connection refused". After that, machine configuration, bootstrap, and
kubeconfig retrieval all happen over the Talos API, and
`data.talos_cluster_health` gates the apply on the cluster becoming healthy.

Note: Talos ≥ 1.13 config generation emits a `HostnameConfig` document
(`auto: stable`). Since `auto` and `hostname` are mutually exclusive, the
per-node hostname patch first deletes that document, then adds one with an
explicit hostname.

## Usage

```sh
export HCLOUD_TOKEN=<your token>
tofu init
tofu apply
```

Takes ~10 minutes. Credentials are written to the module directory
(gitignored):

```sh
kubectl --kubeconfig ./kubeconfig get nodes
talosctl --talosconfig ./talosconfig -n <node-ip> health
```

`kubeconfig` points at the load balancer; `talosconfig` points at the node IPs
directly.

## Configuration

See `variables.tf`: `cluster_name`, `location`, `server_type`,
`control_plane_count`, `talos_version`, `talos_schematic_id`.

The OpenTofu state contains cluster secrets — keep it private.

## Teardown

```sh
tofu destroy
```
