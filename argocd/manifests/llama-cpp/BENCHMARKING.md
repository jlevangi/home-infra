# llama-swap model benchmark — Quadro P4000 (Pascal sm_61, 8 GiB VRAM)

Running comparison of every GGUF on the prod GPU node, ranked for the user's
primary use case: **parallel coding agents** (opencode, aider, etc).

**Hardware reality check:** Pascal has no native BF16. FP16 ops are slow. The
practical ceiling on this GPU is ~12 tok/s per slot regardless of model size.
The decisive variable is **architecture (MoE vs dense)** — MoE with ~3-4B
active params per token consistently beats dense models by 4-5x because most
layers stay on CPU and the active params fit in our ~5 GiB usable VRAM budget.

Benchmarks marked **(May 20 2026)** were run with `ngl=10`, `ctx-size=8192`,
`--flash-attn on`, `--cache-type-k/v q4_0`, threads=22, on a 14-token
"write a median function" prompt with `max_tokens=200` (parallel runs fire
identical concurrent requests).

Benchmarks marked **PENDING** are post-2026-05-21 additions that have not
yet been measured on this hardware; ctx-size for fresh runs should be
left at the production ConfigMap value (262144 for Qwen 35B, 131072 for
Gemma and dense comparison models) since KV cost is trivial with Q4 KV
cache and gives a more realistic per-slot budget for parallel agent use.

---

## Comparison table

### Currently deployed (`/mnt/llm-tank` on prod GPU node)

| Model | Arch | Total / Active | Quant | Size | Per-slot gen | Par=4 aggregate | VRAM | HumanEval+ | SWE-bench | Cold load |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|
| Qwen3.6-35B-A3B-UD-Q4_K_S | MoE | 35B / 3B | Q4_K_S | 19.5 GB | 11.1 t/s | 22.2 t/s | 5202 MiB | ~92% | 73.4% | 45 s |
| Qwen3.6-35B-A3B-MXFP4_MOE | MoE | 35B / 3B | MXFP4 | 20.2 GB | 10.9 t/s | — | 5368 MiB | ~92% | 73.4% | 40 s |
| Qwen3.6-27B-UD-Q8_K_XL | dense | 27B / 27B | Q8_K_XL | 34 GB | **0.93 t/s** ⚠️ | — | 4236 MiB | high | 77.2% | ~12 s page-cached ‡ |
| **Gemma4-26B-A4B** | MoE | 26B / 4B | Q4_K_M | 15.8 GB | **14.1 t/s** | — | 6108 MiB | 78.5% | (na) | 40 s |
| Gemma4-31B | dense | 31B / 31B | Q4_K_M | 17.1 GB | 2.7 t/s | — | 3864 MiB | 82.7% | (na) | 40 s |
| MiniMax-M2.7-MXFP4_MOE | MoE | 230B / 10B | MXFP4 | 130 GB (split) | **UNBENCHABLE** ‼️ | — | n/a | (na) | (na) | **>30 min from tank** † |

### Removed / no longer downloaded (historical baseline)

| Model | Arch | Total / Active | Quant | Size | Per-slot gen | VRAM | HumanEval+ | SWE-bench | Cold load |
|---|---|---|---|---|---:|---:|---:|---:|---:|
| Qwen3.6-35B-A3B-UD-Q4_K_M | MoE | 35B / 3B | Q4_K_M | 20.6 GB | **12.1 t/s** | 5394 MiB | **93.3%** | **73.4%** | 45 s |
| GLM-4.7-Flash-Q6_K | MoE | 30B / 3B | Q6_K | 23.0 GB | 11.3 t/s | 5034 MiB | ~92% | **73.8%** | 20 s |
| Qwen3.6-35B-A3B-UD-Q8_K_XL | MoE | 35B / 3B | Q8_K_XL | 36.4 GB | 9.1 t/s | 5604 MiB | 93%+ | 73.4% | **539 s** ‼️ |
| Qwopus3.5-9B-coder | dense | 9B / 9B | **BF16** | 16.7 GB | 4.2 t/s | 5970 MiB | 87.8% | (na) | 35 s |
| Qwen3.6-27B-Q4_K_S | dense | 27B / 27B | Q4_K_S | 15.3 GB | 2.5 t/s | ~6 GB | high | 77.2% | 33 s |
| GLM-4.7-Flash-BF16 | MoE | 30B / 3B | BF16 | 55 GB | — | — | ~92% | 73.8% | **~4 hours** ‼️ |

