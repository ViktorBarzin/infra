# GPU VRAM protection via a scheduler extended-resource budget + a runtime watchdog (HAMi/MPS rejected)

The single Tesla T4 (16 GB, ~15360 MiB usable) on `k8s-node1` is **time-sliced**
(`nvidia.com/gpu` advertised ×100, `migStrategy: none`) and shared by ~9 tenants
(immich-ml, immich-worker, frigate, llama-swap, stremio, tts,
ebook2audiobook, ytdlp, android-emulator; portal-stt decommissioned 2026-07-21
— its slot went to the stremio NVENC transcode server, infra#80). Time-slicing grants a *scheduling
turn, not memory* — the scheduler is blind to VRAM, so the tenants can
collectively overallocate the card. On 2026-06-02 immich-ml's unbounded
onnxruntime OCR arena grew from ~2 GB to **10.7 GB**, starved llama-swap's
qwen3-8b, and silently broke recruiter-responder triage for ~5 h
(`docs/post-mortems/2026-06-02-immich-ml-ttl-gpu-oom-recruiter.md`). The
post-mortem's #1 follow-up — alert/guard on GPU VRAM — was never built.

## Context

- **MIG is impossible.** The T4 is Turing; hardware memory partitioning (MIG)
  only exists on Ampere+. So per-tenant *hardware* isolation is off the table.
- **The card is busy but not steadily oversubscribed.** Measured steady residents
  (2026-06-17, `gpu_pod_memory_used_bytes`): immich-ml ~2.1 GiB, frigate ~1.9 GiB,
  llama-swap ~4.35 GiB peak (one model at a time — it already swaps), immich-server
  ~1.2 GiB, portal-stt ~1.5 GiB, android-emulator ~0.15 GiB → ~11 GiB used, ~4 GiB
  free. **The failure mode is a single tenant's runtime runaway, not a
  scheduling-time pile-on.**
- **Prior art already exists (soft):** a `gpu-workload` PriorityClass (1,200,000)
  is auto-stamped on every GPU pod by the Kyverno `inject-gpu-workload-priority`
  policy (tts excluded → `tier-2-gpu`, evicted first); tts runs behind a
  free-VRAM demand-gate (`stacks/tts`, scales 0↔1 on `sum(gpu_pod_memory_used_bytes)`
  vs a floor); immich-ml is soft-bounded by `MACHINE_LEARNING_MODEL_TTL=600`. What
  was missing is anything that bounds a tenant's VRAM *during active use*.

### Alternatives considered and rejected

- **NVIDIA MPS** (device-plugin `sharing.mps`, hard `CUDA_MPS_PINNED_DEVICE_MEM_LIMIT`):
  caps are **uniform** — slice = `total ÷ replicas`, tenants get integer multiples.
  Nine heterogeneous tenants spanning 0.15→6 GB do not fit uniform slices without
  large rounding waste on a card that has none to spare. Rejected.
- **HAMi vGPU** (per-container `nvidia.com/gpumem` MiB caps, libvgpu CUDA hook):
  the *correct* hard-cap primitive and T4-supported, but it **replaces the
  operator's device plugin** (the operator owns/reconciles it), enforces via an
  `LD_PRELOAD` CUDA hook that is **unproven for our NVENC transcode path**
  (open codec bug), **cannot cap the android-emulator** (QEMU bypasses the CUDA
  hook — KubeVirt/Kata explicitly unsupported), carries a **restart-triggered
  false-OOM bug** (#1181) directly in our blast radius (kured reboots node1
  regularly), and its reservation-based scheduling would **supersede the working
  demand-gate** and **strand the ~4 GB of steady headroom**. Too much risk and
  behavioral change for the single proven failure mode. Rejected for now; this
  ADR is the record of *why*, so a future "let's just use HAMi" re-opens with the
  trade-offs already on the table.

## Decision

Make the scheduler VRAM-aware and add runtime teeth — entirely with repo-native
pieces, **no device-plugin/driver change, time-slicing untouched**:

1. **Budget (schedule-time).** Advertise a custom node-level **extended resource
   `viktorbarzin.me/gpumem`** on the GPU node (= ~14000 MiB; ~15.4 GB physical
   minus ~1.4 GB driver/CUDA-context/exporter slack), via a reconcile Job +
   CronJob that `kubectl patch node --subresource=status` (dynamic over
   `nvidia.com/gpu.present=true` nodes; re-asserts after node re-register).
   Every GPU tenant declares `resources.limits."viktorbarzin.me/gpumem"` (live
   2026-07-21: immich-worker 3000, llama-swap 5000, frigate 2300, immich-ml 1800,
   stremio 1500 = 13600 ≤ 14000 advertised — stremio took the 1500 slot freed by
   decommissioning portal-stt, so no node-budget bump was needed; infra#80). Extended
   resources are **non-overcommittable** (request==limit,
   integer), so the scheduler refuses to co-schedule past the card → overflow
   `Pending`. On-demand batch tenants (tts/ebook2audiobook/ytdlp) keep the
   free-VRAM demand-gate and fill the real slack rather than holding a reserved seat.
2. **Watchdog (runtime).** A `gpu-vram-watchdog` CronJob (every minute, nvidia ns)
   reads per-pod `gpu_pod_memory_used_bytes` (the host-PID exporter) and each GPU
   pod's *declared* `gpumem`, and **only when actual free VRAM < floor (~1536 MiB)**
   recycles the biggest **over-budget** offender (used > declared). Contract
   enforcement, not priority (immich-ml and llama-swap share `gpu-workload`, so
   priority can't distinguish them). Acting only under pressure lets a tenant burst
   into genuine slack; the recycle clears its arena (exactly what the TTL=600
   Recreate does for immich-ml when idle). This is what would have caught 2026-06-02.
3. **Alerting** (the never-built follow-up): GPU free-VRAM below floor, GPU pod
   `Pending` on `gpumem`, and pod-over-budget → the `#alerts` digest.

This is **soft enforcement**: the scheduler reserves on paper and the watchdog
corrects at runtime with a detection lag (seconds–minute), so a brief physical
overshoot is possible before a recycle. Accepted, given the failure mode is a
slow arena drift, not an instantaneous spike, and the alternative (HAMi) carries
disproportionate risk for this hardware.

## Consequences
- **A first-party service putting onnxruntime on CUDA must pass
  `{"arena_extend_strategy": "kSameAsRequested"}` in the provider options**, not
  the bare `providers=[provider]` string. The CUDA BFC arena defaults to
  `kNextPowerOfTwo`, so it doubles whenever inference asks for more than it
  holds and never returns the memory. On 2026-09-02 that put claude-memory at
  7,314 MiB against a 5,000 MiB seat — a step of exactly +4,096 followed by a
  flat line, which is the signature: a power-of-two step is the arena, and a
  flat line is not a leak. Pinning `kSameAsRequested` took it to 2,466 MiB.
  Both upstream ONNX tenants already do this — immich at
  `/usr/src/immich_ml/sessions/ort.py:130`, frigate at
  `/opt/frigate/frigate/util/model.py:310` — so the gap was only ever in our own
  code. Deliberately no `gpu_mem_limit`: a hard cap turns an over-large batch
  into an inference failure, which is worse than a large arena, and the seat
  plus the watchdog are what bound a tenant. `GPUTenantOverSeatSustained`
  (infra#85) is the guardrail that now catches the next one.


- **The 2026-06-02 class is bounded** without touching the pinned driver, the GPU
  operator, or time-slicing. immich-ml can no longer silently grow into
  llama-swap's VRAM: it either schedules within its budget or, on a true runaway
  under pressure, gets recycled (its heavy library job is the intended loser).
- **The card has a seating chart now.** Sum of declared budgets ≤ ~14 GB, so a new
  always-on GPU tenant requires re-budgeting; an over-budget on-demand tenant sits
  `Pending`. This is the intended, legible back-pressure.
- **Small/on-demand tenants (android-emulator, ytdlp, tts, ebook2audiobook) are
  NOT budgeted in v1** — they fill *actual* slack rather than holding a scheduler
  seat (tts via its existing free-VRAM demand-gate), and are covered by the
  ~1.4 GiB physical reserve plus budget headroom (the five residents' budgets sum
  to 13300 ≤ 14000 advertised). Give them budgets later if they grow; until then
  the watchdog protects the budgeted five and counts everyone's usage toward free.
- **New RBAC:** the reconcile SA patches `nodes/status`; the watchdog SA lists pods
  cluster-wide and deletes pods in GPU tenant namespaces. Far less privileged than
  existing cluster-admin tooling (woodpecker-agent).
- **Apply order matters:** advertise `gpumem` (nvidia stack) **before** the
  consumer stacks declare it, or a pod requesting an unadvertised extended
  resource is unschedulable. The reconcile runs as a Job (immediate) for this.
- **Fully reversible:** delete the CronJobs/Job + the `gpumem` stanzas, and
  `kubectl patch node --subresource=status` to remove the capacity key. Nothing
  structural; no driver/operator state to unwind.
- The `gpumem` numbers are first estimates; tune from `gpu_pod_memory_used_bytes`.
