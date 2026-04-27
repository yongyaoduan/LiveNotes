#!/usr/bin/env python3

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_LOCK_PATH = ROOT_DIR / "QualityBenchmarks" / "model-artifacts.lock.json"


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_json(path: Path) -> str | None:
    try:
        load_json(path)
    except Exception as error:
        return f"{path} is not valid JSON: {error}"
    return None


def validate_safetensors_index(path: Path, root: Path) -> str | None:
    error = validate_json(path)
    if error:
        return error
    payload = load_json(path)
    weight_map = payload.get("weight_map")
    if not isinstance(weight_map, dict) or not weight_map:
        return f"{path} has no weight_map"
    referenced = set(weight_map.values())
    for relative in referenced:
        if not (path.parent / relative).exists() and not (root / relative).exists():
            return f"{path} references missing shard {relative}"
    return None


def read_safetensors_header(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    try:
        with path.open("rb") as handle:
            header_size_bytes = handle.read(8)
            if len(header_size_bytes) != 8:
                return None, f"{path} has an incomplete safetensors header"
            header_size = struct.unpack("<Q", header_size_bytes)[0]
            payload_size = path.stat().st_size - 8
            if header_size <= 0 or header_size > payload_size:
                return None, f"{path} has an invalid safetensors header size"
            header_bytes = handle.read(header_size)
            if len(header_bytes) != header_size:
                return None, f"{path} has a truncated safetensors header"
            payload = json.loads(header_bytes)
            if not isinstance(payload, dict):
                return None, f"{path} safetensors header is not a JSON object"
            return payload, None
    except OSError as error:
        return None, f"{path} could not be read: {error}"
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        return None, f"{path} has invalid safetensors header JSON: {error}"


def validate_safetensors(path: Path) -> str | None:
    _, error = read_safetensors_header(path)
    return error


def validate_precision(root: Path, model: dict[str, Any]) -> list[str]:
    precision = model.get("precision")
    if not precision:
        return []
    errors = []
    model_id = model["id"]
    if model_id == "qwen3-4b-4bit":
        config_path = root / "models" / "qwen3-4b" / "config.json"
        if not config_path.exists():
            return [f"{model_id} precision config is missing"]
        config_error = validate_json(config_path)
        if config_error:
            return [config_error]
        config = load_json(config_path)
        quantization = config.get("quantization") or config.get("quantization_config") or {}
        if config.get("torch_dtype") != precision["base_compute_dtype"]:
            errors.append(f"{model_id} torch_dtype is {config.get('torch_dtype')}, expected {precision['base_compute_dtype']}")
        if quantization.get("bits") != precision["quantization_bits"]:
            errors.append(f"{model_id} quantization bits is {quantization.get('bits')}, expected {precision['quantization_bits']}")
        if quantization.get("group_size") != precision["quantization_group_size"]:
            errors.append(f"{model_id} quantization group_size is {quantization.get('group_size')}, expected {precision['quantization_group_size']}")
        tensor_header, header_error = read_safetensors_header(root / "models" / "qwen3-4b" / "model.safetensors")
        if header_error:
            return [header_error]
        tensor_entries = {
            key: value
            for key, value in tensor_header.items()
            if key != "__metadata__"
        }
        quantized_weights = [
            value["dtype"]
            for key, value in tensor_entries.items()
            if key.endswith(".weight") and len(value.get("shape", [])) == 2
        ]
        scale_bias_tensors = [
            value["dtype"]
            for key, value in tensor_entries.items()
            if key.endswith(".scales") or key.endswith(".biases")
        ]
        if not quantized_weights or any(dtype != precision["quantized_weight_dtype"] for dtype in quantized_weights):
            errors.append(f"{model_id} quantized weights must be stored as {precision['quantized_weight_dtype']}")
        if not scale_bias_tensors or any(dtype != precision["scale_bias_dtype"] for dtype in scale_bias_tensors):
            errors.append(f"{model_id} quantization scales and biases must be stored as {precision['scale_bias_dtype']}")
    if model_id == "whisper-large-v3-turbo":
        weights_path = root / "models" / "whisper-large-v3-turbo" / "weights.safetensors"
        if weights_path.suffix != ".safetensors":
            errors.append(f"{model_id} must use official MLX safetensors weights")
        tensor_header, header_error = read_safetensors_header(weights_path)
        if header_error:
            return [header_error]
        tensor_entries = {
            key: value
            for key, value in tensor_header.items()
            if key != "__metadata__"
        }
        metadata_dtype = precision.get("metadata_dtype", {})
        model_tensor_dtypes = {
            value["dtype"]
            for key, value in tensor_entries.items()
            if key not in metadata_dtype
        }
        if model_tensor_dtypes != {precision["tensor_dtype"]}:
            errors.append(f"{model_id} tensors are {sorted(model_tensor_dtypes)}, expected {precision['tensor_dtype']}")
        for tensor_name, expected_dtype in metadata_dtype.items():
            actual = tensor_entries.get(tensor_name, {}).get("dtype")
            if actual != expected_dtype:
                errors.append(f"{model_id} {tensor_name} is {actual}, expected {expected_dtype}")
    return errors


def bundled_artifacts(lock: dict[str, Any]) -> list[dict[str, Any]]:
    artifacts: list[dict[str, Any]] = []
    for model in lock["models"]:
        if not model.get("bundled", False):
            continue
        for artifact in model["artifacts"]:
            entry = dict(artifact)
            entry["model"] = model["id"]
            artifacts.append(entry)
    return artifacts


def declared_tasks(model: dict[str, Any]) -> set[str]:
    tasks = set()
    task = model.get("task")
    if isinstance(task, str) and task:
        tasks.add(task)
    listed_tasks = model.get("tasks")
    if isinstance(listed_tasks, list):
        tasks.update(item for item in listed_tasks if isinstance(item, str) and item)
    return tasks


def validate_default_profile(lock: dict[str, Any]) -> list[str]:
    errors = []
    profile = lock.get("default_profile")
    if not isinstance(profile, dict):
        return ["default_profile is missing"]
    models = {
        model.get("id"): model
        for model in lock.get("models", [])
        if isinstance(model.get("id"), str)
    }
    bundled_ids = {
        model_id
        for model_id, model in models.items()
        if model.get("bundled", False)
    }
    for role in ("transcription", "summarization", "translation"):
        model_id = profile.get(role)
        if not isinstance(model_id, str) or not model_id:
            errors.append(f"default_profile {role} model is missing")
            continue
        if model_id not in bundled_ids:
            errors.append(f"default_profile {role} uses non-bundled model {model_id}")
            continue
        model_tasks = declared_tasks(models[model_id])
        if role not in model_tasks:
            errors.append(
                f"default_profile {role} uses {model_id}, but the model declares {sorted(model_tasks)}"
            )
    return errors


def validate(root: Path, lock_path: Path) -> list[str]:
    lock = load_json(lock_path)
    errors = validate_default_profile(lock)
    for model in lock["models"]:
        if model.get("bundled", False):
            errors.extend(validate_precision(root, model))
    for artifact in bundled_artifacts(lock):
        relative_path = artifact["path"]
        path = root / relative_path
        if not path.exists():
            errors.append(f"missing {relative_path}")
            continue
        size = path.stat().st_size
        expected_size = artifact.get("size")
        if expected_size is not None and size != expected_size:
            errors.append(f"{relative_path} has size {size}, expected {expected_size}")
        if size <= 0:
            errors.append(f"{relative_path} is empty")
        expected_sha = artifact.get("sha256")
        if expected_sha:
            actual_sha = sha256(path)
            if actual_sha != expected_sha:
                errors.append(f"{relative_path} has sha256 {actual_sha}, expected {expected_sha}")
        artifact_type = artifact.get("type")
        if artifact_type == "json":
            error = validate_json(path)
            if error:
                errors.append(error)
        if artifact_type == "safetensors_index":
            error = validate_safetensors_index(path, root)
            if error:
                errors.append(error)
        if artifact_type == "safetensors":
            error = validate_safetensors(path)
            if error:
                errors.append(error)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument(
        "--lock",
        default=str(Path(sys.argv[0]).resolve().parents[1] / "QualityBenchmarks" / "model-artifacts.lock.json"),
    )
    args = parser.parse_args()

    errors = validate(Path(args.root), Path(args.lock))
    if errors:
        print("LiveNotes model artifact verification failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print(args.root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