\* Qwen-35B-A3B-Q4_K_M parallel=4 sweep wasn't run; estimated from Q4_K_S
   (22.2 t/s @ par4) scaled by the per-slot ratio (12.1 / 11.1).

‡ Qwen3.6-27B-UD-Q8_K_XL cold-load entry is page-cache-warm: file had been
   recently touched on the host, so the on-disk read was already in Linux
   page cache. A truly cold uncached read of 34 GiB from spinning tank
   would be ~4 min at ~150 MB/s; re-run after `echo 3 > /proc/sys/vm/drop_caches`
   for a clean number.

† MiniMax-M2.7-MXFP4_MOE cannot reach `/health=200` within llama-swap's
   maximum `healthCheckTimeout` window when loading from the spinning
   tank pool. Verified 2026-05-21 at 600 s (default), 1800 s (raised),
   and via direct invocation past 30 min — the load IS progressing
   (~9 GiB pulled from disk in the first 30 s with a partly-warm page
   cache, confirmed via `/proc/$PID/io read_bytes`), but the
   initialization touches many random regions of the 130 GiB split
   GGUF (MoE expert metadata, MXFP4 unpacking), and spinning-disk
   seek latency dominates. The Pascal GPU portion of the load (ngl=3
   layer transfer) is not the bottleneck.

   **Recommended action**: revisit after the flash Longhorn pool (see
   beads home-infra-sbd) lands and we have NVMe-class read latency on
   the model storage, OR move just this one model onto a flash zvol
   for selective fast loading.

### Verification of new ctx + parallel defaults (2026-05-21)

Spot-checked Qwen3.6-35B-A3B-UD-Q4_K_S under the new `parallel=4 +
ctx-size=262144` configuration with a single request:
- Cold load: 50 s (consistent with the prior `45 s` baseline)
- VRAM: 5546 MiB (vs 5202 MiB at par=1 + ctx=8192 — modest bump from
  the larger KV cache allocation)
- Warm wall for 200 tokens: 19.7 s → ~10 t/s per slot, in line with the
  11.1 t/s previously measured

Per-slot generation speed is essentially unchanged by the parallel
config (single-request workload); the parallel slots come into play
when concurrent agents fire requests, where prior data showed
aggregate scaling to ~22 t/s at par=4. Re-running the par=4
concurrent burst to confirm scaling under the new ctx-size is left
as a follow-up.

### 128K-context sweep with explicit unloads (2026-05-24)

This follow-up run explicitly unloaded the previous `llama-server` child
before each model switch and re-spawned the next model directly inside the
pod on a scratch port. That gives clean GPU / process state between runs.

Important caveat: these are **unloaded-model** numbers, not guaranteed
disk-cold numbers. Linux page cache was not dropped on the node, so the
`cold load` column below means "no active model process" rather than
"uncached read from storage".

| Model / config | Effective slot ctx | Single gen | 4-request aggregate | VRAM | Load from unloaded |
|---|---:|---:|---:|---:|---:|
| Qwen3.6-35B-A3B-UD-Q4_K_S, `parallel=4`, `ctx=262144` | 64 k | 9.67 t/s | 21.68 t/s | 5544 MiB | 7.9 s * |
| Qwen3.6-35B-A3B-UD-Q4_K_S, `parallel=2`, `ctx=262144` | 128 k | 9.29 t/s | 15.91 t/s | 5614 MiB | 7.8 s * |
| Qwen3.6-35B-A3B-MXFP4_MOE, `parallel=4`, `ctx=262144` | 64 k | 8.77 t/s | 18.88 t/s | 5968 MiB | 117.3 s |
| Gemma4-26B-A4B, `parallel=2`, `ctx=131072` | 64 k | 10.70 t/s | 17.57 t/s | 6406 MiB | 92.7 s |
| Gemma4-26B-A4B, `parallel=4`, `ctx=131072` | 32 k | 10.98 t/s | **27.08 t/s** | 6386 MiB | 7.2 s * |
| Qwen3.6-27B-UD-Q8_K_XL, `parallel=1`, `ctx=131072` | 128 k | 0.97 t/s | — | 4132 MiB | 189.6 s |
| Gemma4-31B, `parallel=1`, `ctx=131072` | 128 k | 1.82 t/s | — | 3184 MiB | 104.3 s |

