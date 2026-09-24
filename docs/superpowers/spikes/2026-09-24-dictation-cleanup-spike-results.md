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

(Task 3)

## S2: FoundationModels background rate limiting

(Task 4)
