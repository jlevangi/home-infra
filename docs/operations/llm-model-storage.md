# LLM Model Storage on the Atlas GPU Worker

## Source of truth

The production GPU worker is VM `107` (`k3s-prod-worker-gpu-1`) on Atlas.

- Terraform: `terraform/stacks/k3s/atlas/prod/workers/gpu-worker.tf`
- Ansible topology: `ansible/group_vars/k3s_cluster_topology.yml`
- Kubernetes local PV: `argocd/manifests/llama-cpp/base/pv.yaml`

`scsi2` is an 800 GiB virtual disk from the Atlas `tank` pool. In the guest it
is `/dev/sdb1`, ext4, mounted at `/mnt/llm-tank`. The `llama-cpp-models-pv`
local PersistentVolume exposes that path read-only to the `llama-cpp` workload.

## Storage policy

- `tank` is HDD-backed ZFS capacity storage. It is appropriate for model
  archives and controlled inference tests, but it is not NVMe-class streaming
  storage.
- `flash` is the constrained SSD-backed ZFS pool. Do not place model files
  there while it carries production Longhorn capacity.
- `/var/lib/longhorn` (`scsi1`) belongs to Longhorn. Never store model files
  there.
- The NAS may hold archived model copies, but it is not an active Colibri
  model tier; the 1 GbE network path is unsuitable for streamed MoE weights.

## Current operational state — 2026-08-25

- VM memory: 120 GiB configured and running; ballooning disabled.
- Model disk: 787 GiB ext4 capacity, 569 GiB used before the stale-model
  cleanup, 180 GiB available.
- The `llama-cpp` production overlay is intentionally scaled to zero. Confirm
  it remains stopped before removing files from the local PV.
- The model disk fstab entry must retain `nofail`; a prior storage failure
  otherwise blocked VM boot.

## Colibri pilot guardrails

Colibri needs its supported safetensors model layout, not the legacy GGUF
files used by llama.cpp. Use a separate `colibri/` directory under
`/mnt/llm-tank` and keep at least 20% free filesystem capacity during
conversion/download staging.

Start with a small supported MoE and measure disk-cold and warm TTFT, decode
rate, disk throughput, RAM, and GPU use. Do not change the 9router default
route until the pilot is measurably better for a defined workload.

## Model cleanup procedure

1. Confirm no workload is mounted or using the model PV and `llama-cpp` is
   scaled to zero.
2. Record each removed file's path, size, timestamp, and upstream source where
   known in a deletion manifest.
3. Remove stale `.incomplete` downloads before complete models.
4. Verify `df -h /mnt/llm-tank` and the complete deletion manifest afterward.
5. Do not delete Longhorn data or modify the `flash` pool as part of model
   cleanup.

See also [LLM Default Model](llm-default-model.md).