\* Same GGUF had already been touched earlier in the session, so treat the
load timing as page-cache-warm.

What this changes operationally:

- **Best 4-agent coding model currently mounted** remains
  `Qwen3.6-35B-A3B-UD-Q4_K_S`: it holds ~21.7 t/s aggregate while still
  giving each agent a 64 k window.
- **Fastest raw 4-agent throughput** is `Gemma4-26B-A4B` at `parallel=4`:
  ~27.1 t/s aggregate, but only **32 k per agent** at a 128 k total window.
- **Qwen can serve 4 x 128 k slots** by raising total `ctx-size` to `524288`.
  The real problem is not fit, it is long-prompt concurrent decode speed.
- **MXFP4 is not competitive on Pascal**: slower generation, higher VRAM,
  and much worse load time than Q4_K_S.
- **Dense Qwen / Gemma remain unusable for interactive agent work** even at
  a 128 k total window.

### Long-prompt follow-up: 4 x 128K vs 4 x 262K (2026-05-24)

The short-prompt numbers above were optimistic for real agent workflows. A
second pass used a synthetic repository-dump prompt of **36,458 prompt
tokens** and measured 160-token completions under concurrent load.

| Model / config | Effective slot ctx | Single prompt | Single gen | Parallel load | Aggregate completion | VRAM | Load from unloaded |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen3.6-35B-A3B-UD-Q4_K_S, `parallel=4`, `ctx=524288` | 128 k | 93.4 t/s | 5.23 t/s | 4 requests | 0.50 t/s | 6072 MiB | 9.1 s |
| Qwen3.6-35B-A3B-UD-Q4_K_S, `parallel=4`, `ctx=1048576` | 262 k | 90.76 t/s | 4.80 t/s | 4 requests | 0.49 t/s | 7128 MiB | 8.9 s |

Operationally:

- **4 x 262 k is technically valid** on this model: llama.cpp created four
  `n_ctx = 262144` slots successfully.
- **4 x 128 k is the saner live default** because it saves ~1 GiB VRAM versus
  4 x 262 k with no meaningful loss of real long-prompt throughput.
- **200 GiB system RAM does not rescue dense long-context parallel decode** on
  this machine. The 8 GiB Pascal GPU remains the hard bottleneck.

### Dense 27B Q5 long-context experiment (2026-05-24)

`Qwen3.6-27B-Q5_K_M.gguf` was tested as a potential 3-agent / 128 k dense
alternative. A `gpu-layers` sweep found `16` to be the best practical point:
`18` was only marginally faster while pushing VRAM to ~8.1 GiB.

| Model / config | Effective slot ctx | Single prompt | Single gen | Parallel load | Aggregate completion | VRAM | Load from unloaded |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen3.6-27B-Q5_K_M, `gpu-layers=16`, `parallel=3`, `ctx=393216` | 128 k | 32.29 t/s | 1.25 t/s | 3 requests | 0.18 t/s | 7516 MiB | 15.2 s |

Conclusion: this dense 27B Q5 is better than the old Q8 reference, but still
too slow for real multi-agent long-context use on the Quadro P4000. Keep it as
an experimental / quality-reference alias, not a default interactive model.

### Role-specific live aliases (2026-05-24)

The best practical adaptation for this hardware is **role separation**, not
trying to make one giant-context dense model do everything. Two extra live
aliases were added for the Qwen 35B A3B MoE model:

| Alias | Purpose | Key flags | Quick check |
|---|---|---|---:|
| `Qwen3.6-35B-A3B-UD-Q4_K_S-worker` | fast worker / reviewer bursts | `parallel=4`, `ctx=131072`, `batch=2048`, `ubatch=512` | 4-way short burst: **22.84 t/s agg** |
| `Qwen3.6-35B-A3B-UD-Q4_K_S-planner` | one deeper planning / review task | `parallel=1`, `ctx=262144`, `batch=1024`, `ubatch=256` | single short request: **9.87 t/s gen** |

LibreChat was manually re-pointed to prefer the worker alias first, followed by
planner, balanced Qwen, Gemma, then the dense 27B experiment.

