# Longhorn Storage (V1 Data Engine) — Design

**Date:** 2026-07-11

## Goal

Replicated persistent storage for the cluster via Longhorn, backed by one
dedicated 10 GB Hetzner Cloud volume attached to each node. A `tofu apply`
from scratch yields a working `longhorn` StorageClass; PVCs bind and are not
tied to specific nodes (Longhorn replicates volume data across nodes and
attaches volumes over the network).

Reference: Sidero's Longhorn guide
(https://docs.siderolabs.com/kubernetes-guides/csi/longhorn), V1 Data Engine
section.

## Key decisions

- **V1 Data Engine, not V2.** V2 requires `vm.nr_hugepages = 1024` — a
  permanent 2 GiB RAM reservation per node. The cx23 nodes have 4 GB and also
  run etcd, the control plane, and workloads; halving usable RAM is not
  acceptable. V1 (iSCSI-based, mature) has no such requirement. Revisit V2 if
  the nodes are ever upgraded to ≥ 8 GB types.
- **Dedicated Hetzner volumes, not root-disk space.** Carving Longhorn space
  out of the system disk (capped EPHEMERAL + user volume) is possible but was
  rejected: Longhorn replica I/O would share the disk with latency-sensitive
  etcd, the EPHEMERAL/user-volume split is frozen at install time, and
  Hetzner volumes can be resized independently later. Cost is ~€0.53/mo per
  volume.
- **OpenTofu installs Longhorn itself** (helm + kubernetes providers wired to
  the generated kubeconfig), not just the infrastructure. Keeps the
  single-`tofu apply` property and lays the provider groundwork for other
  WISHLIST items (Cilium, Hetzner CCM).

## Architecture

### 1. Block storage — new `volumes.tf`

- `hcloud_volume` × `control_plane_count`, 10 GB each (new variable
  `longhorn_volume_size` in `variables.tf`, default 10, minimum 10 — the
  Hetzner minimum volume size), named `<cluster>-longhorn-<n>`,
  location `var.location`, labeled like the servers.
- `hcloud_volume_attachment` per node, `automount = false` (Talos owns the
  disk; no filesystem is created by Hetzner).
- Volumes are plain cluster resources: `tofu destroy` deletes them and their
  data.

### 2. Talos image — schematic with extensions

Longhorn V1 needs `iscsid`/`iscsiadm` and `fstrim` on the host. The default
`talos_schematic_id` changes from the stock image to
`613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`, which
bundles exactly `siderolabs/iscsi-tools` + `siderolabs/util-linux-tools`
(verified against the Image Factory API; the hcloud-amd64 image for v1.13.5
exists). The cluster is currently destroyed, so the new image applies on
first boot — no in-place Talos upgrade orchestration is needed.

### 3. Machine config — `UserVolumeConfig` patch in `talos.tf`

New config patch document appended to the existing `config_patches`:

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: disk.model == "Volume" && !system_disk
  minSize: 1GiB
  grow: true
```

Hetzner Cloud volumes attach as SCSI disks with model `Volume` (the guide's
`disk.transport == 'nvme'` example does not apply to Hetzner). The selector
is verified post-deploy with `talosctl get disks`. Talos partitions and
formats the disk (xfs) and mounts it at `/var/mnt/longhorn`. Talos requires
an explicit size bound (`minSize` or `maxSize`); the volume sets
`minSize: 1GiB` with `grow: true`, taking the whole disk regardless of
`longhorn_volume_size`.

### 4. Longhorn install — new `longhorn.tf`, providers in `versions.tf`

- `kubernetes` and `helm` providers configured from
  `talos_cluster_kubeconfig.this` (host + client cert/key + CA); the
  Kubernetes API is reachable through the load balancer.
- `kubernetes_namespace` `longhorn-system` with label
  `pod-security.kubernetes.io/enforce: privileged` (Longhorn's pods are
  privileged; helm's `create_namespace` cannot set labels).
- `helm_release` `longhorn`, chart `longhorn` from
  `https://charts.longhorn.io`, namespace `longhorn-system`, pinned chart
  version, with:
  - `defaultSettings.defaultDataPath = /var/mnt/longhorn`
- Sequenced `depends_on = [talos_machine_configuration_apply.control_plane]`
  (itself gated on cluster health), so Longhorn installs only after the
  nodes run the config that provisions the data volume.

Open implementation check: whether current Longhorn on Talos still needs a
kubelet `extraMounts` bind for the data path. The current Sidero guide
relies solely on `UserVolumeConfig` + `defaultDataPath`; older guides
bind-mounted `/var/lib/longhorn`. Follow the current guide; if node disks
fail to register during verification, add the documented mount.

## Error handling / operational notes

- Volume attachments happen at server create time; during the rescue-mode
  imaging step the extra disk is visible as `/dev/sdb`, but the dd targets
  `/dev/sda` explicitly, so imaging is unaffected. Talos provisions the user
  volume whenever the disk is present.
- Destroy ordering: `helm_release` and the namespace depend (transitively)
  on the servers, so they are destroyed first; if the cluster is already
  unreachable, `tofu destroy` may need `-refresh=false` — same caveat that
  already applies to the kubeconfig resources.
- The helm release pins a chart version so `tofu apply` stays reproducible;
  Longhorn upgrades are explicit version bumps.

## Testing / verification

- `tofu fmt`, `tofu validate`, `tofu plan`, then full `tofu apply` from
  scratch.
- `talosctl get disks` shows the 10 GB `Volume` disk; `talosctl get
  volumestatus` (or `get volumes`) shows user volume `longhorn` mounted at
  `/var/mnt/longhorn` on every node.
- `kubectl -n longhorn-system get nodes.longhorn.io` lists all 3 nodes as
  ready/schedulable.
- The guide's smoke test: a 1 Gi PVC with `storageClassName: longhorn`
  reaches `Bound`; a pod using it can write data.
- README: new storage section + cost table row (3× 10 GB volume, prices from
  the Hetzner pricing API); WISHLIST: mark Longhorn done.
