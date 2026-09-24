# Dictation cleanup spikes — results

Spec: `docs/superpowers/specs/2026-09-24-relay-dictation-cleanup-design.md` §21.

## S1: tokenizer bridge parity

- Date / machine / Xcode: 2026-09-24, MacBook Pro (Mac16,5, Apple M4 Max), macOS 27.0, Xcode 27.0 (27A266a)
- Fixture: `RelayTests/Fixtures/DictationCleanup/qwen3-tokenizer-parity.json` (transformers 4.56.2, tokenizer.json sha256 aeb13307…4492dae4, 30 strings)
- encode mismatches: 0/30
- decode round-trip mismatches: 0/30
- `<|im_end|>` id: 151645 (expected 151645)
- Offline load (Wi-Fi off): pass
- **Decision:** PASS → ArgmaxCore bridge (`ArgmaxTokenizerBridge.swift`)

## S3: MLX cold and warm timing

- Date / machine / Xcode: 2026-09-24, MacBook Pro (Mac16,5, Apple M4 Max, 48 GB), macOS 27.0, Xcode 27.0 (27A266a). This is the only Apple-silicon Mac available in this environment (not necessarily the slowest supported Mac class); numbers here are an upper bound on headroom, not a worst-case measurement. Ambient load during the run: several other processes active (load avg ~5.3, ~46 GB of 48 GB used), so these numbers are conservative (a quieter Mac would likely be faster).
- Two runs; the first includes Metal shader-cache warmup (compiling on first use), the second is representative and used for the decision.

Run 2 (representative):

| Model | load_ms | cold_generation_ms | warm_total p50/p95 (ms) | warm_first p50/p95 (ms) |
|---|---|---|---|---|
| Qwen3 0.6B | 1525 | 149 | 190 / 330 | 31 / 35 |
| Qwen3 1.7B | 1575 | 197 | 182 / 382 | 62 / 74 |

Run 1 (shader warmup run, for reference): 0.6B load_ms=1513 cold_generation_ms=2028 warm_total p50/p95=192/324 warm_first p50/p95=31/41; 1.7B load_ms=1535 cold_generation_ms=196 warm_total p50/p95=181/374 warm_first p50/p95=62/72. (1.7B's cold generation in run 1 is fast because run 1's 0.6B pass already primed the Metal shader cache for the process.)

- **Decision: A** — 0.6B warm p95 (330 ms) ≤ 2.5 s **and** 1.7B warm p95 (382 ms) ≤ 2.5 s. Keep both models, the 2.5 s production budget and the 10-minute idle unload. Both models have wide headroom under the budget on this machine.
- **Cold-load rule:** the 0.6B cold load (~1.5 s) is well under 8 s, so the Test tool's 10 s budget covers load + generation (spec §17); `DictationCleanupTester.budgetIncludesLoad = true` (Task 16).
- §19 quality bar (p95 ≤ 1.5 s on an M1 base) is recorded, not enforced, here: not measured on an M1 base in this environment; the M4 Max numbers above (warm p95 ≤ 382 ms) leave large headroom before that bar, but an M1 base re-check is recommended before shipping.

## S2: FoundationModels background rate limiting

(Task 4)
