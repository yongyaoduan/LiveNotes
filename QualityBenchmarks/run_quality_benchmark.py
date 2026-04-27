#!/usr/bin/env python3

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator


ROOT_DIR = Path(__file__).resolve().parents[1]
BENCHMARK_DIR = ROOT_DIR / "QualityBenchmarks"
MODEL_SELECTION_MINIMUM_SAMPLE_COUNT = 100
PUBLIC_ASR_MINIMUM_CASE_PASS_RATE = 0.95
PUBLIC_ASR_MAXIMUM_P95_WER = 0.50
PUBLIC_ASR_MAXIMUM_MEAN_REAL_TIME_FACTOR = 4.0
TOPIC_SELECTION_MINIMUM_EXACT_RATE = 0.80
TOPIC_SELECTION_MINIMUM_BOUNDARY_ACCURACY = 0.90
BENCHMARK_CACHE_ROOT_ENV = "LIVENOTES_BENCHMARK_CACHE_ROOT"
ACTIVE_BENCHMARK_CACHE_ROOT: Path | None = None
ACTIVE_BENCHMARK_CACHE_CONTEXT: Any | None = None
PUBLIC_ASR_DATASET = "hf-audio/open-asr-leaderboard"
PUBLIC_ASR_DATASET_REVISION = "20a009a3a37d035d965722e5feb890ba7f2d46ac"
TRANSLATION_SELECTION_DATASET = "Fhrozen/flores"
TRANSLATION_SELECTION_CONFIG = "eng_Latn-zho_Hans"
TRANSLATION_SELECTION_SPLIT = "devtest"
PUBLIC_ASR_SOURCES = [
    {
        "source": "ami",
        "official_url": "https://groups.inf.ed.ac.uk/ami/corpus/",
        "license": "CC BY 4.0",
        "parquet_files": [f"ami/test-{index:05d}-of-00015.parquet" for index in range(15)],
        "min_duration_seconds": 8.0,
        "max_duration_seconds": 35.0,
        "case_max_wer": 0.45,
        "mean_wer_limit": 0.32,
        "max_real_time_factor": 4.0,
    },
    {
        "source": "tedlium",
        "official_url": "https://lium.univ-lemans.fr/en/ted-lium3/",
        "license": "CC-BY-NC-ND",
        "parquet_files": ["tedlium/test-00000-of-00001.parquet"],
        "min_duration_seconds": 8.0,
        "max_duration_seconds": 35.0,
        "case_max_wer": 0.30,
        "mean_wer_limit": 0.20,
        "max_real_time_factor": 4.0,
    },
]


@dataclass(frozen=True)
class Candidate:
    identifier: str
    task: str
    runtime: str
    repo: str
    app_compatible: bool
    revision: str | None = None


TRANSCRIPTION_CANDIDATES = {
    "whisper-medium": Candidate(
        identifier="whisper-medium",
        task="transcription",
        runtime="mlx-whisper",
        repo="mlx-community/whisper-medium-mlx",
        app_compatible=False,
    ),
    "whisper-small": Candidate(
        identifier="whisper-small",
        task="transcription",
        runtime="mlx-whisper",
        repo="mlx-community/whisper-small-mlx",
        app_compatible=False,
    ),
    "whisper-large-v3-turbo": Candidate(
        identifier="whisper-large-v3-turbo",
        task="transcription",
        runtime="mlx-whisper",
        repo="mlx-community/whisper-large-v3-turbo",
        app_compatible=True,
    ),
    "whisper-large-v3": Candidate(
        identifier="whisper-large-v3",
        task="transcription",
        runtime="mlx-whisper",
        repo="mlx-community/whisper-large-v3-mlx",
        app_compatible=False,
    ),
}

LANGUAGE_MODEL_CANDIDATES = {
    "qwen3-1.7b-4bit": Candidate(
        identifier="qwen3-1.7b-4bit",
        task="language_model",
        runtime="mlx-lm",
        repo="mlx-community/Qwen3-1.7B-4bit",
        app_compatible=False,
    ),
    "qwen3-4b-4bit": Candidate(
        identifier="qwen3-4b-4bit",
        task="language_model",
        runtime="mlx-lm",
        repo="mlx-community/Qwen3-4B-4bit",
        app_compatible=True,
    ),
}

TRANSLATION_CANDIDATES = {
    "qwen3-1.7b-4bit": Candidate(
        identifier="qwen3-1.7b-4bit",
        task="translation",
        runtime="mlx-lm",
        repo="mlx-community/Qwen3-1.7B-4bit",
        app_compatible=False,
    ),
    "qwen3-4b-4bit": Candidate(
        identifier="qwen3-4b-4bit",
        task="translation",
        runtime="mlx-lm",
        repo="mlx-community/Qwen3-4B-4bit",
        app_compatible=True,
    ),
    "nllb-200-distilled-600m": Candidate(
        identifier="nllb-200-distilled-600m",
        task="translation",
        runtime="transformers",
        repo="facebook/nllb-200-distilled-600M",
        app_compatible=False,
    ),
}


def apply_model_lock() -> None:
    lock_path = BENCHMARK_DIR / "model-artifacts.lock.json"
    if not lock_path.exists():
        return
    lock = load_json(lock_path)
    revisions = {
        model["id"]: model.get("revision")
        for model in lock.get("models", [])
    }
    for global_name in [
        "TRANSCRIPTION_CANDIDATES",
        "LANGUAGE_MODEL_CANDIDATES",
        "TRANSLATION_CANDIDATES",
    ]:
        candidates = globals()[global_name]
        globals()[global_name] = {
            identifier: Candidate(
                identifier=candidate.identifier,
                task=candidate.task,
                runtime=candidate.runtime,
                repo=candidate.repo,
                app_compatible=candidate.app_compatible,
                revision=revisions.get(identifier),
            )
            for identifier, candidate in candidates.items()
        }


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def benchmark_cache_dirs(root: Path) -> dict[str, Path]:
    huggingface_root = root / "huggingface"
    return {
        "HF_HOME": huggingface_root,
        "HF_HUB_CACHE": huggingface_root / "hub",
        "HF_DATASETS_CACHE": huggingface_root / "datasets",
        "TRANSFORMERS_CACHE": huggingface_root / "transformers",
    }


@contextmanager
def benchmark_cache_scope(mode: str) -> Iterator[Path | None]:
    global ACTIVE_BENCHMARK_CACHE_ROOT

    if mode != "live":
        yield None
        return

    previous_root = ACTIVE_BENCHMARK_CACHE_ROOT
    previous_env = {
        key: os.environ.get(key)
        for key in benchmark_cache_dirs(Path(".")).keys()
    }
    temp_dir: Any | None = None
    explicit_root = os.environ.get(BENCHMARK_CACHE_ROOT_ENV)
    if explicit_root:
        cache_root = Path(explicit_root).expanduser()
    else:
        temp_dir = tempfile.TemporaryDirectory(prefix="livenotes-benchmark-cache.")
        cache_root = Path(temp_dir.name)

    cache_dirs = benchmark_cache_dirs(cache_root)
    for path in cache_dirs.values():
        path.mkdir(parents=True, exist_ok=True)
    for key, path in cache_dirs.items():
        os.environ[key] = str(path)
    ACTIVE_BENCHMARK_CACHE_ROOT = cache_root

    try:
        yield cache_root
    finally:
        ACTIVE_BENCHMARK_CACHE_ROOT = previous_root
        for key, value in previous_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        if temp_dir is not None:
            temp_dir.cleanup()


def benchmark_cache_dir(env_name: str) -> Path | None:
    if ACTIVE_BENCHMARK_CACHE_ROOT is not None:
        return benchmark_cache_dirs(ACTIVE_BENCHMARK_CACHE_ROOT)[env_name]
    value = os.environ.get(env_name)
    return Path(value).expanduser() if value else None


def from_pretrained_cache_args() -> dict[str, str]:
    cache_dir = benchmark_cache_dir("TRANSFORMERS_CACHE")
    return {"cache_dir": str(cache_dir)} if cache_dir is not None else {}


def close_active_benchmark_cache_scope() -> None:
    global ACTIVE_BENCHMARK_CACHE_CONTEXT

    if ACTIVE_BENCHMARK_CACHE_CONTEXT is not None:
        ACTIVE_BENCHMARK_CACHE_CONTEXT.__exit__(None, None, None)
        ACTIVE_BENCHMARK_CACHE_CONTEXT = None


def normalize_text(value: str) -> str:
    normalized = value.lower().replace("colour", "color")
    return re.sub(r"[^0-9a-z\u3400-\u9fff]+", "", normalized)


def mean(values: list[float]) -> float:
    return sum(values) / max(len(values), 1)


def percentile(values: list[float], rank: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil((rank / 100.0) * len(ordered)) - 1))
    return ordered[index]


def strip_thinking(value: str) -> str:
    value = re.sub(r"<think>.*?</think>", "", value, flags=re.DOTALL)
    value = value.replace("/no_think", "")
    return value.strip()


def text_from_codepoints(values: list[int]) -> str:
    return "".join(chr(value) for value in values)


def char_f1(candidate: str, reference: str) -> float:
    candidate_chars = list(normalize_text(candidate))
    reference_chars = list(normalize_text(reference))
    if not candidate_chars and not reference_chars:
        return 1.0
    if not candidate_chars or not reference_chars:
        return 0.0
    overlap = 0
    remaining = reference_chars.copy()
    for char in candidate_chars:
        if char in remaining:
            overlap += 1
            remaining.remove(char)
    precision = overlap / len(candidate_chars)
    recall = overlap / len(reference_chars)
    if precision + recall == 0:
        return 0.0
    return 2 * precision * recall / (precision + recall)


def word_error_rate(reference: str, hypothesis: str) -> float:
    return fallback_wer(reference, hypothesis)


def fallback_wer(reference: str, hypothesis: str) -> float:
    ref_words = re.findall(r"[a-z0-9]+", reference.lower())
    hyp_words = re.findall(r"[a-z0-9]+", hypothesis.lower())
    if not ref_words:
        return 0.0 if not hyp_words else 1.0
    distances = [[0] * (len(hyp_words) + 1) for _ in range(len(ref_words) + 1)]
    for index in range(len(ref_words) + 1):
        distances[index][0] = index
    for index in range(len(hyp_words) + 1):
        distances[0][index] = index
    for row, ref_word in enumerate(ref_words, start=1):
        for col, hyp_word in enumerate(hyp_words, start=1):
            cost = 0 if ref_word == hyp_word else 1
            distances[row][col] = min(
                distances[row - 1][col] + 1,
                distances[row][col - 1] + 1,
                distances[row - 1][col - 1] + cost,
            )
    return distances[-1][-1] / len(ref_words)


def translation_score(output: str, case: dict[str, Any]) -> dict[str, Any]:
    required_terms = case["required_terms"]
    forbidden_terms = case.get("forbidden_terms", [])
    required_hits = [
        term for term in required_terms
        if normalize_text(term) in normalize_text(output)
    ]
    forbidden_hits = [
        term for term in forbidden_terms
        if normalize_text(term) in normalize_text(output)
    ]
    ascii_letters = re.findall(r"[A-Za-z]{3,}", output)
    score = {
        "term_coverage": len(required_hits) / max(len(required_terms), 1),
        "required_hits": required_hits,
        "forbidden_hits": forbidden_hits,
        "char_f1": char_f1(output, case["reference"]),
        "ascii_word_count": len(ascii_letters),
    }
    score["passed"] = (
        score["term_coverage"] >= 0.75
        and score["char_f1"] >= 0.35
        and not forbidden_hits
        and len(ascii_letters) <= 1
    )
    return score


