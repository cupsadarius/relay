#!/usr/bin/env python3
"""Generates RelayTests/Fixtures/DictationCleanup/qwen3-tokenizer-parity.json (spec §21 S1).

usage: python3 scripts/spikes/qwen-tokenizer-fixture.py /tmp/relay-qwen/0.6b OUT.json
"""
import json
import sys

from transformers import AutoTokenizer

STRINGS = [
    "Hello, world.",
    "uh so I think we should um ship it on friday",
    "set the port to 3, no, 4",
    "<|im_start|>system\nClean up the text.<|im_end|>\n",
    "<|im_start|>user\nhello /no_think<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
    "<think>reasoning</think>",
    "<|endoftext|>",
    "func refresh(token: String) -> Bool { return !token.isEmpty }",
    "let userService = AuthService.shared",
    "user_id, account_id, __init__",
    "open src/app.swift I mean src/main.swift",
    "~/Library/Application Support/Relay/Models",
    "./config/app_settings.json and ../build/Debug",
    "run it with --verbose no --quiet -v",
    "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit?blobs=true",
    "www.example.com/docs#setup",
    "bump to v1.2.3-beta, not 2.0.",
    "commit 3b1b176 and 0xFF",
    "we saw 1,000 errors at 50% load",
    "\"quoted text\" and 'single quotes' and don't",
    "“curly quotes” and ‘single curly’",
    "emoji \U0001F389\U0001F680 and flags \U0001F1F7\U0001F1F4",
    "中文测试：你好，世界。",
    "日本語のテキストとカタカナ",
    "한국어 문장입니다",
    "  leading and trailing spaces  ",
    "tabs\tand\nnewlines\r\n",
    "ÄÖÜ äöü ß é è ñ",
    "a" * 200,
    "The quick brown fox jumps over the lazy dog. " * 5,
]


def main() -> None:
    folder, out_path = sys.argv[1], sys.argv[2]
    tok = AutoTokenizer.from_pretrained(folder)
    assert len(STRINGS) == 30
    cases = [{"text": s, "ids": tok.encode(s, add_special_tokens=False)} for s in STRINGS]
    fixture = {
        "tokenizerSHA256": "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
        "transformersVersion": __import__("transformers").__version__,
        "imEndID": tok.convert_tokens_to_ids("<|im_end|>"),
        "cases": cases,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(fixture, f, ensure_ascii=False, indent=1)
        f.write("\n")


if __name__ == "__main__":
    main()