⚠️ Qwen3.6-27B-UD-Q8_K_XL is the slowest model measured to date: 0.93 t/s.
   Per-token GPU work is small but the 34 GiB Q8 weights live mostly in
   CPU RAM (ngl=3 of ~64 layers); the CPU memory-bandwidth ceiling
   dominates. Useful as a high-quality reference for quality comparisons
   against the MoE quants, not for any interactive workflow.

   Measured 2026-05-21 with `--ctx-size 65536`, `--gpu-layers 3`,
   `--parallel 1`, `--threads 22`, `--cache-type-k/v q4_0`. Prompt
   processing 6.4 t/s, generation 0.93 t/s, finish_reason=stop.

### Parallel scaling for the two top contenders

| Parallel slots | GLM-4.7-Flash-Q6_K | Qwen-35B-A3B-Q4_K_S |
|---:|---:|---:|
| 1 | 11.3 t/s per slot | 11.1 t/s per slot |
| 2 | 8.1 t/s × 2 = **14.1 t/s agg** | 10.1 t/s × 2 = **17.4 t/s agg** |
| 4 | 6.6 t/s × 4 = **22.4 t/s agg** | 7.2 t/s × 4 = **22.2 t/s agg** |

Both peak ~22 t/s aggregate at par=4. VRAM stays flat (~5 GiB) across slot
counts because `ctx-size` is divided across slots — KV cache size is
constant. At parallel=4, each slot has 2k effective context which is tight
for code review; bump `ctx-size` to 32k for ~8k per slot if you upgrade beyond
the current 8 GiB allocation.

---

## Capability intelligence (from HuggingFace)

Drawing on each model's published benchmarks and my read of the architecture:

### Tier S — production coding agent
- **Qwen3.6-35B-A3B** (any UD-Q4 quant): Apr 2026, 93.3% HumanEval, 73.4%
  SWE-bench Verified, native 262k context. Best agentic coding score among
  models we have. Sparse MoE means it's actually fast.
- **GLM-4.7-Flash** (Q6_K): Jan 2026, ~92% HumanEval, 73.8% SWE-bench
  (highest SWE score we have). MoE 30B/3B-active. Same speed tier as Qwen.

### Tier A — coder, but smaller
- **Qwopus3.5-9B-coder**: 87.8% HumanEval+ (Opus-distilled Qwen merge). Would
  be a great fast coder but the BF16 quant we have **chokes on Pascal**.
  Would need a Q4_K_M re-download to be viable here.

### Tier B — general purpose, not coding-focused
- **Gemma4-26B-A4B**: 78.5% HumanEval. **Fastest model on this hardware**
  (14.1 t/s). Strong general assistant, mediocre coder. Useful as the
  "non-coding" alias for chat, summarization, etc.
- **Gemma4-31B** (dense): 82.7% HumanEval but **dense → 2.7 t/s, unusable**.

### Tier C — unusable on this hardware
- **Qwen3.6-27B** (dense): SWE-bench 77.2% (better than the MoE variants on
  paper!) but **dense → 2.5 t/s**. Can't use it for parallel agents.
- **GLM-4.7-Flash-BF16** (already removed): same model as Q6_K but Pascal
  can't natively run BF16.

---

## Recommendations

### Keep in llama-swap (3 aliases)

1. **`Qwen3.6-35B-A3B-UD-Q4_K_M`** — primary coding agent. Highest
   HumanEval+ (93.3%), fastest Qwen MoE quant variant, slightly better
   quality than Q4_K_S. Default for `opencode`, `aider`, etc.
