# Longhorn Storage (V1 Data Engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replicated persistent storage via Longhorn (V1 data engine), backed by one dedicated 10 GB Hetzner volume per node, fully provisioned by `tofu apply`.

**Architecture:** One `hcloud_volume` + attachment per control plane node; a Talos `UserVolumeConfig` patch provisions/mounts each at `/var/mnt/longhorn`; the Talos image switches to a schematic bundling `iscsi-tools` + `util-linux-tools`; new `kubernetes`/`helm` providers (fed by `talos_cluster_kubeconfig`) create the privileged `longhorn-system` namespace and install the pinned Longhorn chart.

**Tech Stack:** OpenTofu, hcloud provider ~> 1.52, siderolabs/talos provider ~> 0.9, hashicorp/kubernetes ~> 2.38, hashicorp/helm ~> 3.0, Longhorn chart 1.12.0, Talos v1.13.5.

**Spec:** `docs/superpowers/specs/2026-07-11-longhorn-storage-design.md`

## Global Constraints

- The cluster is currently **destroyed** (empty state); everything is designed for a fresh `tofu apply`. Do not add upgrade/migration logic.
- Longhorn chart version pinned to `1.12.0`; Talos stays `v1.13.5`.
- New schematic ID (exactly `siderolabs/iscsi-tools` + `siderolabs/util-linux-tools`, verified against the Image Factory): `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`.
- `longhorn_volume_size` variable: default 10, validation `>= 10` (Hetzner minimum).
- Longhorn data path: `/var/mnt/longhorn` (Talos user volume mount point for a volume named `longhorn`).
- Every code task ends with `tofu fmt` + `tofu validate` passing and a commit. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Working directory: `/home/marcus/Documents/Programming/iac/hetzner-talos-cluster`. `HCLOUD_TOKEN` must be exported for plan/apply (ask the user if missing; never print it).

---

### Task 1: Hetzner volumes + size variable

**Files:**
- Modify: `variables.tf` (append variable)
- Create: `volumes.tf`

**Interfaces:**
- Consumes: `hcloud_server.control_plane` (`servers.tf`), `var.control_plane_count`, `var.cluster_name`, `var.location`.
- Produces: `hcloud_volume.longhorn[*]`, `hcloud_volume_attachment.longhorn[*]` — Task 2's `UserVolumeConfig` matches these disks by model `Volume`; no other task references them by name.

- [ ] **Step 1: Add the `longhorn_volume_size` variable**

Append to `variables.tf` (before the `locals` block at the bottom, keeping variables together):

```hcl
variable "longhorn_volume_size" {
  description = "Size in GB of the block storage volume attached to each node for Longhorn."
  type        = number
  default     = 10

  validation {
    condition     = var.longhorn_volume_size >= 10
    error_message = "longhorn_volume_size must be at least 10 GB (Hetzner Cloud minimum volume size)."
  }
}
```

- [ ] **Step 2: Create `volumes.tf`**

```hcl
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
```

- [ ] **Step 3: Validate**

Run: `tofu fmt -check volumes.tf variables.tf && tofu validate`
Expected: no fmt diff, `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add variables.tf volumes.tf
git commit -m "Attach a 10 GB Longhorn volume to each node

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Talos image extensions + UserVolumeConfig patch

**Files:**
- Modify: `variables.tf` (the `talos_schematic_id` variable, currently lines 54–58)
- Modify: `talos.tf` (the `config_patches` list in `data.talos_machine_configuration.control_plane`, currently ends at line 72)

**Interfaces:**
- Consumes: nothing new.
- Produces: user volume named `longhorn` mounted at `/var/mnt/longhorn` on every node — Task 3's Helm value `defaultSettings.defaultDataPath` points there.

- [ ] **Step 1: Switch the default schematic to the extensions image**

In `variables.tf`, replace:

```hcl
variable "talos_schematic_id" {
  description = "Talos Image Factory schematic ID (default: stock image, no extensions)."
  type        = string
  default     = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
}
```

with:

```hcl
variable "talos_schematic_id" {
  description = "Talos Image Factory schematic ID (default: siderolabs/iscsi-tools + siderolabs/util-linux-tools, required by Longhorn)."
  type        = string
  default     = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"
}
```

- [ ] **Step 2: Append the UserVolumeConfig patch document**

In `talos.tf`, inside `config_patches`, after the `HostnameConfig` patch (the list element ending with `hostname = local.control_plane_names[count.index]`), append:

```hcl
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
      }
    }),
