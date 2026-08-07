**[Korean Document](./README.md)** | **English Document**

# k8s-cluster-bootstrap

This project builds a fixed five-node Kubernetes GPU cluster foundation from a single control-plane run. It installs and joins four GPU workers over SSH, so no separate commands are required on the workers.

## Fixed topology

| Role | Count | Purpose |
| --- | ---: | --- |
| platform/control-plane | 1 | Kubernetes and platform components |
| GPU backend worker | 4 | One RTX 3090 and one future vLLM replica each |

The script applies platform and GPU-backend role labels with stable backend indices. Each GPU worker is validated for one 24 GiB RTX 3090 and receives Toolkit/CDI configuration.

## Exact versions

| Component | Version |
| --- | --- |
| Kubernetes | **1.35.6** |
| containerd | **2.2.6** |
| Calico | **3.32.1** |
| Helm | **3.20.0** |
| Metrics Server | **0.8.1** |
| NVIDIA Driver | verify existing **580.173.02** |
| NVIDIA Container Toolkit | **1.19.1** |
| GPU Operator | **26.3.3** |
| Model-serving platform | **1.3.0** |
| vLLM runtime | image **1.3.0**, vLLM **0.23.0**, CUDA **13.0** |
| Gateway API | **1.5.1** |
| Gateway API Inference Extension | **1.2.1** |
| agentgateway | **1.0.0** |

`cluster.env`, which is excluded from Git, is the single source for versions, addresses, and SSH credentials.

## Scope

Before making changes, the bootstrap validates Ubuntu 24.04/amd64, NTP synchronization, IP ownership, unique hostnames, SSH/sudo access, and GPU prerequisites. It installs Kubernetes, Calico, and Metrics Server, joins four GPU workers, and verifies that all five Nodes are `Ready`.

Host Toolkit/CDI configuration is applied only to GPU backends. The script verifies that exactly four backends each expose `nvidia.com/gpu=1`. containerd keeps `runc` as its default runtime, while both native CDI and explicit `RuntimeClass/nvidia` paths are tested.

The platform node receives a cluster-wide model-serving operator and a single persistent NATS JetStream using Kubernetes-native discovery. The bootstrap then installs Gateway API, the Inference Extension, the agentgateway controller, and a `GatewayClass`. Finally, it tests cluster DNS and Pod TCP paths between the platform and every GPU backend, and verifies the same vLLM runtime image, vLLM 0.23.0, and CUDA 13.0 on all four GPU backends.

The bootstrap deliberately does not create:

- A Gateway instance or external NodePort/LoadBalancer
- HTTPRoute or serving-routing resources
- An endpoint-selection data plane
- A model deployment, Frontend, or vLLM serving Pod
- A planner, autoscaling, GPU sharing, P/D disaggregation, or service mesh

Create these resources later using separate workload manifests.

## Requirements

- NTP-synchronized Ubuntu 24.04 amd64 nodes
- SSH and root/sudo access from the control plane to all four GPU workers
- Unique hostnames and full node-to-node connectivity
- One RTX 3090 (24576 MiB) with NVIDIA Driver 580.173.02 on each GPU backend
- Access to Kubernetes, GitHub, NVIDIA, NGC, and agentgateway registries
- No existing Kubernetes cluster on the target nodes
- No pre-existing Helm binary on the control plane

The script disables swap and UFW, removes conflicting Docker and distribution containerd packages, and installs upstream containerd. It does not install or change the NVIDIA driver and does not reboot nodes.

## Configure

```bash
cp cluster.env.example cluster.env
chmod 600 cluster.env
```

Configure all four GPU workers using the indexed `GPU_WORKER_*` fields in `cluster.env`. Missing required values are requested interactively and persisted with mode `600`. Bootstrap, resume, and cleanup trust the configured node details, so verify all addresses and accounts before running them.

`cluster.env` may contain SSH credentials. It is excluded from Git, and the scripts refuse to use it when its permissions are broader than `600`.

## Run

Run only on the control plane:

```bash
chmod +x k8s-cluster-bootstrap.sh
sudo ./k8s-cluster-bootstrap.sh
```

No reboot is required during installation. Reboot all nodes first only when a newly installed NVIDIA driver has not yet been loaded by the kernel.

Preflight completes for all four workers before any remote mutation. Worker installation and `kubeadm join` then run with up to four concurrent jobs. If any worker fails, every status is collected and subsequent platform installation is blocked. The scripts print the location of root-only per-worker logs. Large vLLM runtime image pulls are limited to two concurrent workers to reduce network saturation.

Resume an interrupted installation using the same configuration:

```bash
sudo ./k8s-cluster-bootstrap.sh --resume
```

Resume compares the configured nodes with the current Kubernetes state. Workers that are `Ready` with exact component versions and GPU runtime state are preserved. Only missing, incomplete, or drifted workers are reset, reinstalled, and rejoined.

## Result

A successful run verifies:

- Five Ready Nodes: one platform and four GPU backends
- Kubernetes 1.35.6 and containerd 2.2.6 on every node
- Toolkit 1.19.1, CDI, `RuntimeClass/nvidia`, and one RTX 3090 on every GPU backend
- Calico addresses matching each configured Kubernetes `InternalIP`
- Cluster DNS and Pod TCP connectivity from the platform and every GPU backend to every GPU backend
- Model-serving operator 1.3.0 and a Bound NATS JetStream PVC
- Gateway API and Inference Extension CRDs, the agentgateway controller, and a `GatewayClass`
- The same vLLM runtime image digest, vLLM 0.23.0, and CUDA 13.0 across all GPU backends
- A credential-free installation report

## Cleanup

Using the same completed `cluster.env`:

```bash
sudo ./k8s-cluster-cleanup.sh
```

After a `y` confirmation, cleanup removes the Gateway foundation, model-serving platform and NATS data, GPU Operator, Kubernetes/Calico, containerd images, and the Toolkit installed on GPU backends. NVIDIA drivers and unrelated user kubeconfig/Helm data are preserved.

The four GPU workers are cleaned concurrently. The control plane is cleaned last only after every worker cleanup succeeds. Failure output includes the root-only log location. Reboot the workers and then the control plane manually, and verify `nvidia-smi` on each GPU backend. Swap and UFW are not restored automatically.

## Contributing

See the [contribution guidelines](.github/CONTRIBUTING.md).