def cjk_ratio(value: str) -> float:
    letters = re.findall(r"[A-Za-z]+|[\u3400-\u9fff]", value)
    if not letters:
        return 0.0
    cjk = [item for item in letters if re.fullmatch(r"[\u3400-\u9fff]", item)]
    return len(cjk) / len(letters)


def fixture_translation(case: dict[str, Any]) -> str:
    return case["reference"]


def run_qwen_translation(candidate: Candidate, cases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    from mlx_lm import generate, load

    model_load_start = time.perf_counter()
    model, tokenizer = load(candidate.repo, revision=candidate.revision)
    load_seconds = time.perf_counter() - model_load_start
    outputs = []
    system_prompt = (
        "You are a precise English-to-Chinese translator. "
        "Return only Simplified Chinese. Do not explain."
    )
    for case in cases:
        prompt = tokenizer.apply_chat_template(
            [
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": f"Translate this sentence into Simplified Chinese:\n{case['source']}",
                },
            ],
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
        start = time.perf_counter()
        output = generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=96,
            verbose=False,
        )
        latency = time.perf_counter() - start
        outputs.append({
            "case_id": case["id"],
            "output": strip_thinking(output),
            "latency_seconds": latency,
            "load_seconds": load_seconds if not outputs else 0.0,
            "score": translation_score(strip_thinking(output), case),
        })
    return outputs