2. **`GLM-4.7-Flash-Q6_K`** — alternative coder. Highest SWE-bench (73.8%),
   fastest cold load (~20s vs Qwen's ~45s) which matters for snappy first
   request, 256k context.
3. **`Gemma4-26B-A4B`** — fast general assistant. 14.1 t/s, weaker coder
   but useful for non-code tasks where speed dominates.

### With the currently mounted Qwen + Gemma set (2026-05-24)

1. **`Qwen3.6-35B-A3B-UD-Q4_K_S-worker`** — best default for interactive
   LibreChat coding and short worker-agent tasks.
2. **`Qwen3.6-35B-A3B-UD-Q4_K_S-planner`** — best for one deeper planning /
   review job with the full 262 k context on a single slot.
3. **`Qwen3.6-35B-A3B-UD-Q4_K_S`** — balanced 4 x 128 k profile when you
   genuinely need large context on every worker and can tolerate slower
   long-prompt decode.
4. **`Gemma4-26B-A4B`** — fastest raw non-coding / summarization option.
5. **`Qwen3.6-27B-Q5_K_M`** — experiment only; do not use as the default.

### Remove from llama-swap config + delete GGUFs

| GGUF | Size | Why remove |
|---|---:|---|
| `Qwen3.6-35B-A3B-UD-Q4_K_S.gguf` | 19.5 GB | Q4_K_M is strictly better (same speed band, slightly higher quality) |
| `Qwen3.6-35B-A3B-MXFP4_MOE.gguf` | 20.2 GB | Slower than Q4_K_M with no quality benefit (experimental quant, no advantage on Pascal) |
| `Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf` | 36.4 GB | **9-min cold load** (fragmented + Q8 conversion overhead). Only 9.1 t/s. Q4_K_M dominates. |
| `Qwen_Qwen3.6-27B-Q4_K_S.gguf` | 15.3 GB | Dense — 2.5 t/s. Unusable for parallel agents. |
| `gemma-4-31B-it-Q4_K_M.gguf` | 17.1 GB | Dense — 2.7 t/s. Unusable for parallel agents. |
| `Qwopus3.5-9B-coder-Exp-BF16.gguf` | 16.7 GB | BF16 on Pascal degrades it to 4.2 t/s. **Replace with a Q4_K_M variant** for a viable small coder. |

**Total disk reclaimed: ~125 GB** (out of 362 GB used → drops to ~237 GB).

### Configuration tuning notes

- **`ctx-size` + `--parallel` strategy**: llama.cpp splits the KV cache
  evenly across slots, so per-slot effective context = `ctx-size / parallel`.
  The May 2026 production defaults target **~64 k per-slot context** across
  the board, with parallel slot counts chosen by architecture:
  - **Qwen3.6-35B-A3B-UD-Q4_K_S-worker** → `parallel=4`, `ctx-size=131072`
    → 4 × 32 k slots. Highest-confidence choice for short worker-agent bursts.
  - **Qwen3.6-35B-A3B-UD-Q4_K_S-planner** → `parallel=1`, `ctx-size=262144`
    → 1 × 262 k slot. Best for one deeper planning or review task.
  - **Qwen3.6-35B-A3B-UD-Q4_K_S (balanced)** → `parallel=4`,
    `ctx-size=524288` → 4 × 128 k slots. Technically valid, but long-prompt
    concurrent generation still collapses on this GPU.
  - **Gemma4-26B-A4B** → `parallel=4`, `ctx-size=131072` → 4 × 32 k slots.
    The 2026-05-24 sweep showed a clear throughput win here (~27 t/s
    aggregate) with essentially unchanged single-request speed.
  - **Dense models (Qwen 27B Q5_K_M / Q8_K_XL, Gemma4-31B)** → prefer
    `parallel=1` unless you are running a targeted experiment. System RAM can
    hold them, but decode remains CPU-bandwidth-bound at ~1-2 t/s.

  Total KV memory cost at these defaults is ~5-16 GiB CPU-side per model,
  well within the 80-130 GiB pod budget.
- **Cold-start matters more than steady-state** for agents that swap models.
  GLM's ~20s cold load is the biggest practical win over Qwen's ~45s for
  agent UX.
- **`--reasoning auto`** is left on every entry so frontends can toggle
  thinking per-request via `chat_template_kwargs.enable_thinking`. For
  coding, plain non-thinking output is usually what you want; for hard
  reasoning tasks, request thinking explicitly.

---

## Methodology

- One-shot generation request, low temperature (0.1), 200 max_tokens, code-write prompt
- Each model: spin up `/usr/local/bin/llama-server` directly inside the
  llama-cpp pod with the exact same flags differing only in
  `--gpu-layers`, `--parallel`, and the model file
- Long-prompt follow-ups use a synthetic repository-dump prompt of ~36.5k
  prompt tokens with `max_tokens=160` to approximate real agentic code review
  pressure instead of the tiny median-function prompt
- Per-slot gen tok/s comes from llama-server's own `timings.predicted_per_second`
- Aggregate tok/s = total generated tokens / wall clock of all concurrent
  curl requests
- VRAM via `nvidia-smi --query-gpu=memory.used` after model loaded
- Cold load = time from `llama-server` exec to first successful `/health`
- Plex/Jellyfin co-tenancy budget assumed at ~2-3 GiB during transcodes;
  every "keep" model fits in the remaining ~5 GiB headroom

To re-run any benchmark, see `/tmp/bench-parallel.sh` inside the
llama-cpp pod (re-staged with `kubectl cp` each session).
