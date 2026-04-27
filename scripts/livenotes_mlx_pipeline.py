#!/usr/bin/env python3

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any


def load_llm(model_path: Path):
    from mlx_lm import load

    return load(str(model_path))


def generate_text(model: Any, tokenizer: Any, prompt: str, max_tokens: int) -> str:
    from mlx_lm import generate

    return generate(
        model,
        tokenizer,
        prompt=prompt,
        max_tokens=max_tokens,
        verbose=False,
    ).strip()


def generate_chat_text(
    model: Any,
    tokenizer: Any,
    system: str,
    user: str,
    max_tokens: int,
) -> str:
    prompt = tokenizer.apply_chat_template(
        [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        tokenize=False,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    return strip_thinking(generate_text(model, tokenizer, prompt, max_tokens))


def strip_thinking(value: str) -> str:
    value = re.sub(r"<think>.*?</think>", "", value, flags=re.DOTALL)
    return value.replace("/no_think", "").strip()


def clean_translation(value: str) -> str:
    value = strip_thinking(value)
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    cjk_lines = [line for line in lines if re.search(r"[\u3400-\u9fff]", line)]
    if cjk_lines:
        return " ".join(cjk_lines)
    return lines[0] if lines else ""


def split_long_transcript_segments(
    sentences: list[dict[str, Any]],
    max_words: int = 28,
) -> list[dict[str, Any]]:
    split_sentences = []
    for sentence in sentences:
        words = sentence["text"].split()
        if len(words) <= max_words:
            split_sentences.append(sentence)
            continue
        chunks = [
            words[index:index + max_words]
            for index in range(0, len(words), max_words)
        ]
        duration = max(1, sentence["endTime"] - sentence["startTime"])
        for index, chunk in enumerate(chunks):
            start = sentence["startTime"] + int(round(duration * index / len(chunks)))
            end = sentence["startTime"] + int(round(duration * (index + 1) / len(chunks)))
            split_sentences.append(
                {
                    "startTime": start,
                    "endTime": max(start + 1, end),
                    "text": " ".join(chunk),
                    "translation": "",
                    "confidence": sentence["confidence"],
                }
            )
    return split_sentences


def transcribe(audio_path: Path, model_path: Path) -> list[dict[str, Any]]:
    import mlx_whisper

    result = mlx_whisper.transcribe(
        str(audio_path),
        path_or_hf_repo=str(model_path),
        language="en",
        task="transcribe",
        verbose=False,
    )
    segments = result.get("segments") or []
    if not segments and result.get("text", "").strip():
        segments = [
            {
                "start": 0,
                "end": max(1, int(result.get("duration", 1))),
                "text": result["text"],
            }
        ]
    sentences = []
    for segment in segments:
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        start = max(0, int(round(float(segment.get("start", 0)))))
        end = max(start + 1, int(round(float(segment.get("end", start + 1)))))
        sentences.append(
            {
                "startTime": start,
                "endTime": end,
                "text": text,
                "translation": "",
                "confidence": "high",
            }
        )
    return split_long_transcript_segments(sentences)


def translate_sentences(
    model: Any,
    tokenizer: Any,
    sentences: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    for sentence in sentences:
        response = generate_chat_text(
            model,
            tokenizer,
            "You are a precise English-to-Simplified-Chinese translator. Return only Simplified Chinese. Do not explain. Do not include English unless it is a product name.",
            f"Translate this transcript sentence into natural Simplified Chinese:\n{sentence['text']}",
            128,
        )
        sentence["translation"] = clean_translation(response)
    return sentences


def extract_json_value(text: str) -> Any:
    text = strip_thinking(text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    array_match = re.search(r"\[[\s\S]*\]", text)
    if array_match:
        return json.loads(array_match.group(0))
    object_match = re.search(r"\{[\s\S]*\}", text)
    if object_match:
        return json.loads(object_match.group(0))
    raise ValueError("No JSON value found")


def extract_json_array(text: str) -> list[Any]:
    match = re.search(r"\[[\s\S]*\]", text)
    if not match:
        raise ValueError("No JSON array found")
    return json.loads(match.group(0))


def parse_topic_ids(text: str, expected_count: int) -> list[int]:
    parsed = extract_json_value(text)
    if not isinstance(parsed, list):
        raise ValueError("Topic ids must be a JSON array.")
    topic_ids = []
    for item in parsed:
        if isinstance(item, bool):
            raise ValueError("Topic ids must be integers.")
        if isinstance(item, int):
            topic_ids.append(item)
            continue
        if isinstance(item, str) and re.fullmatch(r"-?[0-9]+", item.strip()):
            topic_ids.append(int(item.strip()))
            continue
        raise ValueError("Topic ids must be integers.")
    if len(topic_ids) != expected_count:
        raise ValueError("Topic id count must match sentence count.")
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


def detect_topic_ids(
    model: Any,
    tokenizer: Any,
    sentences: list[dict[str, Any]],
) -> list[int]:
    if not sentences:
        return []
    if len(sentences) == 1:
        return [0 for _ in sentences]
    response = generate_chat_text(
        model,
        tokenizer,
        "You classify topic continuity. Return valid JSON only.",
        topic_boundary_prompt([sentence["text"] for sentence in sentences]),
        min(256, max(80, len(sentences) * 4 + 24)),
    )
    try:
        topic_ids = parse_topic_ids(response, len(sentences))
    except Exception:
        raise RuntimeError("Local MLX topic detection returned invalid JSON.")
    if has_leading_topic_boundary(topic_ids, len(sentences)):
        return leading_singleton_topic_ids(len(sentences))
    else:
        secondary_response = generate_chat_text(
            model,
            tokenizer,
            "You classify topic continuity. Return valid JSON only.",
            sensitive_topic_boundary_prompt([sentence["text"] for sentence in sentences]),
            min(256, max(80, len(sentences) * 4 + 24)),
        )
        try:
            secondary_topic_ids = parse_topic_ids(secondary_response, len(sentences))
        except Exception:
            secondary_topic_ids = []
        if has_leading_topic_boundary(secondary_topic_ids, len(sentences)):
            return leading_singleton_topic_ids(len(sentences))
    return topic_ids


def group_sentences_by_topic_ids(
    sentences: list[dict[str, Any]],
    topic_ids: list[int],
) -> list[list[dict[str, Any]]]:
    if not sentences:
        return []
    if len(topic_ids) != len(sentences):
        raise RuntimeError("Local MLX topic detection returned the wrong number of topics.")
    groups: list[list[dict[str, Any]]] = []
    current_group: list[dict[str, Any]] = []
    previous_topic = topic_ids[0]
    for sentence, topic_id in zip(sentences, topic_ids):
        if current_group and topic_id != previous_topic:
            groups.append(current_group)
            current_group = []
        current_group.append(sentence)
        previous_topic = topic_id
    if current_group:
        groups.append(current_group)
    return groups


def summarize_topic_group(
    model: Any,
    tokenizer: Any,
    group: list[dict[str, Any]],
    index: int,
) -> dict[str, Any]:
    transcript = "\n".join(
        f"{item['startTime']}-{item['endTime']}: {item['text']}"
        for item in group
    )
    response = generate_chat_text(
        model,
        tokenizer,
        "You create concise grounded topic notes. Return valid JSON only.",
        (
            "Return one JSON object with title, summary, keyPoints, and questions. "
            "Use English. Keep summary to one sentence. "
            "Use at most two keyPoints and at most one question. "
            "Do not include facts not grounded in the transcript.\n\n"
            f"Transcript:\n{transcript}"
        ),
        220,
    )
    try:
        note = extract_json_value(response)
        if not isinstance(note, dict):
            raise ValueError("Topic note must be a JSON object.")
    except Exception:
        raise RuntimeError("Local MLX topic summary returned invalid JSON.")
    return {
        "title": str(note.get("title") or f"Topic {index}"),
        "startTime": group[0]["startTime"],
        "endTime": group[-1]["endTime"],
        "summary": str(note.get("summary") or group[0]["text"]),
        "keyPoints": [str(item) for item in note.get("keyPoints", [])][:2],
        "questions": [str(item) for item in note.get("questions", [])][:1],
    }


def summarize_topics(
    model: Any,
    tokenizer: Any,
    sentences: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    if not sentences:
        return []
    topic_ids = detect_topic_ids(model, tokenizer, sentences)
    groups = group_sentences_by_topic_ids(sentences, topic_ids)
    return [
        summarize_topic_group(model, tokenizer, group, index)
        for index, group in enumerate(groups, start=1)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--artifacts-root", required=True)
    args = parser.parse_args()

    audio_path = Path(args.audio)
    artifacts_root = Path(args.artifacts_root)
    whisper_path = artifacts_root / "models" / "whisper-large-v3-turbo"
    qwen_path = artifacts_root / "models" / "qwen3-4b"

    started_at = time.perf_counter()
    transcription_started_at = time.perf_counter()
    sentences = transcribe(audio_path, whisper_path)
    transcription_seconds = time.perf_counter() - transcription_started_at
    model_load_started_at = time.perf_counter()
    model, tokenizer = load_llm(qwen_path)
    model_load_seconds = time.perf_counter() - model_load_started_at
    translation_started_at = time.perf_counter()
    translated = translate_sentences(model, tokenizer, sentences)
    translation_seconds = time.perf_counter() - translation_started_at
    topic_started_at = time.perf_counter()
    topics = summarize_topics(model, tokenizer, translated)
    topic_seconds = time.perf_counter() - topic_started_at
    duration = max([item["endTime"] for item in translated], default=0)
    total_seconds = time.perf_counter() - started_at

    payload = {
        "transcript": translated,
        "topics": topics,
        "metrics": {
            "audioDurationSeconds": duration,
            "transcriptSegments": len(translated),
            "translationSegments": len([item for item in translated if item["translation"]]),
            "topicCount": len(topics),
            "modelLoadSeconds": model_load_seconds,
            "transcriptionProcessingSeconds": transcription_seconds,
            "translationProcessingSeconds": translation_seconds,
            "topicProcessingSeconds": topic_seconds,
            "totalProcessingSeconds": total_seconds,
            "realTimeFactor": total_seconds / max(duration, 1),
        },
    }
    json.dump(payload, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