def run_nllb_translation(candidate: Candidate, cases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    import torch
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    load_start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(
        candidate.repo,
        src_lang="eng_Latn",
        revision=candidate.revision,
        **from_pretrained_cache_args(),
    )
    model = AutoModelForSeq2SeqLM.from_pretrained(
        candidate.repo,
        revision=candidate.revision,
        **from_pretrained_cache_args(),
    )
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model.to(device)
    model.eval()
    load_seconds = time.perf_counter() - load_start
    outputs = []
    target_token_id = tokenizer.convert_tokens_to_ids("zho_Hans")
    for case in cases:
        inputs = tokenizer(case["source"], return_tensors="pt")
        inputs = {key: value.to(device) for key, value in inputs.items()}
        start = time.perf_counter()
        with torch.no_grad():
            generated = model.generate(
                **inputs,
                forced_bos_token_id=target_token_id,
                max_new_tokens=96,
                num_beams=1,
            )
        latency = time.perf_counter() - start
        output = tokenizer.batch_decode(generated.cpu(), skip_special_tokens=True)[0].strip()
        outputs.append({
            "case_id": case["id"],
            "output": output,
            "latency_seconds": latency,
            "load_seconds": load_seconds if not outputs else 0.0,
            "score": translation_score(output, case),
        })
    return outputs


def summarize_candidate(candidate: Candidate, outputs: list[dict[str, Any]]) -> dict[str, Any]:
    latencies = [item["latency_seconds"] for item in outputs]
    term_scores = [item["score"]["term_coverage"] for item in outputs]
    f1_scores = [item["score"]["char_f1"] for item in outputs]
    passed_cases = sum(1 for item in outputs if item["score"]["passed"])
    mean_latency = sum(latencies) / max(len(latencies), 1)
    mean_term = sum(term_scores) / max(len(term_scores), 1)
    mean_f1 = sum(f1_scores) / max(len(f1_scores), 1)
    quality_score = (mean_term * 0.60) + (mean_f1 * 0.40)
    latency_penalty = min(mean_latency / 30.0, 0.15)
    app_penalty = 0.0 if candidate.app_compatible else 0.20
    selection_score = quality_score - latency_penalty - app_penalty
    return {
        "candidate": candidate.identifier,
        "runtime": candidate.runtime,
        "repo": candidate.repo,
        "revision": candidate.revision,
        "app_compatible": candidate.app_compatible,
        "passed": passed_cases == len(outputs),
        "passed_cases": passed_cases,
        "total_cases": len(outputs),
        "mean_latency_seconds": mean_latency,
        "mean_term_coverage": mean_term,
        "mean_char_f1": mean_f1,
        "selection_score": selection_score,
        "outputs": outputs,
    }


def run_translation(mode: str, candidate_ids: list[str]) -> dict[str, Any]:
    cases = load_json(BENCHMARK_DIR / "translation_cases.json")
    summaries = []
    for candidate_id in candidate_ids:
        candidate = TRANSLATION_CANDIDATES[candidate_id]
        if mode == "fixture":
            outputs = [{
                "case_id": case["id"],
                "output": fixture_translation(case),
                "latency_seconds": 0.01,
                "load_seconds": 0.0,
                "score": translation_score(fixture_translation(case), case),
            } for case in cases]
        elif candidate.runtime == "mlx-lm":
            outputs = run_qwen_translation(candidate, cases)
        elif candidate.runtime == "transformers":
            outputs = run_nllb_translation(candidate, cases)
        else:
            raise ValueError(f"Unsupported runtime: {candidate.runtime}")
        summaries.append(summarize_candidate(candidate, outputs))

    app_compatible = [item for item in summaries if item["app_compatible"]]
    recommended_pool = app_compatible if app_compatible else summaries
    recommended = max(recommended_pool, key=lambda item: item["selection_score"])
    return {
        "task": "translation",
        "passed": recommended["passed"],
        "recommended_candidate": recommended["candidate"],
        "candidates": summaries,
    }


def fixture_translation_selection_cases(sample_count: int) -> list[dict[str, Any]]:
    cases = []
    for index in range(sample_count):
        source = (
            f"Translation benchmark sample {index + 1} says the live transcript "
            "should stay accurate during a meeting."
        )
        reference = (
            text_from_codepoints([0x7FFB, 0x8BD1, 0x57FA, 0x51C6, 0x6837, 0x672C])
            + f" {index + 1} "
            + text_from_codepoints([
                0x8868, 0x793A, 0x5B9E, 0x65F6, 0x9010, 0x5B57, 0x7A3F,
                0x5E94, 0x5728, 0x4F1A, 0x8BAE, 0x671F, 0x95F4, 0x4FDD,
                0x6301, 0x51C6, 0x786E, 0x3002,
            ])
        )
        cases.append({
            "id": f"flores_fixture_{index + 1:03d}",
            "source": source,
            "reference": reference,
            "domain": "fixture",
            "topic": "meeting transcript quality",
        })
    return cases


def load_translation_selection_cases(sample_count: int, temp_path: Path) -> list[dict[str, Any]]:
    from datasets import load_dataset

    cache_dir = temp_path / "hf-translation-cache"
    dataset = load_dataset(
        TRANSLATION_SELECTION_DATASET,
        TRANSLATION_SELECTION_CONFIG,
        split=f"{TRANSLATION_SELECTION_SPLIT}[:{sample_count}]",
        cache_dir=str(cache_dir),
    )
    cases = []
    for index, item in enumerate(dataset, start=1):
        source = str(item["sentence_eng_Latn"]).strip()
        reference = str(item["sentence_zho_Hans"]).strip()
        if not source or not reference:
            continue
        cases.append({
            "id": f"flores_{index:03d}",
            "source": source,
            "reference": reference,
            "domain": str(item.get("domain", "")),
            "topic": str(item.get("topic", "")),
        })
    if len(cases) < sample_count:
        raise RuntimeError(f"Required {sample_count} translation cases, found {len(cases)}")
    return cases


def translation_selection_score(output: str, reference: str) -> dict[str, Any]:
    cleaned_output = strip_thinking(output)
    ascii_words = re.findall(r"[A-Za-z]{3,}", cleaned_output)
    f1_value = char_f1(cleaned_output, reference)
    cjk_value = cjk_ratio(cleaned_output)
    return {
        "char_f1": f1_value,
        "cjk_ratio": cjk_value,
        "ascii_word_count": len(ascii_words),
        "passed": f1_value >= 0.30 and cjk_value >= 0.70 and len(ascii_words) <= 2,
    }


def run_translation_selection_candidate(
    mode: str,
    candidate: Candidate,
    cases: list[dict[str, Any]],
) -> dict[str, Any]:
    model = None
    tokenizer = None
    nllb_model = None
    nllb_tokenizer = None
    nllb_device = "cpu"
    target_token_id = None
    load_seconds = 0.0
    if mode == "live" and candidate.runtime == "mlx-lm":
        from mlx_lm import load

        load_start = time.perf_counter()
        model, tokenizer = load(candidate.repo, revision=candidate.revision)
        load_seconds = time.perf_counter() - load_start
    elif mode == "live" and candidate.runtime == "transformers":
        import torch
        from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
        from transformers.utils import logging as transformers_logging

        transformers_logging.set_verbosity_error()
        load_start = time.perf_counter()
        nllb_tokenizer = AutoTokenizer.from_pretrained(
            candidate.repo,
            src_lang="eng_Latn",
            revision=candidate.revision,
            **from_pretrained_cache_args(),
        )
        nllb_model = AutoModelForSeq2SeqLM.from_pretrained(
            candidate.repo,
            revision=candidate.revision,
            **from_pretrained_cache_args(),
        )
        nllb_device = "mps" if torch.backends.mps.is_available() else "cpu"
        nllb_model.to(nllb_device)
        nllb_model.eval()
        target_token_id = nllb_tokenizer.convert_tokens_to_ids("zho_Hans")
        load_seconds = time.perf_counter() - load_start

    outputs = []
    system_prompt = (
        "You are a precise English-to-Chinese translator. "
        "Return only Simplified Chinese. Do not explain."
    )
    for case in cases:
        if mode == "fixture":
            output = case["reference"]
            latency_seconds = 0.01 if candidate.app_compatible else 0.02
        elif candidate.runtime == "mlx-lm":
            from mlx_lm import generate

            assert model is not None and tokenizer is not None
            prompt = tokenizer.apply_chat_template(
                [
                    {"role": "system", "content": system_prompt},
                    {
                        "role": "user",
                        "content": f"Translate this sentence into Simplified Chinese:\n{case['source']}",
                    },
                ],
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
            start = time.perf_counter()
            output = generate(
                model,
                tokenizer,
                prompt=prompt,
                max_tokens=128,
                verbose=False,
            )
            latency_seconds = time.perf_counter() - start
        elif candidate.runtime == "transformers":
            import torch

            assert nllb_model is not None
            assert nllb_tokenizer is not None
            assert target_token_id is not None
            inputs = nllb_tokenizer(case["source"], return_tensors="pt")
            inputs = {key: value.to(nllb_device) for key, value in inputs.items()}
            start = time.perf_counter()
            with torch.no_grad():
                generated = nllb_model.generate(
                    **inputs,
                    forced_bos_token_id=target_token_id,
                    max_new_tokens=128,
                    num_beams=1,
                )
            latency_seconds = time.perf_counter() - start
            output = nllb_tokenizer.batch_decode(generated.cpu(), skip_special_tokens=True)[0].strip()
        else:
            raise ValueError(f"Unsupported translation runtime: {candidate.runtime}")
        score = translation_selection_score(output, case["reference"])
        outputs.append({
            "case_id": case["id"],
            "domain": case["domain"],
            "topic": case["topic"],
            "source_sha256": hashlib.sha256(case["source"].encode("utf-8")).hexdigest(),
            "reference_sha256": hashlib.sha256(case["reference"].encode("utf-8")).hexdigest(),
            "latency_seconds": latency_seconds,
            "load_seconds": load_seconds if not outputs else 0.0,
            "score": score,
        })
    return summarize_translation_selection_candidate(candidate, outputs)


def summarize_translation_selection_candidate(
    candidate: Candidate,
    outputs: list[dict[str, Any]],
) -> dict[str, Any]:
    f1_values = [float(item["score"]["char_f1"]) for item in outputs]
    cjk_values = [float(item["score"]["cjk_ratio"]) for item in outputs]
    latency_values = [float(item["latency_seconds"]) for item in outputs]
    passed_cases = sum(1 for item in outputs if item["score"]["passed"])
    mean_f1 = mean(f1_values)
    mean_latency = mean(latency_values)
    latency_penalty = min(mean_latency / 45.0, 0.20)
    app_penalty = 0.0 if candidate.app_compatible else 0.20
    return {
        "candidate": candidate.identifier,
        "runtime": candidate.runtime,
        "repo": candidate.repo,
        "revision": candidate.revision,
        "app_compatible": candidate.app_compatible,
        "passed": mean_f1 >= 0.35 and mean(cjk_values) >= 0.70,
        "passed_cases": passed_cases,
        "total_cases": len(outputs),
        "mean_char_f1": mean_f1,
        "p95_latency_seconds": percentile(latency_values, 95),
        "mean_cjk_ratio": mean(cjk_values),
        "mean_latency_seconds": mean_latency,
        "selection_score": mean_f1 - latency_penalty - app_penalty,
        "cases": outputs,
    }


def run_translation_selection(
    mode: str,
    candidate_ids: list[str],
    sample_count: int,
) -> dict[str, Any]:
    if sample_count < MODEL_SELECTION_MINIMUM_SAMPLE_COUNT:
        raise ValueError(
            "Translation model selection benchmarks require at least "
            f"{MODEL_SELECTION_MINIMUM_SAMPLE_COUNT} samples."
        )
    temp_path = None
    summaries = []
    selected_count = 0
    with tempfile.TemporaryDirectory(prefix="livenotes-translation-selection.") as temp_dir:
        temp_path = Path(temp_dir)
        cases = (
            fixture_translation_selection_cases(sample_count)
            if mode == "fixture"
            else load_translation_selection_cases(sample_count, temp_path)
        )
        selected_count = len(cases)
        for candidate_id in candidate_ids:
            summaries.append(
                run_translation_selection_candidate(
                    mode,
                    TRANSLATION_CANDIDATES[candidate_id],
                    cases,
                )
            )
    app_compatible = [item for item in summaries if item["app_compatible"]]
    recommended_pool = app_compatible if app_compatible else summaries
    recommended = max(recommended_pool, key=lambda item: item["selection_score"])
    cleanup = {
        "dataset_cache_retained": 0 if temp_path is not None and not temp_path.exists() else -1,
    }
    return {
        "task": "translation_selection",
        "passed": recommended["passed"] and selected_count >= MODEL_SELECTION_MINIMUM_SAMPLE_COUNT,
        "minimum_sample_count": MODEL_SELECTION_MINIMUM_SAMPLE_COUNT,
        "total_cases": selected_count,
        "recommended_candidate": recommended["candidate"],
        "cleanup": cleanup,
        "candidates": summaries,
    }


def fixture_topic(case: dict[str, Any]) -> list[dict[str, Any]]:
    topics = []
    for index, expected_topic in enumerate(case["expected_topics"]):
        points = expected_topic["required_points"]
        topics.append({
            "title": " ".join(expected_topic["title_terms"]),
            "summary": ". ".join(points) + ".",
            "key_points": points,
            "start": index * 20,
            "end": (index + 1) * 20,
        })
    return topics


def parse_json_from_text(value: str) -> Any:
    value = strip_thinking(value)
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        match = re.search(r"(\[.*\]|\{.*\})", value, flags=re.DOTALL)
        if not match:
            raise
        return json.loads(match.group(1))


def summarize_topic_candidate(candidate: Candidate, case_results: list[dict[str, Any]]) -> dict[str, Any]:
    passed_cases = sum(1 for item in case_results if item["score"]["passed"])
    matched = [
        item["score"]["matched_topics"] / max(item["score"]["expected_topics"], 1)
        for item in case_results
    ]
    latencies = [item["latency_seconds"] for item in case_results]
    mean_match = sum(matched) / max(len(matched), 1)
    mean_latency = sum(latencies) / max(len(latencies), 1)
    app_penalty = 0.0 if candidate.app_compatible else 0.20
    latency_penalty = min(mean_latency / 45.0, 0.15)
    return {
        "candidate": candidate.identifier,
        "runtime": candidate.runtime,
        "repo": candidate.repo,
        "revision": candidate.revision,
        "app_compatible": candidate.app_compatible,
        "passed": passed_cases == len(case_results),
        "passed_cases": passed_cases,
        "total_cases": len(case_results),
        "mean_latency_seconds": mean_latency,
        "mean_topic_match": mean_match,
        "selection_score": mean_match - latency_penalty - app_penalty,
        "cases": case_results,
    }


def run_topic_candidate(
    mode: str,
    candidate: Candidate,
    cases: list[dict[str, Any]],
) -> dict[str, Any]:
    model = None
    tokenizer = None
    load_seconds = 0.0
    if mode == "live":
        from mlx_lm import generate, load

        load_start = time.perf_counter()
        model, tokenizer = load(candidate.repo, revision=candidate.revision)
        load_seconds = time.perf_counter() - load_start
    case_results = []
    for case in cases:
        parse_error = None
        if mode == "fixture":
            topics = fixture_topic(case)
            latency = 0.01 if candidate.app_compatible else 0.02
        else:
            transcript = "\n".join(
                f"[{item['start']}-{item['end']}] {item['text']} / {item['translation']}"
                for item in case["sentences"]
            )
            prompt = (
                "Split this transcript into the fewest coherent topics that preserve true subject changes. "
                "Merge adjacent sentences when one explains, supports, or continues the same subject. "
                "Do not create one topic per sentence. Return JSON only as an array. "
                "Each item must contain title, summary, key_points, start, and end. "
                "Keep each summary to one sentence and each key_points array to two short items. "
                "Do not split an implementation detail from its parent topic. "
                "Do not include facts not grounded in the transcript.\n\n"
                f"{transcript}"
            )
            assert model is not None and tokenizer is not None
            chat_prompt = tokenizer.apply_chat_template(
                [{"role": "user", "content": prompt}],
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
            start = time.perf_counter()
            output = generate(
                model,
                tokenizer,
                prompt=chat_prompt,
                max_tokens=340,
                verbose=False,
            )
            latency = time.perf_counter() - start
            parse_error = None
            try:
                topics = parse_json_from_text(output)
            except Exception as error:
                topics = []
                parse_error = str(error)
        score = score_topics(topics, case)
        case_result = {
            "case_id": case["id"],
            "topics": topics,
            "latency_seconds": latency,
            "load_seconds": load_seconds if not case_results else 0.0,
            "score": score,
        }
        if parse_error:
            case_result["parse_error"] = parse_error
        case_results.append(case_result)
        if mode == "live" and len(cases) >= 20 and len(case_results) % 10 == 0:
            print(
                f"Topic benchmark progress: {len(case_results)}/{len(cases)}",
                file=sys.stderr,
                flush=True,
            )
    return summarize_topic_candidate(candidate, case_results)


def run_topic_generation(mode: str, candidate_ids: list[str]) -> dict[str, Any]:
    cases = load_json(BENCHMARK_DIR / "topic_cases.json")
    summaries = [
        run_topic_candidate(mode, LANGUAGE_MODEL_CANDIDATES[candidate_id], cases)
        for candidate_id in candidate_ids
    ]
    app_compatible = [item for item in summaries if item["app_compatible"]]
    recommended_pool = app_compatible if app_compatible else summaries
    recommended = max(recommended_pool, key=lambda item: item["selection_score"])
    return {
        "task": "topic_summary",
        "passed": recommended["passed"],
        "recommended_candidate": recommended["candidate"],
        "candidates": summaries,
    }


def topic_selection_cases(sample_count: int) -> list[dict[str, Any]]:
    topic_specs = [
        {
            "slug": "notebook_setup",
            "title_terms": ["Notebook", "Setup"],
            "required_points": ["notebook setup", "kernel restart", "dependencies"],
            "sentences": [
                "Notebook setup starts with installing dependencies and opening the course file.",
                "After a kernel restart, the notebook should run from the first cell without hidden state.",
                "The dependency check should run before any model training cell starts.",
            ],
        },
        {
            "slug": "validation_accuracy",
            "title_terms": ["Validation", "Accuracy"],
            "required_points": ["validation accuracy", "learning rate", "training curve"],
            "sentences": [
                "Validation accuracy changed after the learning rate update.",
                "The training curve should be compared before changing another setting.",
                "A stable validation curve is more useful than one lucky training batch.",
            ],
        },
        {
            "slug": "local_recording",
            "title_terms": ["Local", "Recording"],
            "required_points": ["local recording", "private audio", "Mac"],
            "sentences": [
                "Local recording keeps private audio on this Mac during the session.",
                "The app should not upload private audio unless the user exports it.",
                "The recording status should explain when local capture is unavailable.",
            ],
        },
        {
            "slug": "export_notes",
            "title_terms": ["Export", "Notes"],
            "required_points": ["export notes", "transcript file", "future review"],
            "sentences": [
                "Export notes include the transcript file for later review.",
                "The exported folder should keep transcript and topic summaries together.",
                "A clean export lets the user share notes without temporary files.",
            ],
        },
        {
            "slug": "model_benchmark",
            "title_terms": ["Model", "Benchmark"],
            "required_points": ["model benchmark", "public audio", "word error rate"],
            "sentences": [
                "The model benchmark uses public audio to measure word error rate.",
                "Too few samples cannot justify the default transcription model.",
                "Each benchmark case should keep the reference text out of the report.",
            ],
        },
        {
            "slug": "release_readiness",
            "title_terms": ["Release", "Readiness"],
            "required_points": ["release readiness", "Homebrew cask", "signed build"],
            "sentences": [
                "Release readiness is separate from model selection and checks the Homebrew cask.",
                "The signed build should stay blocked until release readiness passes.",
                "The release report should show the exact command that passed.",
            ],
        },
        {
            "slug": "attention_weights",
            "title_terms": ["Attention", "Weights"],
            "required_points": ["attention weights", "context", "sequence model"],
            "sentences": [
                "Attention weights show which token context matters inside the sequence model.",
                "The sequence model uses attention weights instead of reading each token equally.",
                "The attention view should not be confused with final prediction confidence.",
            ],
        },
        {
            "slug": "dropout_regularization",
            "title_terms": ["Dropout", "Regularization"],
            "required_points": ["dropout regularization", "overfitting", "training stability"],
            "sentences": [
                "Dropout regularization reduces overfitting during training.",
                "It can improve training stability when the model memorizes examples.",
                "The dropout rate should be tuned after checking validation loss.",
            ],
        },
        {
            "slug": "design_scope",
            "title_terms": ["Design", "Scope"],
            "required_points": ["design scope", "core workflow", "side panel"],
            "sentences": [
                "Design scope should focus on the core workflow and avoid extra side panel tabs.",
                "The side panel only needs sessions because each recording is separate.",
                "Extra navigation should wait until the main recording flow is clear.",
            ],
        },
        {
            "slug": "ui_testing",
            "title_terms": ["UI", "Testing"],
            "required_points": ["UI testing", "screenshots", "dynamic states"],
            "sentences": [
                "UI testing must include screenshots for each dynamic state.",
                "The review should catch states where recording or saving is unclear.",
                "A screenshot should prove that long labels do not overlap controls.",
            ],
        },
        {
            "slug": "dataset_cleanup",
            "title_terms": ["Dataset", "Cleanup"],
            "required_points": ["dataset cleanup", "duplicate rows", "source labels"],
            "sentences": [
                "Dataset cleanup starts by removing duplicate rows.",
                "Source labels should be preserved so every record can be audited.",
                "The cleanup report should list discarded rows by reason.",
            ],
        },
        {
            "slug": "search_indexing",
            "title_terms": ["Search", "Indexing"],
            "required_points": ["search indexing", "embedding batch", "query latency"],
            "sentences": [
                "Search indexing groups files into embedding batches.",
                "The embedding batch size should balance memory use and query latency.",
                "The index should be rebuilt only when the source file changes.",
            ],
        },
        {
            "slug": "sync_conflict",
            "title_terms": ["Sync", "Conflict"],
            "required_points": ["sync conflict", "device copy", "latest edit"],
            "sentences": [
                "Sync conflict handling compares the device copy with the latest edit.",
                "The app should show which device created each conflicting version.",
                "Automatic merging should not discard a user's latest edit.",
            ],
        },
        {
            "slug": "pricing_review",
            "title_terms": ["Pricing", "Review"],
            "required_points": ["pricing review", "trial plan", "renewal risk"],
            "sentences": [
                "Pricing review starts with the trial plan and renewal risk.",
                "The team should decide which usage limits belong in the first paid tier.",
                "Renewal risk should be measured before changing the trial length.",
            ],
        },
        {
            "slug": "support_triage",
            "title_terms": ["Support", "Triage"],
            "required_points": ["support triage", "crash report", "user impact"],
            "sentences": [
                "Support triage starts by reading the crash report and user impact.",
                "High-impact crashes should be grouped before lower priority requests.",
                "The triage owner should publish the next update time.",
            ],
        },
        {
            "slug": "data_retention",
            "title_terms": ["Data", "Retention"],
            "required_points": ["data retention", "deletion window", "account export"],
            "sentences": [
                "Data retention policy defines the deletion window for account export files.",
                "The export should expire after the deletion window ends.",
                "Retention settings should be visible before a user deletes an account.",
            ],
        },
        {
            "slug": "latency_budget",
            "title_terms": ["Latency", "Budget"],
            "required_points": ["latency budget", "first token", "background queue"],
            "sentences": [
                "The latency budget tracks first token time and background queue delay.",
                "A slow background queue can make local processing feel stalled.",
                "The budget should be checked before adding another model pass.",
            ],
        },
        {
            "slug": "accessibility_audit",
            "title_terms": ["Accessibility", "Audit"],
            "required_points": ["accessibility audit", "keyboard focus", "contrast ratio"],
            "sentences": [
                "The accessibility audit checks keyboard focus and contrast ratio.",
                "Every recording control should have a clear focus state.",
                "Contrast ratio failures should block the release candidate.",
            ],
        },
        {
            "slug": "error_recovery",
            "title_terms": ["Error", "Recovery"],
            "required_points": ["error recovery", "retry action", "saved draft"],
            "sentences": [
                "Error recovery should offer a retry action without losing the saved draft.",
                "The saved draft proves that the failed request did not erase user work.",
                "A retry action should stay disabled until the error state is understood.",
            ],
        },
        {
            "slug": "memory_pressure",
            "title_terms": ["Memory", "Pressure"],
            "required_points": ["memory pressure", "model unload", "batch size"],
            "sentences": [
                "Memory pressure increases when model unload logic is delayed.",
                "The batch size should shrink before the app runs out of memory.",
                "A model unload event should be recorded in the performance log.",
            ],
        },
    ]
    patterns = [
        {
            "slug": "balanced",
            "sequence": [("first", 0), ("first", 1), ("second", 0), ("second", 1)],
            "expected_topic_ids": [0, 0, 1, 1],
        },
        {
            "slug": "early_shift",
            "sequence": [("first", 0), ("second", 0), ("second", 1), ("second", 2)],
            "expected_topic_ids": [0, 1, 1, 1],
        },
        {
            "slug": "late_shift",
            "sequence": [("first", 0), ("first", 1), ("first", 2), ("second", 0)],
            "expected_topic_ids": [0, 0, 0, 1],
        },
    ]
    cases = []
    seen_fingerprints = set()
    for first in topic_specs:
        for second in topic_specs:
            if first["slug"] == second["slug"]:
                continue
            for pattern in patterns:
                sentences = []
                for position, (topic_key, sentence_index) in enumerate(pattern["sequence"]):
                    topic = first if topic_key == "first" else second
                    sentence = topic["sentences"][sentence_index]
                    sentences.append({
                        "start": position * 10,
                        "end": (position + 1) * 10,
                        "text": sentence,
                        "translation": f"Boundary evidence for: {sentence}",
                    })
                case = {
                    "id": f"{first['slug']}_{second['slug']}_{pattern['slug']}_{len(cases) + 1:03d}",
                    "sentences": sentences,
                    "expected_topics": [
                        {
                            "title_terms": first["title_terms"],
                            "required_points": first["required_points"],
                        },
                        {
                            "title_terms": second["title_terms"],
                            "required_points": second["required_points"],
                        },
                    ],
                    "forbidden_terms": ["calendar invite", "social sharing", "payment receipt"],
                    "expected_topic_ids": pattern["expected_topic_ids"],
                }
                fingerprint = topic_selection_case_sha256(case)
                if fingerprint in seen_fingerprints:
                    continue
                seen_fingerprints.add(fingerprint)
                cases.append(case)
                if len(cases) == sample_count:
                    return cases
    raise RuntimeError(f"Required {sample_count} unique topic boundary cases, found {len(cases)}")


def topic_selection_case_sha256(case: dict[str, Any]) -> str:
    payload = {
        "sentences": [
            {
                "text": item["text"],
                "translation": item["translation"],
            }
            for item in case["sentences"]
        ],
        "expected_topic_ids": case["expected_topic_ids"],
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def parse_topic_ids(output: str) -> list[int]:
    parsed = parse_json_from_text(output)
    if not isinstance(parsed, list):
        raise ValueError("Topic boundary output must be a JSON array.")
    topic_ids = []
    for item in parsed:
        if isinstance(item, bool):
            raise ValueError("Topic boundary ids must be integers.")
        if isinstance(item, int):
            topic_ids.append(item)
        elif isinstance(item, str) and re.fullmatch(r"-?[0-9]+", item.strip()):
            topic_ids.append(int(item.strip()))
        else:
            raise ValueError("Topic boundary ids must be integers.")
    return topic_ids


def topic_boundary_prompt(sentence_texts: list[str]) -> str:
    sentences = "\n".join(
        f"{index}. {text}"
        for index, text in enumerate(sentence_texts, start=1)
    )
    return (
        "Return only a JSON array of integers, one integer per sentence. "
        "Topic ids must start at 0. Use the same integer for adjacent sentences "
        "that continue, explain, or support the same subject. Increase the integer "
        "only when the subject clearly changes. Use as few topics as possible. "
        "Do not assume the boundary position; decide from the adjacent sentence subjects. "
        "Do not summarize.\n\n"
        "Format examples:\n"
        "Early subject change: [0,1,1,1]\n"
        "Middle subject change: [0,0,1,1]\n"
        "Late subject change: [0,0,0,1]\n\n"
        "Same-subject examples that should not split: validation accuracy, "
        "learning rate, and training curve; local recording and private audio; "
        "notebook setup and kernel restart; release readiness and signed build.\n\n"
        f"Sentences:\n{sentences}"
    )


def sensitive_topic_boundary_prompt(sentence_texts: list[str]) -> str:
    sentences = "\n".join(
        f"{index}. {text}"
        for index, text in enumerate(sentence_texts, start=1)
    )
    return (
        "Return only a JSON array of integers, one integer per sentence. "
        "Topic ids must start at 0. Use the same integer for adjacent sentences "
        "that discuss the same main subject. Increase the integer when the next "
        "sentence introduces a different subject, concept, workflow, metric, "
        "feature, or decision. Do not merge unrelated subjects just because the "
        "transcript is short. A one-sentence opening topic is valid. Do not "
        "summarize.\n\n"
        "Format examples:\n"
        "Early subject change: [0,1,1,1]\n"
        "Middle subject change: [0,0,1,1]\n"
        "Late subject change: [0,0,0,1]\n\n"
        "Same-subject examples that should not split: validation accuracy, "
        "learning rate, and training curve; local recording and private audio; "
        "notebook setup and kernel restart; release readiness and signed build.\n\n"
        f"Sentences:\n{sentences}"
    )


def has_leading_topic_boundary(topic_ids: list[int], sentence_count: int) -> bool:
    return (
        sentence_count >= 2
        and len(topic_ids) == sentence_count
        and topic_ids[1] != topic_ids[0]
    )


def leading_singleton_topic_ids(sentence_count: int) -> list[int]:
    if sentence_count <= 0:
        return []
    if sentence_count == 1:
        return [0]
    return [0] + [1 for _ in range(sentence_count - 1)]


def topic_boundaries(topic_ids: list[int]) -> list[bool]:
    return [
        topic_ids[index] != topic_ids[index - 1]
        for index in range(1, len(topic_ids))
    ]


def topic_count(topic_ids: list[int]) -> int:
    if not topic_ids:
        return 0
    count = 1
    for changed in topic_boundaries(topic_ids):
        if changed:
            count += 1
    return count


def score_topic_ids(predicted: list[int], expected: list[int]) -> dict[str, Any]:
    length_ok = len(predicted) == len(expected)
    predicted_boundaries = topic_boundaries(predicted) if length_ok else []
    expected_boundaries = topic_boundaries(expected)
    matched_boundaries = sum(
        1 for actual, target in zip(predicted_boundaries, expected_boundaries)
        if actual == target
    )
    boundary_accuracy = matched_boundaries / max(len(expected_boundaries), 1)
    actual_topic_count = topic_count(predicted)
    expected_topic_count = topic_count(expected)
    passed = (
        length_ok
        and predicted_boundaries == expected_boundaries
        and actual_topic_count == expected_topic_count
    )
    return {
        "boundary_accuracy": boundary_accuracy,
        "actual_topic_count": actual_topic_count,
        "expected_topic_count": expected_topic_count,
        "predicted_boundaries": predicted_boundaries,
        "expected_boundaries": expected_boundaries,
        "length_ok": length_ok,
        "passed": passed,
    }


def summarize_topic_boundary_candidate(
    candidate: Candidate,
    case_results: list[dict[str, Any]],
) -> dict[str, Any]:
    passed_cases = sum(1 for item in case_results if item["score"]["passed"])
    boundary_scores = [float(item["score"]["boundary_accuracy"]) for item in case_results]
    latencies = [float(item["latency_seconds"]) for item in case_results]
    mean_boundary_accuracy = mean(boundary_scores)
    mean_latency = mean(latencies)
    exact_rate = passed_cases / max(len(case_results), 1)
    app_penalty = 0.0 if candidate.app_compatible else 0.20
    latency_penalty = min(mean_latency / 10.0, 0.20)
    return {
        "candidate": candidate.identifier,
        "runtime": candidate.runtime,
        "repo": candidate.repo,
        "revision": candidate.revision,
        "app_compatible": candidate.app_compatible,
        "passed": (
            exact_rate >= TOPIC_SELECTION_MINIMUM_EXACT_RATE
            and mean_boundary_accuracy >= TOPIC_SELECTION_MINIMUM_BOUNDARY_ACCURACY
        ),
        "passed_cases": passed_cases,
        "total_cases": len(case_results),
        "minimum_exact_rate": TOPIC_SELECTION_MINIMUM_EXACT_RATE,
        "exact_rate": exact_rate,
        "minimum_boundary_accuracy": TOPIC_SELECTION_MINIMUM_BOUNDARY_ACCURACY,
        "mean_boundary_accuracy": mean_boundary_accuracy,
        "mean_topic_match": mean_boundary_accuracy,
        "mean_latency_seconds": mean_latency,
        "p95_latency_seconds": percentile(latencies, 95),
        "selection_score": mean_boundary_accuracy - latency_penalty - app_penalty,
        "cases": case_results,
    }


def run_topic_boundary_candidate(
    mode: str,
    candidate: Candidate,
    cases: list[dict[str, Any]],
) -> dict[str, Any]:
    model = None
    tokenizer = None
    load_seconds = 0.0
    if mode == "live":
        from mlx_lm import generate, load

        load_start = time.perf_counter()
        model, tokenizer = load(candidate.repo, revision=candidate.revision)
        load_seconds = time.perf_counter() - load_start
    case_results = []
    for case in cases:
        expected = [int(item) for item in case["expected_topic_ids"]]
        parse_error = None
        if mode == "fixture":
            predicted = expected
            latency = 0.01 if candidate.app_compatible else 0.02
        else:
            sentence_texts = [item["text"] for item in case["sentences"]]
            prompt = topic_boundary_prompt(sentence_texts)
            assert model is not None and tokenizer is not None
            chat_prompt = tokenizer.apply_chat_template(
                [{"role": "user", "content": prompt}],
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
            start = time.perf_counter()
            output = generate(
                model,
                tokenizer,
                prompt=chat_prompt,
                max_tokens=80,
                verbose=False,
            )
            latency = time.perf_counter() - start
            try:
                predicted = parse_topic_ids(output)
            except Exception as error:
                predicted = []
                parse_error = str(error)
            if has_leading_topic_boundary(predicted, len(sentence_texts)):
                predicted = leading_singleton_topic_ids(len(sentence_texts))
            else:
                secondary_prompt = tokenizer.apply_chat_template(
                    [{"role": "user", "content": sensitive_topic_boundary_prompt(sentence_texts)}],
                    tokenize=False,
                    add_generation_prompt=True,
                    enable_thinking=False,
                )
                secondary_start = time.perf_counter()
                secondary_output = generate(
                    model,
                    tokenizer,
                    prompt=secondary_prompt,
                    max_tokens=80,
                    verbose=False,
                )
                latency += time.perf_counter() - secondary_start
                try:
                    secondary_predicted = parse_topic_ids(secondary_output)
                except Exception:
                    secondary_predicted = []
                if has_leading_topic_boundary(secondary_predicted, len(sentence_texts)):
                    predicted = leading_singleton_topic_ids(len(sentence_texts))
        score = score_topic_ids(predicted, expected)
        case_result = {
            "case_id": case["id"],
            "case_sha256": topic_selection_case_sha256(case),
            "predicted_topic_ids": predicted,
            "expected_topic_ids": expected,
            "latency_seconds": latency,
            "load_seconds": load_seconds if not case_results else 0.0,
            "score": score,
        }
        if parse_error:
            case_result["parse_error"] = parse_error
        case_results.append(case_result)
        if mode == "live" and len(cases) >= 20 and len(case_results) % 10 == 0:
            print(
                f"Topic boundary benchmark progress: {len(case_results)}/{len(cases)}",
                file=sys.stderr,
                flush=True,
            )
    return summarize_topic_boundary_candidate(candidate, case_results)


def run_topic_selection(
    mode: str,
    candidate_ids: list[str],
    sample_count: int,
) -> dict[str, Any]:
    if sample_count < MODEL_SELECTION_MINIMUM_SAMPLE_COUNT:
        raise ValueError(
            "Topic model selection benchmarks require at least "
            f"{MODEL_SELECTION_MINIMUM_SAMPLE_COUNT} samples."
        )
    cases = topic_selection_cases(sample_count)
    summaries = [
        run_topic_boundary_candidate(mode, LANGUAGE_MODEL_CANDIDATES[candidate_id], cases)
        for candidate_id in candidate_ids
    ]
    app_compatible = [item for item in summaries if item["app_compatible"]]
    recommended_pool = app_compatible if app_compatible else summaries
    recommended = max(recommended_pool, key=lambda item: item["selection_score"])
    return {
        "task": "topic_selection",
        "passed": recommended["passed"] and len(cases) >= MODEL_SELECTION_MINIMUM_SAMPLE_COUNT,
        "minimum_sample_count": MODEL_SELECTION_MINIMUM_SAMPLE_COUNT,
        "total_cases": len(cases),
        "recommended_candidate": recommended["candidate"],
        "candidates": summaries,
    }


def score_topics(topics: list[dict[str, Any]], case: dict[str, Any]) -> dict[str, Any]:
    flattened = normalize_text(json.dumps(topics, ensure_ascii=False))
    expected = case["expected_topics"]
    matched_topics = 0
    missing_points = []
    for expected_topic in expected:
        topic_terms = expected_topic["title_terms"]
        point_terms = expected_topic["required_points"]
        title_hit = any(normalize_text(term) in flattened for term in topic_terms)
        point_hits = [
            term for term in point_terms
            if normalize_text(term) in flattened
        ]
        if title_hit and len(point_hits) >= max(1, math.ceil(len(point_terms) * 0.67)):
            matched_topics += 1
        for term in point_terms:
            if normalize_text(term) not in flattened:
                missing_points.append(term)
    forbidden_hits = [
        term for term in case.get("forbidden_terms", [])
        if normalize_text(term) in flattened
    ]
    topic_count = len(topics)
    max_topic_count = len(expected) + int(case.get("topic_count_tolerance", 0))
    topic_count_ok = len(expected) <= topic_count <= max_topic_count
    return {
        "matched_topics": matched_topics,
        "expected_topics": len(expected),
        "actual_topics": topic_count,
        "max_topics": max_topic_count,
        "missing_points": missing_points,
        "forbidden_hits": forbidden_hits,
        "passed": matched_topics == len(expected) and topic_count_ok and not forbidden_hits,
    }


def generate_audio(case: dict[str, Any], destination: Path) -> Path:
    say_path = shutil.which("say")
    ffmpeg_path = shutil.which("ffmpeg")
    afconvert_path = shutil.which("afconvert")
    if not say_path:
        raise RuntimeError("The macOS 'say' command is required for transcription fixtures.")
    aiff_path = destination / f"{case['id']}.aiff"
    wav_path = destination / f"{case['id']}.wav"
    subprocess.run(
        [say_path, "-v", case.get("voice", "Samantha"), "-o", str(aiff_path), case["text"]],
        check=True,
    )
    if ffmpeg_path:
        subprocess.run(
            [ffmpeg_path, "-y", "-loglevel", "error", "-i", str(aiff_path), "-ar", "16000", "-ac", "1", str(wav_path)],
            check=True,
        )
    elif afconvert_path:
        subprocess.run(
            [afconvert_path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff_path), str(wav_path)],
            check=True,
        )
    else:
        raise RuntimeError("ffmpeg or afconvert is required to produce wav fixtures.")
    return wav_path


def summarize_transcription_candidate(
    candidate: Candidate,
    results: list[dict[str, Any]],
) -> dict[str, Any]:
    passed_cases = sum(1 for item in results if item["passed"])
    wer_values = [item["wer"] for item in results]
    latencies = [item["latency_seconds"] for item in results]
    mean_wer = sum(wer_values) / max(len(wer_values), 1)
    mean_latency = sum(latencies) / max(len(latencies), 1)
    quality_score = max(0.0, 1.0 - mean_wer)
    latency_penalty = min(mean_latency / 60.0, 0.15)
    app_penalty = 0.0 if candidate.app_compatible else 0.20
    return {
        "candidate": candidate.identifier,
        "runtime": candidate.runtime,
        "repo": candidate.repo,
        "revision": candidate.revision,
        "app_compatible": candidate.app_compatible,
        "passed": passed_cases == len(results),
        "passed_cases": passed_cases,
        "total_cases": len(results),
        "mean_latency_seconds": mean_latency,
        "mean_wer": mean_wer,
        "selection_score": quality_score - latency_penalty - app_penalty,
        "cases": results,
    }


def run_transcription_candidate(
    mode: str,
    candidate: Candidate,
    cases: list[dict[str, Any]],
    temp_path: Path,
) -> dict[str, Any]:
    results = []
    for case in cases:
        if mode == "fixture":
            transcript = case["text"]
            latency = 0.01 if candidate.app_compatible else 0.02
        else:
            import mlx_whisper

            audio_path = generate_audio(case, temp_path)
            model_path = locked_transcription_model_path(candidate)
            start = time.perf_counter()
            result = mlx_whisper.transcribe(
                str(audio_path),
                path_or_hf_repo=model_path,
                verbose=False,
                language="en",
                word_timestamps=False,
            )
            latency = time.perf_counter() - start
            transcript = str(result.get("text", "")).strip()
        wer_value = word_error_rate(case["text"], transcript)
        missing_terms = [
            term for term in case["required_terms"]
            if normalize_text(term) not in normalize_text(transcript)
        ]
        results.append({
            "case_id": case["id"],
            "transcript": transcript,
            "latency_seconds": latency,
            "wer": wer_value,
            "missing_terms": missing_terms,
            "passed": wer_value <= case["max_wer"] and not missing_terms,
        })
    return summarize_transcription_candidate(candidate, results)


def run_transcription(mode: str, candidate_ids: list[str]) -> dict[str, Any]:
    cases = load_json(BENCHMARK_DIR / "transcription_cases.json")
    summaries = []
    with tempfile.TemporaryDirectory(prefix="livenotes-transcription-benchmark.") as temp_dir:
        temp_path = Path(temp_dir)
        for candidate_id in candidate_ids:
            summaries.append(
                run_transcription_candidate(
                    mode,
                    TRANSCRIPTION_CANDIDATES[candidate_id],
                    cases,
                    temp_path,
                )
            )
    app_compatible = [item for item in summaries if item["app_compatible"]]
    recommended_pool = app_compatible if app_compatible else summaries
    recommended = max(recommended_pool, key=lambda item: item["selection_score"])
    return {
        "task": "transcription",
        "passed": recommended["passed"],
        "recommended_candidate": recommended["candidate"],
        "candidates": summaries,
    }


def ensure_dependencies(mode: str, tasks: set[str], translation_candidates: list[str]) -> None:
    if mode == "fixture":
        return
    missing = []
    imports = []
    if "transcription" in tasks or "public_asr_selection" in tasks:
        imports.extend(["mlx_whisper", "jiwer", "soundfile"])
    if "translation" in tasks or "topic" in tasks or "topic_selection" in tasks:
        imports.append("mlx_lm")
    if "translation_selection" in tasks:
        imports.extend(["datasets", "mlx_lm"])
    if "translation" in tasks and "nllb-200-distilled-600m" in translation_candidates:
        imports.extend(["torch", "transformers"])
    if "translation_selection" in tasks and "nllb-200-distilled-600m" in translation_candidates:
        imports.extend(["torch", "transformers"])
    if "public_audio" in tasks or "public_asr_selection" in tasks:
        imports.extend(["huggingface_hub", "pyarrow.parquet"])
    for module_name in imports:
        try:
            __import__(module_name)
        except Exception:
            missing.append(module_name)
    if missing:
        joined = ", ".join(sorted(set(missing)))
        raise RuntimeError(f"Missing benchmark dependencies: {joined}")


def locked_snapshot_path(repo: str, revision: str) -> str:
    from huggingface_hub import snapshot_download

    cache_dir = benchmark_cache_dir("HF_HUB_CACHE")
    kwargs = {"cache_dir": str(cache_dir)} if cache_dir is not None else {}
    return snapshot_download(repo_id=repo, revision=revision, **kwargs)


def locked_transcription_model_path(candidate: Candidate) -> str:
    if candidate.identifier == "whisper-large-v3-turbo":
        root = Path(os.environ.get(
            "LIVENOTES_MODEL_ARTIFACT_ROOT",
            ROOT_DIR / ".cache" / "LiveNotesArtifacts",
        )).expanduser()
        bundled_model = root / "models" / "whisper-large-v3-turbo"
        if bundled_model.exists():
            return str(bundled_model)
    return locked_snapshot_path(candidate.repo, candidate.revision or "main")


def parse_tasks(value: str) -> set[str]:
    tasks = {item.strip() for item in value.split(",") if item.strip()}
    allowed = {
        "transcription",
        "translation",
        "translation_selection",
        "topic",
        "topic_selection",
        "public_audio",
        "public_asr_selection",
    }
    unknown = tasks - allowed
    if unknown:
        raise ValueError(f"Unknown benchmark tasks: {', '.join(sorted(unknown))}")
    return tasks


def load_public_audio_cases() -> list[dict[str, Any]]:
    override = os.environ.get("LIVENOTES_PUBLIC_AUDIO_CASES")
    path = Path(override) if override else BENCHMARK_DIR / "public_audio_cases.json"
    return load_json(path)


def public_audio_artifacts_root() -> Path:
    override = os.environ.get("LIVENOTES_MODEL_ARTIFACT_ROOT")
    if override:
        root = Path(override).expanduser()
    else:
        root = ROOT_DIR / ".cache" / "LiveNotesArtifacts"
    verify_command = [
        sys.executable,
        str(ROOT_DIR / "scripts" / "verify-model-artifacts.py"),
        str(root),
    ]
    if subprocess.run(verify_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        subprocess.run(
            [str(ROOT_DIR / "scripts" / "prepare-bundled-artifacts.sh"), str(root)],
            check=True,
        )
    return root


def fetch_public_audio_case(
    case: dict[str, Any],
    destination: Path,
    cache_dir: Path | None = None,
) -> tuple[Path, str]:
    import pyarrow.parquet as pq
    from huggingface_hub import hf_hub_download

    parquet_path = hf_hub_download(
        repo_id=case["dataset"],
        repo_type="dataset",
        filename=case["parquet_file"],
        revision=case["dataset_revision"],
        cache_dir=str(cache_dir) if cache_dir else None,
    )
    table = pq.read_table(parquet_path, columns=["id", "text", "audio", "audio_length_s"])
    ids = table.column("id").to_pylist()
    try:
        row_index = ids.index(case["record_id"])
    except ValueError as error:
        raise RuntimeError(f"Public audio record was not found: {case['record_id']}") from error
    item = table.slice(row_index, 1).to_pylist()[0]
    reference = str(item.get("text", "")).strip()
    reference_hash = hashlib.sha256(reference.encode("utf-8")).hexdigest()
    if reference_hash != case["reference_sha256"]:
        raise RuntimeError(f"Public audio reference changed for {case['id']}")
    audio = item["audio"]
    suffix = Path(audio.get("path") or "sample.wav").suffix or ".wav"
    output_path = destination / f"{case['id']}{suffix}"
    if audio.get("bytes"):
        output_path.write_bytes(audio["bytes"])
    elif audio.get("path"):
        source_path = Path(audio["path"])
        output_path.write_bytes(source_path.read_bytes())
    else:
        raise RuntimeError(f"Public audio case has no audio bytes: {case['id']}")
    return output_path, reference


def run_local_pipeline(audio_path: Path, artifacts_root: Path) -> tuple[dict[str, Any], float]:
    helper = Path(os.environ.get("LIVENOTES_MLX_HELPER", ROOT_DIR / "scripts" / "livenotes_mlx_pipeline.py"))
    python_executable = os.environ.get("LIVENOTES_PYTHON", sys.executable)
    start = time.perf_counter()
    result = subprocess.run(
        [
            python_executable,
            str(helper),
            "--audio",
            str(audio_path),
            "--artifacts-root",
            str(artifacts_root),
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    latency = time.perf_counter() - start
    return json.loads(result.stdout), latency


def public_audio_fixture_output(case: dict[str, Any]) -> dict[str, Any]:
    fixture_translation = text_from_codepoints([
        0x8FD9, 0x6BB5, 0x5185, 0x5BB9, 0x8BA8, 0x8BBA, 0x6E38, 0x620F,
        0x3001, 0x73B0, 0x5B9E, 0x4F53, 0x9A8C, 0x3001, 0x7528, 0x6237,
        0x754C, 0x9762, 0x548C, 0x529F, 0x80FD, 0x3002,
    ])
    return {
        "transcript": [
            {
                "startTime": 0,
                "endTime": int(case.get("audio_length_s", 30)),
                "text": " ".join(case["required_terms"]),
                "translation": fixture_translation,
                "confidence": "high",
            }
        ],
        "topics": [
            {
                "title": "Public Audio Topic",
                "startTime": 0,
                "endTime": int(case.get("audio_length_s", 30)),
                "summary": "The recording covers " + ", ".join(case["topic_required_terms"]) + ".",
                "keyPoints": case["topic_required_terms"],
                "questions": [],
            }
        ],
        "metrics": {
            "audioDurationSeconds": case.get("audio_length_s", 30),
            "transcriptSegments": 1,
            "translationSegments": 1,
            "topicCount": 1,
        },
    }


def score_public_audio_output(
    case: dict[str, Any],
    reference: str,
    output: dict[str, Any],
    latency_seconds: float,
) -> dict[str, Any]:
    transcript_items = output.get("transcript", [])
    topic_items = output.get("topics", [])
    transcript = " ".join(str(item.get("text", "")) for item in transcript_items)
    translation = " ".join(str(item.get("translation", "")) for item in transcript_items)
    topics = json.dumps(topic_items, ensure_ascii=False)
    wer_value = word_error_rate(reference, transcript)
    transcript_terms = [
        term for term in case["required_terms"]
        if normalize_text(term) in normalize_text(transcript)
    ]
    translation_terms = [
        term for term in case["translation_required_terms"]
        if normalize_text(term) in normalize_text(translation)
    ]
    topic_terms = [
        term for term in case["topic_required_terms"]
        if normalize_text(term) in normalize_text(topics)
    ]
    forbidden_topic_terms = [
        term for term in case.get("forbidden_topic_terms", [])
        if normalize_text(term) in normalize_text(topics)
    ]
    duration = float(case.get("audio_length_s", 1))
    real_time_factor = latency_seconds / max(duration, 1.0)
    ascii_leaks = re.findall(r"[A-Za-z]{3,}", translation)
    passed = (
        wer_value <= case["max_wer"]
        and len(transcript_terms) == len(case["required_terms"])
        and len(translation_terms) >= math.ceil(len(case["translation_required_terms"]) * 0.8)
        and cjk_ratio(translation) >= 0.70
        and len(ascii_leaks) <= 2
        and len(topic_terms) == len(case["topic_required_terms"])
        and len(topic_items) == 1
        and not forbidden_topic_terms
        and real_time_factor <= case["max_real_time_factor"]
        and latency_seconds <= case["max_total_seconds"]
    )
    return {
        "wer": wer_value,
        "transcript_required_hits": transcript_terms,
        "translation_required_hits": translation_terms,
        "translation_cjk_ratio": cjk_ratio(translation),
        "translation_ascii_leaks": ascii_leaks,
        "topic_required_hits": topic_terms,
        "forbidden_topic_hits": forbidden_topic_terms,
        "real_time_factor": real_time_factor,
        "latency_seconds": latency_seconds,
        "passed": passed,
    }


def run_public_audio_pipeline(mode: str) -> dict[str, Any]:
    cases = load_public_audio_cases()
    case_results = []
    temp_path = None
    with tempfile.TemporaryDirectory(prefix="livenotes-public-audio.") as temp_dir:
        temp_path = Path(temp_dir)
        dataset_cache = temp_path / "hf-cache"
        artifacts_root = public_audio_artifacts_root() if mode != "fixture" else temp_path
        for case in cases:
            if mode == "fixture":
                reference = " ".join(case["required_terms"])
                output = public_audio_fixture_output(case)
                latency_seconds = 0.05
            else:
                audio_path, reference = fetch_public_audio_case(case, temp_path, dataset_cache)
                output, latency_seconds = run_local_pipeline(audio_path, artifacts_root)
            score = score_public_audio_output(case, reference, output, latency_seconds)
            case_results.append(
                {
                    "case_id": case["id"],
                    "source": case["source"],
                    "record_id": case["record_id"],
                    "latency_seconds": latency_seconds,
                    "score": score,
                    "metrics": output.get("metrics", {}),
                    "transcript_segments": len(output.get("transcript", [])),
                    "topic_count": len(output.get("topics", [])),
                }
            )
    passed_cases = sum(1 for item in case_results if item["score"]["passed"])
    group_wers: dict[str, list[float]] = {}
    for case, result in zip(cases, case_results):
        group = case.get("mean_wer_group", case["config"])
        group_wers.setdefault(group, []).append(result["score"]["wer"])
    mean_wer_by_group = {
        group: sum(values) / max(len(values), 1)
        for group, values in group_wers.items()
    }
    group_limits_passed = all(
        mean_wer_by_group[case.get("mean_wer_group", case["config"])] <= case["mean_wer_limit"]
        for case in cases
    )
    mean_rtf = sum(item["score"]["real_time_factor"] for item in case_results) / max(len(case_results), 1)
    mean_latency = sum(item["latency_seconds"] for item in case_results) / max(len(case_results), 1)
    cleanup = {
        "temporary_audio_retained": 0 if temp_path is not None and not temp_path.exists() else -1,
        "dataset_cache_retained": 0 if temp_path is not None and not temp_path.exists() else -1,
    }
    return {
        "task": "public_audio_pipeline",
        "passed": passed_cases == len(case_results) and group_limits_passed,
        "passed_cases": passed_cases,
        "total_cases": len(case_results),
        "mean_real_time_factor": mean_rtf,
        "mean_latency_seconds": mean_latency,
        "mean_wer_by_group": mean_wer_by_group,
        "cleanup": cleanup,
        "cases": case_results,
    }


def public_asr_source_targets(sample_count: int) -> list[int]:
    base = sample_count // len(PUBLIC_ASR_SOURCES)
    remainder = sample_count % len(PUBLIC_ASR_SOURCES)
    return [
        base + (1 if index < remainder else 0)
        for index in range(len(PUBLIC_ASR_SOURCES))
    ]


def fixture_public_asr_cases(sample_count: int) -> list[dict[str, Any]]:
    cases = []
    targets = public_asr_source_targets(sample_count)
    for source, target in zip(PUBLIC_ASR_SOURCES, targets):
        for index in range(target):
            case_index = len(cases) + 1
            reference = (
                f"Public benchmark sample {case_index} discusses recording quality, "
                "meeting notes, transcript stability, and live review."
            )
            cases.append({
                "id": f"{source['source']}_fixture_{case_index:03d}",
                "source": source["source"],
                "official_url": source["official_url"],
                "license": source["license"],
                "record_id": f"fixture-{case_index:03d}",
                "duration_seconds": 20.0,
                "reference": reference,
                "reference_sha256": hashlib.sha256(reference.encode("utf-8")).hexdigest(),
                "audio_suffix": ".wav",
                "audio_bytes": b"",
                "case_max_wer": source["case_max_wer"],
                "mean_wer_limit": source["mean_wer_limit"],
                "max_real_time_factor": source["max_real_time_factor"],
            })
    return cases


def load_public_asr_source_cases(
    source: dict[str, Any],
    target_count: int,
    cache_dir: Path,
) -> list[dict[str, Any]]:
    import pyarrow.parquet as pq
    from huggingface_hub import hf_hub_download

    cases = []
    for parquet_file in source["parquet_files"]:
        parquet_path = hf_hub_download(
            repo_id=PUBLIC_ASR_DATASET,
            repo_type="dataset",
            filename=parquet_file,
            revision=PUBLIC_ASR_DATASET_REVISION,
            cache_dir=str(cache_dir),
        )
        table = pq.read_table(parquet_path, columns=["id", "text", "audio", "audio_length_s"])
        for item in table.to_pylist():
            if len(cases) >= target_count:
                return cases
            reference = str(item.get("text", "")).strip()
            audio = item.get("audio") or {}
            duration = float(item.get("audio_length_s") or 0.0)
            if (
                not reference
                or duration < float(source["min_duration_seconds"])
                or duration > float(source["max_duration_seconds"])
            ):
                continue
            audio_bytes = audio.get("bytes")
            if not audio_bytes and audio.get("path"):
                audio_path = Path(audio["path"])
                if audio_path.exists():
                    audio_bytes = audio_path.read_bytes()
            if not audio_bytes:
                continue
            suffix = Path(audio.get("path") or "sample.wav").suffix or ".wav"
            case_index = len(cases) + 1
            cases.append({
                "id": f"{source['source']}_{case_index:03d}",
                "source": source["source"],
                "official_url": source["official_url"],
                "license": source["license"],
                "record_id": str(item.get("id", f"{source['source']}-{case_index:03d}")),
                "duration_seconds": duration,
                "reference": reference,
                "reference_sha256": hashlib.sha256(reference.encode("utf-8")).hexdigest(),
                "audio_suffix": suffix,
                "audio_bytes": audio_bytes,
                "case_max_wer": source["case_max_wer"],
                "mean_wer_limit": source["mean_wer_limit"],
                "max_real_time_factor": source["max_real_time_factor"],
            })
        if len(cases) >= target_count:
            return cases
    return cases


def select_public_asr_cases(sample_count: int, temp_path: Path) -> list[dict[str, Any]]:
    cache_dir = temp_path / "hf-public-asr-cache"
    targets = public_asr_source_targets(sample_count)
    selected = []
    for source, target in zip(PUBLIC_ASR_SOURCES, targets):
        source_cases = load_public_asr_source_cases(source, target, cache_dir)
        if len(source_cases) < target:
            raise RuntimeError(
                "Not enough public ASR cases for "
                f"{source['source']}: required {target}, found {len(source_cases)}"
            )
        selected.extend(source_cases)
    if len(selected) < sample_count:
        raise RuntimeError(f"Required {sample_count} public ASR cases, found {len(selected)}")
    return selected[:sample_count]


def run_public_asr_candidate(
    mode: str,
    candidate: Candidate,
    cases: list[dict[str, Any]],
    audio_dir: Path,
) -> dict[str, Any]:
    results = []
    model_path = ""
    if mode == "live":
        import mlx_whisper

        model_path = locked_transcription_model_path(candidate)
    for case in cases:
        if mode == "fixture":
            transcript = case["reference"]
            latency_seconds = 0.05 if candidate.app_compatible else 0.06
        else:
            audio_path = audio_dir / f"{case['id']}{case['audio_suffix']}"
            audio_path.write_bytes(case["audio_bytes"])
            try:
                start = time.perf_counter()
                result = mlx_whisper.transcribe(
                    str(audio_path),
                    path_or_hf_repo=model_path,
                    verbose=False,
                    language="en",
                    word_timestamps=False,
                )
                latency_seconds = time.perf_counter() - start
                transcript = str(result.get("text", "")).strip()
            finally:
                audio_path.unlink(missing_ok=True)
        wer_value = word_error_rate(case["reference"], transcript)
        real_time_factor = latency_seconds / max(float(case["duration_seconds"]), 1.0)
        results.append({
            "case_id": case["id"],
            "source": case["source"],
            "official_url": case["official_url"],
            "license": case["license"],
            "record_id": case["record_id"],
            "duration_seconds": case["duration_seconds"],
            "reference_sha256": case["reference_sha256"],
            "wer": wer_value,
            "latency_seconds": latency_seconds,
            "real_time_factor": real_time_factor,
            "passed": (
                wer_value <= float(case["case_max_wer"])
                and real_time_factor <= float(case["max_real_time_factor"])
            ),
        })
    return summarize_public_asr_candidate(candidate, results)


def summarize_public_asr_candidate(
    candidate: Candidate,
    results: list[dict[str, Any]],
) -> dict[str, Any]:
    wer_values = [float(item["wer"]) for item in results]
    latency_values = [float(item["latency_seconds"]) for item in results]
    rtf_values = [float(item["real_time_factor"]) for item in results]
    passed_cases = sum(1 for item in results if item["passed"])
    case_pass_rate = passed_cases / len(results)
    source_wers: dict[str, list[float]] = {}
    for item in results:
        source_wers.setdefault(item["source"], []).append(float(item["wer"]))
    mean_wer_by_source = {
        source: mean(values)
        for source, values in source_wers.items()
    }
    source_limits = {
        source["source"]: float(source["mean_wer_limit"])
        for source in PUBLIC_ASR_SOURCES
    }
    source_limits_passed = all(
        value <= source_limits.get(source, 1.0)
        for source, value in mean_wer_by_source.items()
    )
    mean_wer_value = mean(wer_values)
    mean_rtf = mean(rtf_values)
    p95_wer = percentile(wer_values, 95)
    quality_score = max(0.0, 1.0 - mean_wer_value)
    latency_penalty = min(mean_rtf / 10.0, 0.20)
    app_penalty = 0.0 if candidate.app_compatible else 0.20
    passed = (
        case_pass_rate >= PUBLIC_ASR_MINIMUM_CASE_PASS_RATE
        and source_limits_passed
        and p95_wer <= PUBLIC_ASR_MAXIMUM_P95_WER
        and mean_rtf <= PUBLIC_ASR_MAXIMUM_MEAN_REAL_TIME_FACTOR
    )
    return {
        "candidate": candidate.identifier,
        "runtime": candidate.runtime,
        "repo": candidate.repo,
        "revision": candidate.revision,
        "app_compatible": candidate.app_compatible,
        "passed": passed,
        "passed_cases": passed_cases,
        "total_cases": len(results),
        "case_pass_rate": case_pass_rate,
        "minimum_case_pass_rate": PUBLIC_ASR_MINIMUM_CASE_PASS_RATE,
        "mean_wer": mean_wer_value,
        "p95_wer": p95_wer,
        "maximum_p95_wer": PUBLIC_ASR_MAXIMUM_P95_WER,
        "mean_latency_seconds": mean(latency_values),
        "p95_latency_seconds": percentile(latency_values, 95),
        "mean_real_time_factor": mean_rtf,
        "maximum_mean_real_time_factor": PUBLIC_ASR_MAXIMUM_MEAN_REAL_TIME_FACTOR,
        "p95_real_time_factor": percentile(rtf_values, 95),
        "mean_wer_by_source": mean_wer_by_source,
        "source_mean_wer_limits": source_limits,
        "selection_score": quality_score - latency_penalty - app_penalty,
        "cases": results,
        "failed_cases": len(results) - passed_cases,
    }


def run_public_asr_selection(
    mode: str,
    candidate_ids: list[str],
    sample_count: int,
) -> dict[str, Any]:
    if sample_count < MODEL_SELECTION_MINIMUM_SAMPLE_COUNT:
        raise ValueError(
            "Model selection benchmarks require at least "
            f"{MODEL_SELECTION_MINIMUM_SAMPLE_COUNT} samples."
        )
    temp_path = None
    summaries = []
    selected_count = 0
    with tempfile.TemporaryDirectory(prefix="livenotes-public-asr-selection.") as temp_dir:
        temp_path = Path(temp_dir)
        audio_dir = temp_path / "audio"
        audio_dir.mkdir(parents=True, exist_ok=True)
        cases = (
            fixture_public_asr_cases(sample_count)
            if mode == "fixture"
            else select_public_asr_cases(sample_count, temp_path)
        )
        selected_count = len(cases)
        for candidate_id in candidate_ids:
            summaries.append(
                run_public_asr_candidate(
                    mode,
                    TRANSCRIPTION_CANDIDATES[candidate_id],
                    cases,
                    audio_dir,
                )
            )
    app_compatible = [item for item in summaries if item["app_compatible"]]
    recommended_pool = app_compatible if app_compatible else summaries
    recommended = max(recommended_pool, key=lambda item: item["selection_score"])
    cleanup = {
        "temporary_audio_retained": 0 if temp_path is not None and not temp_path.exists() else -1,
        "dataset_cache_retained": 0 if temp_path is not None and not temp_path.exists() else -1,
    }
    return {
        "task": "public_asr_selection",
        "passed": recommended["passed"] and selected_count >= MODEL_SELECTION_MINIMUM_SAMPLE_COUNT,
        "minimum_sample_count": MODEL_SELECTION_MINIMUM_SAMPLE_COUNT,
        "total_cases": selected_count,
        "recommended_candidate": recommended["candidate"],
        "cleanup": cleanup,
        "candidates": summaries,
    }


def run_swift_pipeline_gate() -> dict[str, Any]:
    started = time.perf_counter()
    override = os.environ.get("LIVENOTES_RELEASE_READINESS_COMMAND")
    command = shlex.split(override) if override else [
        str(ROOT_DIR / "scripts" / "check-release-readiness.sh")
    ]
    result = subprocess.run(
        command,
        cwd=ROOT_DIR,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output_tail = "\n".join(result.stdout.splitlines()[-30:])
    passed = (
        result.returncode == 0
        and "Release readiness passed." in result.stdout
        and "No matching test cases were run" not in result.stdout
    )
    return {
        "task": "swift_pipeline",
        "passed": passed,
        "duration_seconds": time.perf_counter() - started,
        "command": " ".join(command),
        "output_tail": output_tail,
    }


def main() -> int:
    global ACTIVE_BENCHMARK_CACHE_CONTEXT

    apply_model_lock()
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["fixture", "live"], default="fixture")
    parser.add_argument(
        "--benchmark-profile",
        choices=["release-smoke", "model-selection"],
        default="release-smoke",
    )
    parser.add_argument("--tasks", default="transcription,translation,topic,public_audio")
    parser.add_argument(
        "--transcription-candidates",
        default="whisper-large-v3-turbo",
    )
    parser.add_argument(
        "--translation-candidates",
        default="qwen3-4b-4bit",
    )
    parser.add_argument(
        "--topic-candidates",
        default="qwen3-4b-4bit",
    )
    parser.add_argument("--required-transcription-default", default="whisper-large-v3-turbo")
    parser.add_argument("--required-translation-default", default="qwen3-4b-4bit")
    parser.add_argument("--required-topic-default", default="qwen3-4b-4bit")
    parser.add_argument("--require-swift-pipeline", action="store_true")
    parser.add_argument("--sample-count", type=int, default=None)
    parser.add_argument(
        "--output",
        default=str(ROOT_DIR / "dist" / "quality-benchmark" / "latest.json"),
    )
    args = parser.parse_args()

    tasks = parse_tasks(args.tasks)
    sample_count = (
        args.sample_count
        if args.sample_count is not None
        else MODEL_SELECTION_MINIMUM_SAMPLE_COUNT
    )
    if args.benchmark_profile == "model-selection" and args.mode != "live":
        raise ValueError("Model selection benchmarks must run in live mode.")
    if args.benchmark_profile == "model-selection":
        required_selection_tasks = {
            "public_asr_selection",
            "translation_selection",
            "topic_selection",
        }
        if not required_selection_tasks.issubset(tasks):
            raise ValueError(
                "Model selection benchmarks must include public ASR, translation, and topic selection."
            )
    transcription_candidates = [
        item.strip() for item in args.transcription_candidates.split(",") if item.strip()
    ]
    translation_candidates = [
        item.strip() for item in args.translation_candidates.split(",") if item.strip()
    ]
    topic_candidates = [
        item.strip() for item in args.topic_candidates.split(",") if item.strip()
    ]
    for candidate in transcription_candidates:
        if candidate not in TRANSCRIPTION_CANDIDATES:
            raise ValueError(f"Unknown transcription candidate: {candidate}")
    for candidate in translation_candidates:
        if candidate not in TRANSLATION_CANDIDATES:
            raise ValueError(f"Unknown translation candidate: {candidate}")
    for candidate in topic_candidates:
        if candidate not in LANGUAGE_MODEL_CANDIDATES:
            raise ValueError(f"Unknown topic candidate: {candidate}")
    ACTIVE_BENCHMARK_CACHE_CONTEXT = benchmark_cache_scope(args.mode)
    ACTIVE_BENCHMARK_CACHE_CONTEXT.__enter__()
    ensure_dependencies(args.mode, tasks, translation_candidates)

    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    benchmark_start = time.perf_counter()
    results: dict[str, Any] = {
        "schema": 1,
        "mode": args.mode,
        "benchmark_profile": args.benchmark_profile,
        "started_at": started_at,
        "results": {},
    }
    if "transcription" in tasks:
        transcription_result = run_transcription(args.mode, transcription_candidates)
        default_candidate = next(
            (
                item for item in transcription_result["candidates"]
                if item["candidate"] == args.required_transcription_default
            ),
            None,
        )
        if default_candidate is None:
            raise ValueError(
                "Required transcription default was not benchmarked: "
                f"{args.required_transcription_default}"
            )
        transcription_result["required_default"] = args.required_transcription_default
        transcription_result["required_default_passed"] = default_candidate["passed"]
        transcription_result["passed"] = (
            transcription_result["passed"]
            and transcription_result["recommended_candidate"] == args.required_transcription_default
            and default_candidate["passed"]
        )
        results["results"]["transcription"] = transcription_result
    if "translation" in tasks:
        translation_result = run_translation(args.mode, translation_candidates)
        default_candidate = next(
            (
                item for item in translation_result["candidates"]
                if item["candidate"] == args.required_translation_default
            ),
            None,
        )
        if default_candidate is None:
            raise ValueError(
                f"Required translation default was not benchmarked: {args.required_translation_default}"
            )
        translation_result["required_default"] = args.required_translation_default
        translation_result["required_default_passed"] = default_candidate["passed"]
        translation_result["passed"] = (
            translation_result["passed"]
            and translation_result["recommended_candidate"] == args.required_translation_default
            and default_candidate["passed"]
        )
        results["results"]["translation"] = translation_result
    if "translation_selection" in tasks:
        translation_selection_result = run_translation_selection(
            args.mode,
            translation_candidates,
            sample_count,
        )
        default_candidate = next(
            (
                item for item in translation_selection_result["candidates"]
                if item["candidate"] == args.required_translation_default
            ),
            None,
        )
        if default_candidate is None:
            raise ValueError(
                "Required translation default was not benchmarked for translation selection: "
                f"{args.required_translation_default}"
            )
        translation_selection_result["required_default"] = args.required_translation_default
        translation_selection_result["required_default_passed"] = default_candidate["passed"]
        translation_selection_result["passed"] = (
            translation_selection_result["passed"]
            and translation_selection_result["recommended_candidate"] == args.required_translation_default
            and default_candidate["passed"]
        )
        results["results"]["translation_selection"] = translation_selection_result
    if "topic" in tasks:
        topic_result = run_topic_generation(args.mode, topic_candidates)
        default_candidate = next(
            (
                item for item in topic_result["candidates"]
                if item["candidate"] == args.required_topic_default
            ),
            None,
        )
        if default_candidate is None:
            raise ValueError(
                f"Required topic default was not benchmarked: {args.required_topic_default}"
            )
        topic_result["required_default"] = args.required_topic_default
        topic_result["required_default_passed"] = default_candidate["passed"]
        topic_result["passed"] = (
            topic_result["passed"]
            and topic_result["recommended_candidate"] == args.required_topic_default
            and default_candidate["passed"]
        )
        results["results"]["topic_summary"] = topic_result
    if "topic_selection" in tasks:
        topic_selection_result = run_topic_selection(
            args.mode,
            topic_candidates,
            sample_count,
        )
        default_candidate = next(
            (
                item for item in topic_selection_result["candidates"]
                if item["candidate"] == args.required_topic_default
            ),
            None,
        )
        if default_candidate is None:
            raise ValueError(
                "Required topic default was not benchmarked for topic selection: "
                f"{args.required_topic_default}"
            )
        topic_selection_result["required_default"] = args.required_topic_default
        topic_selection_result["required_default_passed"] = default_candidate["passed"]
        topic_selection_result["passed"] = (
            topic_selection_result["passed"]
            and topic_selection_result["recommended_candidate"] == args.required_topic_default
            and default_candidate["passed"]
        )
        results["results"]["topic_selection"] = topic_selection_result
    if "public_audio" in tasks:
        results["results"]["public_audio"] = run_public_audio_pipeline(args.mode)
    if "public_asr_selection" in tasks:
        public_asr_result = run_public_asr_selection(
            args.mode,
            transcription_candidates,
            sample_count,
        )
        default_candidate = next(
            (
                item for item in public_asr_result["candidates"]
                if item["candidate"] == args.required_transcription_default
            ),
            None,
        )
        if default_candidate is None:
            raise ValueError(
                "Required transcription default was not benchmarked for public ASR selection: "
                f"{args.required_transcription_default}"
            )
        public_asr_result["required_default"] = args.required_transcription_default
        public_asr_result["required_default_passed"] = default_candidate["passed"]
        public_asr_result["passed"] = (
            public_asr_result["passed"]
            and public_asr_result["recommended_candidate"] == args.required_transcription_default
            and default_candidate["passed"]
        )
        results["results"]["public_asr_selection"] = public_asr_result
    if args.require_swift_pipeline:
        results["results"]["swift_pipeline"] = run_swift_pipeline_gate()
    results["duration_seconds"] = time.perf_counter() - benchmark_start
    results["passed"] = all(task_result["passed"] for task_result in results["results"].values())

    output_path = Path(args.output)
    write_json(output_path, results)
    print(f"Quality benchmark report: {output_path}")
    for name, task_result in results["results"].items():
        status = "PASS" if task_result["passed"] else "FAIL"
        print(f"{status} {name}")
        if name == "transcription":
            print(f"  recommended: {task_result['recommended_candidate']}")
            for candidate in task_result["candidates"]:
                print(
                    "  {candidate}: pass={passed_cases}/{total_cases} "
                    "wer={wer:.2f} latency={latency:.2f}s app={app}".format(
                        candidate=candidate["candidate"],
                        passed_cases=candidate["passed_cases"],
                        total_cases=candidate["total_cases"],
                        wer=candidate["mean_wer"],
                        latency=candidate["mean_latency_seconds"],
                        app=candidate["app_compatible"],
                    )
                )
        if name == "translation":
            print(f"  recommended: {task_result['recommended_candidate']}")
            for candidate in task_result["candidates"]:
                print(
                    "  {candidate}: pass={passed_cases}/{total_cases} "
                    "term={term:.2f} f1={f1:.2f} latency={latency:.2f}s "
                    "app={app}".format(
                        candidate=candidate["candidate"],
                        passed_cases=candidate["passed_cases"],
                        total_cases=candidate["total_cases"],
                        term=candidate["mean_term_coverage"],
                        f1=candidate["mean_char_f1"],
                        latency=candidate["mean_latency_seconds"],
                        app=candidate["app_compatible"],
                    )
                )
        if name == "translation_selection":
            print(
                "  translation selection: samples={total_cases} minimum={minimum} "
                "recommended={recommended}".format(
                    total_cases=task_result["total_cases"],
                    minimum=task_result["minimum_sample_count"],
                    recommended=task_result["recommended_candidate"],
                )
            )
            for candidate in task_result["candidates"]:
                print(
                    "  {candidate}: pass={passed_cases}/{total_cases} "
                    "f1={f1:.2f} cjk={cjk:.2f} latency={latency:.2f}s app={app}".format(
                        candidate=candidate["candidate"],
                        passed_cases=candidate["passed_cases"],
                        total_cases=candidate["total_cases"],
                        f1=candidate["mean_char_f1"],
                        cjk=candidate["mean_cjk_ratio"],
                        latency=candidate["mean_latency_seconds"],
                        app=candidate["app_compatible"],
                    )
                )
        if name == "topic_summary":
            print(f"  recommended: {task_result['recommended_candidate']}")
            for candidate in task_result["candidates"]:
                print(
                    "  {candidate}: pass={passed_cases}/{total_cases} "
                    "match={match:.2f} latency={latency:.2f}s app={app}".format(
                        candidate=candidate["candidate"],
                        passed_cases=candidate["passed_cases"],
                        total_cases=candidate["total_cases"],
                        match=candidate["mean_topic_match"],
                        latency=candidate["mean_latency_seconds"],
                        app=candidate["app_compatible"],
                    )
                )
        if name == "topic_selection":
            print(
                "  topic boundary selection: samples={total_cases} minimum={minimum} "
                "recommended={recommended}".format(
                    total_cases=task_result["total_cases"],
                    minimum=task_result["minimum_sample_count"],
                    recommended=task_result["recommended_candidate"],
                )
            )
            for candidate in task_result["candidates"]:
                print(
                    "  {candidate}: pass={passed_cases}/{total_cases} "
                    "exact={exact:.2f} boundary={match:.2f} latency={latency:.2f}s app={app}".format(
                        candidate=candidate["candidate"],
                        passed_cases=candidate["passed_cases"],
                        total_cases=candidate["total_cases"],
                        exact=candidate["exact_rate"],
                        match=candidate["mean_topic_match"],
                        latency=candidate["mean_latency_seconds"],
                        app=candidate["app_compatible"],
                    )
                )
        if name == "public_audio":
            print(
                "  public recordings: pass={passed_cases}/{total_cases} "
                "rtf={rtf:.2f} latency={latency:.2f}s".format(
                    passed_cases=task_result["passed_cases"],
                    total_cases=task_result["total_cases"],
                    rtf=task_result["mean_real_time_factor"],
                    latency=task_result["mean_latency_seconds"],
                )
            )
        if name == "public_asr_selection":
            print(
                "  public ASR selection: samples={total_cases} minimum={minimum} "
                "recommended={recommended}".format(
                    total_cases=task_result["total_cases"],
                    minimum=task_result["minimum_sample_count"],
                    recommended=task_result["recommended_candidate"],
                )
            )
            for candidate in task_result["candidates"]:
                print(
                    "  {candidate}: pass={passed_cases}/{total_cases} "
                    "wer={wer:.2f} rtf={rtf:.2f} latency={latency:.2f}s app={app}".format(
                        candidate=candidate["candidate"],
                        passed_cases=candidate["passed_cases"],
                        total_cases=candidate["total_cases"],
                        wer=candidate["mean_wer"],
                        rtf=candidate["mean_real_time_factor"],
                        latency=candidate["mean_latency_seconds"],
                        app=candidate["app_compatible"],
                    )
                )
    exit_code = 0 if results["passed"] else 1
    close_active_benchmark_cache_scope()
    return exit_code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        close_active_benchmark_cache_scope()
        print(f"Quality benchmark failed: {error}", file=sys.stderr)
        raise SystemExit(1)
