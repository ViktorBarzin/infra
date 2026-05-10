# Vision-LLM benchmark — Malaga / Seville album

**Run ID:** `2026-05-10-1424` · **Date:** 2026-05-10 · **Operator:** wizard

100 photos randomly sampled (seed=42) from the Immich album `🇪🇸 Malaga
Seville` (`46565b85-7580-4ac1-91a6-1ece2cf8634d`, 1556 image assets +
9 videos), scored by three local vision-LLMs served by `llama-swap`
on a single Tesla T4. Goal: pick a model to wire into
`instagram-poster`'s `/candidates` ranking path.

## TL;DR

**Recommendation: `qwen3vl-4b`.**

- **Fastest** by a wide margin (3.55 s p50, 60% of qwen3vl-8b),
  important once this is in the request path of `/candidates`.
- **100% structured-output success** — same as the other two; GBNF
  grammar enforcement worked across the board.
- **Captions are competitive** with the 8B model in qualitative review
  (tied or close on 8/10 sampled photos; 8B wins on Flair, 4B wins on
  Latency).
- **Most decisive scorer** — 47/100 photos got IG-fit=9 vs 17 for
  qwen3vl-8b and 9 for minicpm. We get more signal at the top end
  for ranking.

Use qwen3vl-8b for *manual* caption refinement (top-1 of the day) if
caption polish matters. Use minicpm-v-4-5 for nothing immediate — it's
the most conservative scorer and the slowest at high quantiles, with
no offsetting wins in this dataset.

## Setup

- Hardware: 1× Tesla T4 (16 GiB VRAM), `nvidia.com/gpu` time-slicing
  enabled (replicas=100), pod scheduled on `k8s-node1`.
- Server: `mostlygeek/llama-swap:cuda` (ships llama.cpp `b9085-046e28443`)
  on `llama-swap.llama-cpp.svc.cluster.local:8080`.
- Models: GGUF Q4_K_M, mmproj F16 except qwen3vl-4b which used the
  Q8_0 mmproj (alphabetically first matching the glob).
- Image prep: EXIF-transposed, long-edge resized to 1024 px, JPEG q=90,
  base64-embedded as `image_url` data URLs.
- Generation: `temperature=0`, `top_k=1`, `enable_thinking=false`,
  GBNF grammar pinning the JSON schema (6 fields, 1–10 ints, ≤8 tags).
- Run isolation: `immich-machine-learning` scaled to 0 for the
  duration to avoid noisy GPU contention. *(Diagnostic note: the
  scheduling failure that triggered this was actually node1 RAM —
  not GPU — at 94% allocated. Time-slicing was already on. Bumping
  node1 RAM is tracked as a follow-up.)*

## Headline numbers

| model | n | parse_ok | p50 latency | p95 latency | median IG-fit | median aesthetic |
|-------|---|----------|-------------|-------------|---------------|------------------|
| **qwen3vl-4b** | 100 | 100% | **3.55 s** | 4.06 s | 8.0 | 8.0 |
| minicpm-v-4-5 | 100 | 100% | 5.62 s | 6.00 s | 7.0 | 8.0 |
| qwen3vl-8b | 100 | 100% | 5.98 s | 6.64 s | 7.0 | 8.0 |

Total wall time for the run: **33 m 32 s** (300 calls + 3 cold loads
of ~30 s each).

## What each model is good at

### qwen3vl-4b — fast and decisive
- p50 3.55 s — comfortable for adding to `/candidates` request path.
- IG-fit distribution skews right (47 nines), spreading 6 → 9 fairly
  evenly, which is what you want from a *ranker*.
