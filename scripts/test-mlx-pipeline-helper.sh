#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python - "$ROOT_DIR/scripts/livenotes_mlx_pipeline.py" <<'PY'
import importlib.util
import sys
from pathlib import Path

module_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("livenotes_mlx_pipeline", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

expected_translation = "".join(chr(value) for value in [
    0x8FD9, 0x6BB5, 0x8BDD, 0x5E94, 0x8BE5, 0x81EA, 0x7136, 0x7FFB,
    0x8BD1, 0x3002,
])
cleaned = module.clean_translation(
    f"The translation should be natural.\n{expected_translation}\nAvoid literal translation."
)
assert cleaned == expected_translation

segments = module.split_long_transcript_segments(
    [
        {
            "startTime": 10,
            "endTime": 22,
            "text": "one two three four five six seven eight nine ten eleven twelve",
            "translation": "",
            "confidence": "high",
        }
    ],
    max_words=5,
)
assert len(segments) == 3
assert segments[0]["startTime"] == 10
assert segments[-1]["endTime"] == 22
assert segments[0]["text"] == "one two three four five"
assert segments[1]["text"] == "six seven eight nine ten"
assert segments[2]["text"] == "eleven twelve"

assert module.parse_topic_ids("[0, 0, 1, 1]", 4) == [0, 0, 1, 1]
assert module.parse_topic_ids('["0", "0", "1", "1"]', 4) == [0, 0, 1, 1]

topic_sentences = [
    {"startTime": 0, "endTime": 8, "text": "Notebook setup starts with dependencies.", "translation": "", "confidence": "high"},
    {"startTime": 8, "endTime": 18, "text": "The notebook setup continues after a kernel restart.", "translation": "", "confidence": "high"},
    {"startTime": 18, "endTime": 29, "text": "Now we move to validation accuracy and the learning rate.", "translation": "", "confidence": "high"},
    {"startTime": 29, "endTime": 40, "text": "Validation accuracy should be compared before other changes.", "translation": "", "confidence": "high"},
]

groups = module.group_sentences_by_topic_ids(topic_sentences, [0, 0, 1, 1])
assert len(groups) == 2
assert groups[0][0]["startTime"] == 0
assert groups[0][-1]["endTime"] == 18
assert groups[1][0]["startTime"] == 18
assert groups[1][-1]["endTime"] == 40

try:
    module.group_sentences_by_topic_ids(topic_sentences, [0, 0, 1])
    raise AssertionError("Expected topic-count mismatch to fail.")
except RuntimeError as error:
    assert "wrong number of topics" in str(error)

prompt = module.topic_boundary_prompt([
    "Notebook setup starts with dependencies.",
    "Validation accuracy changed after the learning rate update.",
    "The training curve should be compared before changing another setting.",
    "A stable validation curve is more useful than one lucky training batch.",
])
assert "[0,1,1,1]" in prompt
assert "[0,0,0,1]" in prompt
assert "[0,0,1,1]" in prompt
assert "Example: four sentences in two topics should return [0,0,1,1]" not in prompt
sensitive_prompt = module.sensitive_topic_boundary_prompt([
    "Notebook setup starts with dependencies.",
    "Validation accuracy changed after the learning rate update.",
    "The training curve should be compared before changing another setting.",
    "A stable validation curve is more useful than one lucky training batch.",
])
assert "A one-sentence opening topic is valid." in sensitive_prompt
assert module.has_leading_topic_boundary([0, 1, 1, 1], 4) is True
assert module.has_leading_topic_boundary([0, 0, 1, 1], 4) is False
assert module.leading_singleton_topic_ids(4) == [0, 1, 1, 1]
PY

printf 'MLX helper tests passed.\n'
