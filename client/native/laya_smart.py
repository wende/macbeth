#!/usr/bin/env python3
import json
import os
import sys
import time

import mlx.core as mx
from mlx_lm import load

MODEL_ID = os.environ.get("MACBETH_SMART_MODEL", "mlx-community/Qwen3-Reranker-0.6B-4bit")
BATCH_SIZE = int(os.environ.get("MACBETH_SMART_BATCH_SIZE", "16"))
MAX_LENGTH = int(os.environ.get("MACBETH_SMART_MAX_LENGTH", "2048"))
INSTRUCTION = (
    "Given the user's computer-use goal and one candidate UI element from the current "
    "accessibility tree, score how likely pressing that exact element is to make direct "
    "progress toward the goal. Respect the named application and ancestor/menu path; do "
    "not confuse the requested feature with a similarly named but unrelated control."
)
PREFIX = (
    '<|im_start|>system\nJudge whether the Document meets the requirements based on '
    'the Query and the Instruct provided. Note that the answer can only be "yes" or '
    '"no".<|im_end|>\n<|im_start|>user\n'
)
SUFFIX = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"

model, tokenizer = load(MODEL_ID)
hf_tokenizer = getattr(tokenizer, "_tokenizer", tokenizer)
yes_id = hf_tokenizer.convert_tokens_to_ids("yes")
no_id = hf_tokenizer.convert_tokens_to_ids("no")
prefix_ids = hf_tokenizer.encode(PREFIX, add_special_tokens=False)
suffix_ids = hf_tokenizer.encode(SUFFIX, add_special_tokens=False)
pad_id = hf_tokenizer.pad_token_id or hf_tokenizer.eos_token_id or 0


def encode(query, document, instruction):
    content = f"<Instruct>: {instruction}\n<Query>: {query}\n<Document>: {document}"
    available = MAX_LENGTH - len(prefix_ids) - len(suffix_ids)
    content_ids = hf_tokenizer.encode(content, add_special_tokens=False)[:available]
    return prefix_ids + content_ids + suffix_ids


def score_batch(query, documents, instruction):
    scores = []
    for start in range(0, len(documents), BATCH_SIZE):
        encoded = [encode(query, document, instruction) for document in documents[start:start + BATCH_SIZE]]
        max_length = max(map(len, encoded))
        padded = [ids + [pad_id] * (max_length - len(ids)) for ids in encoded]
        logits = model(mx.array(padded))
        rows = mx.arange(len(encoded))
        positions = mx.array([len(ids) - 1 for ids in encoded])
        final = logits[rows, positions]
        pair = mx.stack([final[:, no_id], final[:, yes_id]], axis=1)
        probabilities = mx.softmax(pair, axis=1)[:, 1]
        mx.eval(probabilities)
        scores.extend(float(score) for score in probabilities.tolist())
    return scores


for line in sys.stdin:
    try:
        request = json.loads(line)
        started = time.perf_counter()
        documents = request["documents"]
        scores = score_batch(request["query"], documents, request.get("instruction", INSTRUCTION))
        ranked = sorted(
            ({"index": index, "score": score} for index, score in enumerate(scores)),
            key=lambda item: item["score"],
            reverse=True,
        )
        print(json.dumps({
            "scores": scores,
            "ranked": ranked,
            "model": MODEL_ID,
            "latencyMs": (time.perf_counter() - started) * 1000,
        }))
    except Exception as error:
        print(json.dumps({"error": str(error)}))
    sys.stdout.flush()
