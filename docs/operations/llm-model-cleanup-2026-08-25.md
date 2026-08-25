# LLM Model Cleanup Manifest — 2026-08-25

**Scope:** all legacy llama.cpp GGUF models and incomplete Hugging Face downloads on VM `107`, `/mnt/llm-tank`.

**Reason:** `llama-cpp` is scaled to zero. The next pilot is Colibri, which needs its own supported safetensors layout and does not consume these GGUFs. This cleanup does not touch `/var/lib/longhorn`, any PVC, NAS data, or the SSD-backed `flash` pool.

## Preconditions verified

- `llama-cpp` Deployment: `0` desired replicas, `0` ready replicas.
- `llama-cpp-models-pv`: mounted only by the stopped `llama-cpp` workload.
- `fuser -vm /mnt/llm-tank`: no userspace model consumers.

## Deleted directories and models

| Directory | Approx. pre-cleanup size | Complete GGUF payload |
|---|---:|---|
| `gemma4/` | 33 GiB | `gemma-4-26B-A4B-it-UD-Q4_K_M.gguf` (15.78 GiB); `gemma-4-31B-it-Q4_K_M.gguf` (17.07 GiB) |
| `minimax/` | 389 GiB | MiniMax M2.7 UD-Q4_K_M, four shards (~176 GiB); partial MiniMax M3 UD-Q3_K_M, five shards (~181 GiB) |
| `qwen3.6/` | 92 GiB | Qwen3.6 27B Q5_K_S (17.95 GiB), UD-Q5_K_XL (18.95 GiB), UD-Q8_K_XL (33.32 GiB); Qwen3.6 35B-A3B UD-Q4_K_M (21.11 GiB) |
| `qwen3/` | 47 GiB | Qwen3-Coder-Next UD-Q4_K_M (45.92 GiB); Qwen3-Embedding-0.6B Q8_0 (0.60 GiB) |
| `qwopus/` | 9 GiB | Qwopus3.5-9B-Coder-MTP Q8_0 (9.11 GiB) |

All Hugging Face `.cache` directories, sidecar `.metadata` files, benchmarking notes bundled with the model directories, and incomplete downloads were removed with their parent model directories.

## Incomplete payload removed

`minimax/.cache/huggingface/download/UD-Q3_K_M/` contained four stale incomplete files totaling about **76.6 GiB**, plus smaller incomplete MXFP4 files under `minimax/M3/.cache/`.

## Retrieval notes

The removed models were Hugging Face downloads. The surviving `.metadata` files recorded the original model filenames; use the names in this manifest to locate the equivalent upstream repositories and quantizations if a llama.cpp rollback is ever required. No checksum was taken because the payload is being removed rather than retained as a backup artifact.

## Post-cleanup verification

Completed 2026-08-25:

- `/mnt/llm-tank`: 787 GiB total, 28 KiB used, 749 GiB available (1%).
- Only `lost+found` remains at the mount root.
- No `*.gguf`, `*.safetensors`, or `*.incomplete` files remain.

The disk is ready for a separate Colibri model staging directory under
`/mnt/llm-tank/colibri/`.

See [LLM Model Storage](llm-model-storage.md).