```

- [ ] **Step 3: Validate**

Run: `tofu fmt -check variables.tf talos.tf && tofu validate`
Expected: no fmt diff, `Success! The configuration is valid.`

- [ ] **Step 4: Verify the schematic image exists (belt and braces)**

Run: `curl -sI "https://factory.talos.dev/image/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245/v1.13.5/hcloud-amd64.raw.xz" | head -1`
Expected: `HTTP/2 200`

- [ ] **Step 5: Commit**

```bash
git add variables.tf talos.tf
git commit -m "Provision the Longhorn volume via Talos with required extensions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: kubernetes/helm providers + Longhorn install

**Files:**
- Modify: `versions.tf` (add two `required_providers` entries and two provider blocks)
- Create: `longhorn.tf`

**Interfaces:**
- Consumes: `talos_cluster_kubeconfig.this.kubernetes_client_configuration` (attributes: `host`, `client_certificate`, `client_key`, `ca_certificate` — all base64-encoded except `host`), `talos_machine_configuration_apply.control_plane` (talos.tf).
- Produces: namespace `longhorn-system`, Helm release `longhorn`, StorageClass `longhorn` (created by the chart) — used only by Task 4's verification.

- [ ] **Step 1: Add providers to `versions.tf`**

Inside `required_providers`, after the `local` entry, add:

```hcl
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
```

At the bottom of `versions.tf`, after the `provider "hcloud"` block, add:

```hcl
# Kubernetes access for in-cluster addons, via the load balancer endpoint
# from the generated kubeconfig.
provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}
```

Note: helm provider 3.x uses `kubernetes = { ... }` (attribute syntax with `=`), not the 2.x nested block syntax.

- [ ] **Step 2: Create `longhorn.tf`**

```hcl
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
```

- [ ] **Step 3: Init and validate**

Run: `tofu init && tofu fmt -check versions.tf longhorn.tf && tofu validate`
Expected: both new providers install, no fmt diff, `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add versions.tf longhorn.tf .terraform.lock.hcl
git commit -m "Install Longhorn via Helm

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Deploy and verify end-to-end

**Files:**
- No code changes (deployment + verification only). Scratch manifests go in the session scratchpad, not the repo.

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: a running cluster with a `Bound`-capable `longhorn` StorageClass; evidence for the README claims in Task 5.

- [ ] **Step 1: Plan**

Requires `HCLOUD_TOKEN` in the environment (ask the user if missing).

Run: `tofu plan -out tfplan`
Expected: creates ~3 servers, 3 volumes, 3 attachments, LB + network + firewall resources, namespace, helm release; no destroys/replacements beyond a fresh create; exit code 0.

- [ ] **Step 2: Apply**

Run: `tofu apply tfplan`
Expected: completes in ~10–15 min. `data.talos_cluster_health` gates success; `helm_release.longhorn` finishes deployed. If `helm_release` times out, do NOT immediately retry — inspect with `kubectl --kubeconfig ./kubeconfig -n longhorn-system get pods` first.

- [ ] **Step 3: Verify the Talos user volume on every node**

```bash
for n in 10.0.1.11 10.0.1.12 10.0.1.13; do
  talosctl --talosconfig ./talosconfig -n $n get disks
  talosctl --talosconfig ./talosconfig -n $n get volumestatus | grep -i longhorn