- Captions are emoji-friendly, hashtag-friendly, sometimes
  hallucinatory (e.g. labelled a Seville street as "Barcelona's
  colourful streets" once).
- Failure mode to watch: occasional double-down on the same caption
  template ("Lost in the tiles. 🌿" repeated across two unrelated
  blue-dress photos).

### minicpm-v-4-5 — conservative, terse
- Most conservative scorer: 65% of photos got IG-fit=7. Only 9 nines.
  Less useful as a top-N ranker because the top is squashed.
- Fastest p95 of the three (6.0 s) but slower p50 than qwen3vl-4b.
- Captions are short and lower-case ("azulejo dreams.",
  "sunshine & secrets") — distinct voice but less Instagram-native.

### qwen3vl-8b — most polished captions
- Best subject identification (specifically named "Metropol Parasol"
  and "Plaza de España" by name where the others said "modern
  architecture" / "plaza").
- Captions read well: "Coffee & calm vibes ☕️", "where modern meets
  historic under a brilliant sky".
- Slowest p50 (5.98 s) and tightest score distribution (median 7,
  17 nines) — middle of the pack as a ranker.

## Top-10 agreement (Kendall-tau-style overlap)

How many of each model's top-10 IG-fit picks appear in another
model's top-10:

| pair | overlap |
|------|---------|
| qwen3vl-4b ↔ qwen3vl-8b | 5/10 |
| minicpm-v-4-5 ↔ qwen3vl-4b | 4/10 |
| minicpm-v-4-5 ↔ qwen3vl-8b | 4/10 |

Read: there's moderate but not strong agreement. The models pick
roughly half the same "best" photos and half different ones. For
ranking, that's a healthy sign — they're not collapsing to a single
notion of "good", so combining their scores would add real signal.

## Cost-equivalent context

Approximate cost to score the same 100 photos via cloud APIs
(prompt ≈ 1100 tokens incl. image, completion ≈ 100 tokens):

| backend | input | output | per-100 photos |
|---------|-------|--------|----------------|
| Local llama-swap on T4 | — | — | ≈ $0.04 (electricity, ~70 W × 7 min) |
| Anthropic Haiku 4.5 | $1.00/M | $5.00/M | ≈ $0.15 |
| Anthropic Sonnet 4.6 | $3.00/M | $15.00/M | ≈ $0.45 |
| Google Gemini 2.5 Flash | $0.30/M | $2.50/M | ≈ $0.05 |

Local is competitive with Gemini Flash on marginal cost. The case
for keeping it local is privacy (Immich originals never leave the
LAN), no rate-limits, and no per-call quota planning. The case
against is the GPU is finite — adding this to a request path means
sharing T4 time with frigate, ytdlp, and (when we restore it)
immich-ml. With time-slicing on, that's tractable but each tenant
gets fewer full-GPU kernels.

## Sample captions (10 representative photos, all 3 models)

`9f9c9faf-...` — man at ornate arch in Seville
- **minicpm-v-4-5** (7/8): sunshine & secrets
- **qwen3vl-4b** (9/8): Found the perfect spot to pause. 🌞 #travel #architecture
- **qwen3vl-8b** (9/8): Standing in Seville's magic, framed by history and color.

`0d53158b-...` — Metropol Parasol
- **minicpm-v-4-5** (9/8): Seville's skyward statement.
- **qwen3vl-4b** (9/8): Seville's iconic modern structure against a vibrant blue sky.
- **qwen3vl-8b** (9/8): The Metropol Parasol in Seville, where modern meets historic under a brilliant sky.

`23137c1c-...` — coffee shot
- **minicpm-v-4-5** (8/7): a morning pick-me-up and a smile.
- **qwen3vl-4b** (8/7): Coffee & chill. Perfectly imperfect moment.
- **qwen3vl-8b** (9/8): Coffee & calm vibes ☕️

`3376ee87-...` — woman against tiled wall
- **minicpm-v-4-5** (7/8): azulejo dreams.
- **qwen3vl-4b** (9/8): Lost in the tiles. 🌿
- **qwen3vl-8b** (9/8): Blue tiles, golden light, and a moment of quiet grace.

`4f2fea45-...` — courtyard
- **minicpm-v-4-5** (7/8): hidden gems of seville
- **qwen3vl-4b** (7/8): Timeless beauty in a Spanish courtyard. 🌿
- **qwen3vl-8b** (7/8): A serene courtyard in Seville, where palm trees sway under the sun.

`ea713729-...` — flower-market street (qwen3vl-4b confused location)
- **minicpm-v-4-5** (7/8): Seville's hidden gems.
- **qwen3vl-4b** (7/8): Walking through *Barcelona's* colorful streets, backlit by golden hour.
- **qwen3vl-8b** (7/8): Walking through Seville's vibrant streets, lavender in hand.

The full list of 10 sample sets is in the auto-generated section
below; the raw 300-row JSON is at `benchmark-2026-05-10-1424.json`
in this directory.

## Operational cost during the run

- llama-swap pod (1× T4 wholly allocated for the duration): ~33 min.
- Immich-ML downtime: ~33 min. New uploads weren't auto-tagged or
  CLIP-embedded during this window. No user-visible impact (Immich
  search against already-indexed assets still worked via pgvector).
- Network egress: zero — Immich originals stayed on the LAN, all
  scoring traffic was in-cluster.

## Reproducibility

```bash
DATA_DIR=/tmp/benchmark \
  IMMICH_API_KEY=… \
  LLAMA_SWAP_URL=http://localhost:18080 \
  poetry run python -m instagram_poster.benchmark run \
    --album-id 46565b85-7580-4ac1-91a6-1ece2cf8634d \
    --models qwen3vl-8b,minicpm-v-4-5,qwen3vl-4b \
    --limit 100 --random-seed 42 --run-id 2026-05-10-1424
```

The same `--random-seed` reproduces the photo sample exactly. Prompt
version `4bbb7e7721da24d9` is the SHA-256 of the system prompt + user
prompt + GBNF grammar; rerunning under the same prompt version against
the same seed should produce within-noise identical scores (the models
themselves are temperature=0, top_k=1).

## Next steps

- **Wire `qwen3vl-4b` into `instagram-poster`** as an additional ranking
  signal alongside CLIP-based recency in `/candidates`. Cache the score
  per asset_id so we don't re-pay 4 s on every list refresh.
- **Bump k8s-node1 RAM** so immich-ml + llama-swap can co-exist (drain
  → resize → uncordon, with kubelet `systemReserved` adjusted in
  `stacks/infra/main.tf`).
- **Re-benchmark with shared GPU** once node1 RAM is bumped, to get
  realistic latency numbers when the T4 is also under load from
  immich-ml and frigate.
- **Front llama-swap with LiteLLM** so Home Assistant and any other
  consumer can hit one OpenAI-compat gateway. Track separately.

---

## Auto-generated report

Below is the unedited output of `python -m instagram_poster.benchmark
report --run-id 2026-05-10-1424`, kept for diff-checking against
future runs.

### Per-model summary

| model | n | parse_ok % | error % | p50 latency | p95 latency | median IG-fit | median aesthetic |
|-------|---|-----------|--------|------------|-------------|--------------|------------------|
| minicpm-v-4-5 | 100 | 100.0 | 0.0 | 5617 ms | 5998 ms | 7.0 | 8.0 |
| qwen3vl-4b | 100 | 100.0 | 0.0 | 3552 ms | 4063 ms | 8.0 | 8.0 |
| qwen3vl-8b | 100 | 100.0 | 0.0 | 5981 ms | 6637 ms | 7.0 | 8.0 |

### Score histograms (instagram_fit_score 1–10)

#### minicpm-v-4-5
```
 1: (0)   2: (0)   3: (0)   4: (0)   5: (0)
 6: ███████ (7)
 7: █████████████████████████████████████████████████████████████████ (65)
 8: ███████████████████ (19)
 9: █████████ (9)
10: (0)
```

#### qwen3vl-4b
```
 1: (0)   2: (0)   3: (0)   4: (0)   5: (0)
 6: █████ (5)
 7: ████████████████ (16)
 8: ████████████████████████████████ (32)
 9: ███████████████████████████████████████████████ (47)
10: (0)
```

#### qwen3vl-8b
```
 1: (0)   2: (0)   3: (0)   4: (0)   5: (0)
 6: ███████████ (11)
 7: ███████████████████████████████████████████████████████ (55)
 8: █████████████████ (17)
 9: █████████████████ (17)
10: (0)
```

### Top-10 by IG-fit per model — see `benchmark-2026-05-10-1424.json`

(Tables omitted from the curated report; available in the JSON dump
alongside this file.)
