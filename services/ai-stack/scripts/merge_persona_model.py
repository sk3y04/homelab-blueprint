#!/usr/bin/env python3
"""Merge a PEFT LoRA adapter into its base model and save a full HF checkpoint."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge a persona LoRA adapter into a full model.")
    parser.add_argument("--adapter-dir", required=True, help="Path to the trained PEFT adapter directory.")
    parser.add_argument("--output-dir", required=True, help="Path where the merged full model should be written.")
    parser.add_argument(
        "--base-model",
        default="",
        help="Optional base model path or Hugging Face repo ID. Defaults to adapter_config.json metadata.",
    )
    parser.add_argument(
        "--device-map",
        default="auto",
        help="Transformers device_map value. Default: auto",
    )
    parser.add_argument(
        "--max-shard-size",
        default="5GB",
        help="Shard size for merged safetensors output. Default: 5GB",
    )
    parser.add_argument(
        "--max-seq-length",
        type=int,
        default=2048,
        help="Max sequence length passed to the Unsloth loader. Default: 2048",
    )
    return parser.parse_args()


def load_runtime_dependencies() -> tuple[Any, Any, Any, Any, Any, Any, Any]:
    try:
        import torch
        from unsloth import FastLanguageModel
        from peft import PeftModel
        from transformers import AutoProcessor, AutoTokenizer
    except ImportError as exc:
        raise SystemExit(
            "Missing merge dependencies. Run this inside the training container or install unsloth, peft, torch, and transformers."
        ) from exc

    return torch, FastLanguageModel, PeftModel, AutoTokenizer, AutoProcessor, exc_to_str, read_run_config


def exc_to_str(exc: Exception) -> str:
    return f"{type(exc).__name__}: {exc}"


def read_base_model_from_adapter(adapter_dir: Path) -> str:
    config_path = adapter_dir / "adapter_config.json"
    if not config_path.is_file():
        raise SystemExit(f"adapter_config.json not found in {adapter_dir}")

    config = json.loads(config_path.read_text(encoding="utf-8"))
    base_model = config.get("base_model_name_or_path")
    if not isinstance(base_model, str) or not base_model:
        raise SystemExit(f"base_model_name_or_path missing in {config_path}")
    return base_model


def read_run_config(adapter_dir: Path) -> dict[str, Any]:
    config_path = adapter_dir / "run_config.json"
    if not config_path.is_file():
        return {}

    return json.loads(config_path.read_text(encoding="utf-8"))


def choose_torch_dtype(torch: Any) -> Any:
    if torch.cuda.is_available():
        if torch.cuda.is_bf16_supported():
            return torch.bfloat16
        return torch.float16
    return torch.float32


def maybe_save_tokenizer_and_processor(base_model: str, output_dir: Path, auto_tokenizer: Any, auto_processor: Any, exc_formatter: Any) -> None:
    tokenizer = auto_tokenizer.from_pretrained(base_model, trust_remote_code=True)
    tokenizer.save_pretrained(output_dir)

    try:
        processor = auto_processor.from_pretrained(base_model, trust_remote_code=True)
    except Exception as exc:
        print(f"Processor not saved: {exc_formatter(exc)}")
        return

    processor.save_pretrained(output_dir)


def main() -> None:
    args = parse_args()
    adapter_dir = Path(args.adapter_dir).resolve()
    output_dir = Path(args.output_dir).resolve()

    if not adapter_dir.is_dir():
        raise SystemExit(f"Adapter directory not found: {adapter_dir}")

    torch, fast_language_model, peft_model_cls, auto_tokenizer, auto_processor, exc_formatter, run_config_reader = load_runtime_dependencies()

    base_model = args.base_model or read_base_model_from_adapter(adapter_dir)
    run_config = run_config_reader(adapter_dir)
    max_seq_length = int(run_config.get("max_seq_length", args.max_seq_length))
    dtype = choose_torch_dtype(torch)

    print(f"Loading adapter from: {adapter_dir}")
    print(f"Base model: {base_model}")
    print(f"Device map: {args.device_map}")
    print(f"Torch dtype: {dtype}")
    print(f"Max seq length: {max_seq_length}")

    base, _tokenizer = fast_language_model.from_pretrained(
        base_model,
        max_seq_length=max_seq_length,
        torch_dtype=dtype,
        load_in_4bit=False,
        device_map=args.device_map,
    )

    model = peft_model_cls.from_pretrained(
        base,
        adapter_dir,
        is_trainable=False,
    )

    print("Merging adapter into base model...")
    merged_model = model.merge_and_unload()

    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Saving merged model to: {output_dir}")
    merged_model.save_pretrained(
        output_dir,
        safe_serialization=True,
        max_shard_size=args.max_shard_size,
    )

    maybe_save_tokenizer_and_processor(base_model, output_dir, auto_tokenizer, auto_processor, exc_formatter)
    print("Merged model export complete.")


if __name__ == "__main__":
    main()