done
```

Expected: each node shows a 10 GB disk with model `Volume` plus the system disk; a volume `u-longhorn` (user volumes are prefixed `u-`) in phase `ready`, mounted at `/var/mnt/longhorn`. If the disk selector matched nothing, `volumestatus` shows the volume waiting for a disk — revisit the CEL expression in `talos.tf` against the actual `get disks` output (fields: model, transport, size) before any other debugging.

- [ ] **Step 4: Verify Longhorn sees the nodes**

Run: `kubectl --kubeconfig ./kubeconfig -n longhorn-system get nodes.longhorn.io`
Expected: 3 nodes, `READY True`, `ALLOWSCHEDULING true`. Also check `kubectl --kubeconfig ./kubeconfig get storageclass` lists `longhorn (default)`.

If nodes show no schedulable disks: check `kubectl -n longhorn-system describe nodes.longhorn.io <node>` conditions — this is the point where the older guides needed a kubelet `extraMounts` bind for the data path. Only if the condition explicitly complains about the disk path being invalid/inaccessible, add to the `machine` section of the main config patch in `talos.tf`:

```hcl
        kubelet = {
          nodeIP = {
            validSubnets = [var.subnet_cidr]
          }
          extraMounts = [
            {
              destination = "/var/mnt/longhorn"
              type        = "bind"
              source      = "/var/mnt/longhorn"
              options     = ["bind", "rshared", "rw"]
            }
          ]
        }
```

(replacing the existing `kubelet` block), then `tofu apply` again and re-verify.

- [ ] **Step 5: PVC smoke test**

Write to the scratchpad (not the repo) `longhorn-test.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-test-pod
spec:
  containers:
    - name: test
      image: busybox
      command: ["sh", "-c", "echo longhorn-ok > /data/probe && cat /data/probe && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: longhorn-test-pvc
```

```bash
kubectl --kubeconfig ./kubeconfig apply -f <scratchpad>/longhorn-test.yaml
kubectl --kubeconfig ./kubeconfig wait --for=jsonpath='{.status.phase}'=Bound pvc/longhorn-test-pvc --timeout=120s
kubectl --kubeconfig ./kubeconfig wait --for=condition=Ready pod/longhorn-test-pod --timeout=180s
kubectl --kubeconfig ./kubeconfig logs longhorn-test-pod
kubectl --kubeconfig ./kubeconfig delete -f <scratchpad>/longhorn-test.yaml
```

Expected: PVC `Bound`, pod logs print `longhorn-ok`, cleanup succeeds.

- [ ] **Step 6: Commit (only if Step 4 required the extraMounts fix)**

```bash
git add talos.tf
git commit -m "Bind-mount the Longhorn data path into kubelet

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

If no fix was needed, there is nothing to commit in this task.

---

### Task 5: Documentation (README, WISHLIST)

**Files:**
- Modify: `README.md` (Architecture list, cost table, Configuration variable list)
- Modify: `WISHLIST.md` (first line)

**Interfaces:**
- Consumes: verified behavior from Task 4; volume pricing from the Hetzner API.

- [ ] **Step 1: Get the real volume price**

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/pricing | jq '.pricing.volume'
```

Expected: net EUR per GB/month (~0.05). Multiply by `10 × 3` for the table.

- [ ] **Step 2: Update `README.md`**

- Architecture bullet list: update the first bullet's "stock Image Factory image" to name the two extensions, and add a bullet after the firewall one:

```markdown
- 3× 10 GB Hetzner volumes (one per node) backing Longhorn distributed
  storage (V1 engine); Talos mounts each at `/var/mnt/longhorn`, and the
  `longhorn` StorageClass replicates volumes across nodes
```

- Cost table: add a row `| 10 GB volume | 3 | <price> | <total> |` and update the totals (net + gross).
- Configuration section: add `longhorn_volume_size` to the variable list.
- Sanity-check every number against the Step 1 API output before committing.

- [ ] **Step 3: Update `WISHLIST.md`**

Replace the line `- Longhorn or Ceph` with nothing (remove it) — the item is done. Leave the other lines untouched. (The WISHLIST edit was already uncommitted in the working tree at session start; committing the removal here also settles that pending diff.)

- [ ] **Step 4: Commit**

```bash
git add README.md WISHLIST.md
git commit -m "Document Longhorn storage

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
