# Talos Kubernetes Cluster on Hetzner Cloud

Pure OpenTofu provisioning of a three-node Talos Linux Kubernetes cluster on
Hetzner Cloud. All three nodes are control plane nodes (CX23) and are
schedulable for regular workloads — there are no dedicated workers.

## Architecture

- 3× `cx23` servers in `fsn1` in a spread placement group, running Talos
  (v1.13.5, stock Image Factory image)
- Private network `10.0.0.0/16` (subnet `10.0.1.0/24`): nodes at
  `10.0.1.11-13`, load balancer at `10.0.1.5`. All inter-node traffic (etcd,
  kubelet, pods) and LB→node traffic stays on the private network
  (`etcd.advertisedSubnets`, `kubelet.nodeIP.validSubnets`)
- Hetzner Load Balancer (`lb11`) as the only public entry point:
  - TCP 6443 — Kubernetes API
  - TCP 50000 — Talos API (mTLS; LB IPs in `machine.certSANs`)
- Hetzner Firewall on the nodes: inbound TCP 22 only; the Kubernetes and
  Talos APIs are unreachable on the node public IPs. Port 22 exists for the
  rescue-system provisioning/recovery path — Talos itself has no SSH
- `cluster.allowSchedulingOnControlPlanes: true` — no control plane taints

## Monthly cost

Prices from the Hetzner Cloud pricing API for `fsn1` as of July 2026, in EUR:

| Item                              | Qty | Net €/mo each | Net €/mo  |
| --------------------------------- | --- | ------------- | --------- |
| `cx23` server                     | 3   | 5.49          | 16.47     |
| Primary IPv4                      | 3   | 0.50          | 1.50      |
| Load balancer `lb11`              | 1   | 7.49          | 7.49      |
| Private network, subnet, firewall, placement group, primary IPv6 | — | free | 0.00 |
| **Total**                         |     |               | **25.46** |

That is **€25.46/month net** (≈ €30.30 gross at 19 % VAT). Billing is
per-hour, capped at the monthly price. Each server and the load balancer
include 20 TB of outbound traffic (additional traffic €1.00/TB net); inbound
and private network traffic are free.

## How provisioning works

Hetzner offers no Talos image (and Packer is out of scope), so each server
first boots the Hetzner rescue system, where a `remote-exec` provisioner
streams the Talos disk image onto `/dev/sda` and schedules a reboot via
`systemd-run` (an in-session background reboot would be killed on SSH
disconnect). The machine configuration is passed as Hetzner `user_data`:
Talos' hcloud platform reads it from the metadata service on first boot, so
the nodes configure themselves and join the cluster without any inbound
network access — the firewall is active from the moment of creation and there
is no unauthenticated maintenance-mode window.

OpenTofu then waits until the Hetzner API reports all load balancer targets
healthy on port 50000, bootstraps etcd through the LB (apid routes requests to
the node given by its private IP), fetches the kubeconfig, and gates the apply
on `data.talos_cluster_health`.

Notes:

- Hetzner metadata only configures the public `eth0`; the machine config adds
  `eth1` (private) with DHCP — hcloud serves the IP assigned in OpenTofu.
- Talos ≥ 1.13 config generation emits a `HostnameConfig` document
  (`auto: stable`); `auto` and `hostname` are mutually exclusive, so the
  per-node hostname patch deletes that document and adds an explicit one.
- Day-2 config changes flow through `talos_machine_configuration_apply` via
  the load balancer. `user_data` is in `ignore_changes`, so config edits do
  not replace servers; only genuinely new servers boot with the then-current
  config.

## Usage

Requires `tofu`, `bash`, `curl`, and `jq` (the LB health wait shells out to
the Hetzner API).

```sh
export HCLOUD_TOKEN=<your token>
tofu init
tofu apply
```

Takes ~10 minutes. Credentials are written to the module directory
(gitignored):

```sh
kubectl --kubeconfig ./kubeconfig get nodes
talosctl --talosconfig ./talosconfig -n 10.0.1.11 health
```

Both `kubeconfig` and `talosconfig` point at the load balancer; with
`talosctl`, address nodes by their private IPs (`-n 10.0.1.11` etc.) — apid on
any node proxies the request over the private network.

## Configuration

See `variables.tf`: `cluster_name`, `location`, `network_zone`,
`network_cidr`, `subnet_cidr`, `server_type`, `control_plane_count`,
`talos_version`, `talos_schematic_id`.

The OpenTofu state contains cluster secrets — keep it private.

## Teardown

```sh
tofu destroy
```
