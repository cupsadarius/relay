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

- Date / machine: 2026-09-24, human run. macOS 27.0, build 26A428. Relay Debug (spike harness) running in the background with Terminal in front (TextEdit was the frontmost app during the run, per the harness's Step 3 instructions).
- Only macOS 27 was tested; no macOS 26.x machine was available for this run.

| OS | paced rateLimited/50 | burst rateLimited/20 | other errors |
|---|---|---|---|
| macOS 27.0 (26A428) | 0/50 | 0/20 | none reported |

- **Decision: ship.** Zero `rateLimited` in both the paced run (50/50 ok) and the burst run (20/20 ok), meeting the `ship` bar (zero paced, ≤5% burst). `AppleFoundationCleanupModelManager.isOfferedInV1 = true`; no "may be skipped in the background" row note is added (Task 23 applies this).
- Caveat: only macOS 27 was exercised. macOS 26.x background rate limiting for FoundationModels remains unverified; if a macOS 26.x-specific regression surfaces post-ship, re-run this spike on that OS.

## Eval: opt-in live model quality (Task 27)

- Date / machine: 2026-09-24, MacBook Pro (Mac16,5, Apple M4 Max, 48 GB), macOS 27.0, Xcode 27.0 (27A266a). `RELAY_CLEANUP_EVAL=1` against the Task 1 Qwen3 snapshots still present at `/tmp/relay-qwen/{0.6b,1.7b}`. The Apple system model was not run (`RELAY_CLEANUP_EVAL_APPLE=1` not set in this pass).

| model | cases | acceptance | reference match | correction application | wrapper/markup | fail-open | already-clean fail-open | cue-negative over-corrections | p50 | p95 | passes bar |
|---|---|---|---|---|---|---|---|---|---|---|---|
| mlx.qwen3-0.6b-4bit | 48 | 87.5% | 10.4% | 0% | 4.2% | 12.5% | 0% | 5 | 112 ms | 204 ms | **false** |
| mlx.qwen3-1.7b-4bit | 48 | 81.25% | 4.2% | 0% | 2.1% | 18.75% | 0% | 5 | 136 ms | 210 ms | **false** |

- Both models fail the §19 bar: the bar requires `correctionApplicationRate >= 0.8` and `cueNegativeOverCorrections == 0`; both models scored `correctionApplicationRate: 0` (no self-correction case produced the reference/acceptable output) and 5 cue-negative over-corrections each (editing text the corpus expects left untouched). Latency is not the problem (p95 well under the 1.5 s bar on this machine).
- Per spec §19/Task 27: a model with `passesBar: false` stays offered in v1 — there is no auto-select or auto-hide on eval results. Both Qwen models remain selectable in Settings; this result is a quality note for a future prompt/model iteration, not a shipping blocker.
- The Apple system model was not evaluated in this pass; re-run with `RELAY_CLEANUP_EVAL_APPLE=1` on a signed build with Apple Intelligence enabled to get comparable numbers for it.
