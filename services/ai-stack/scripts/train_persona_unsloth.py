#!/usr/bin/env python3
"""Baseline Unsloth QLoRA trainer for persona SFT.

This script expects the JSONL shape emitted by build_persona_dataset.py:

{
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "metadata": {...}
}

The implementation is intentionally conservative:
- single-GPU QLoRA
- full-chat text rendering through the tokenizer chat template
- adapter-only output

It is a baseline, not a final experiment framework.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


DEFAULT_TARGET_MODULES = [
    "q_proj",
    "k_proj",
    "v_proj",
    "o_proj",
    "gate_proj",
    "up_proj",
    "down_proj",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a persona LoRA with Unsloth.")
    parser.add_argument("--model-name", required=True, help="Hugging Face model ID to fine-tune.")
    parser.add_argument("--train-file", required=True, help="Path to the training JSONL file.")
    parser.add_argument("--valid-file", default="", help="Optional path to the validation JSONL file.")
    parser.add_argument("--output-dir", required=True, help="Directory for the adapter output.")
    parser.add_argument(
        "--max-seq-length",
        type=int,
        default=2048,
        help="Maximum sequence length. Default: 2048",
    )
    parser.add_argument(
        "--load-in-4bit",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Load the base model in 4-bit mode. Default: true",
    )
    parser.add_argument(
        "--per-device-train-batch-size",
        type=int,
        default=1,
        help="Per-device train batch size. Default: 1",
    )
    parser.add_argument(
        "--per-device-eval-batch-size",
        type=int,
        default=1,
        help="Per-device eval batch size. Default: 1",
    )
    parser.add_argument(
        "--gradient-accumulation-steps",
        type=int,
        default=16,
        help="Gradient accumulation steps. Default: 16",
    )
    parser.add_argument("--learning-rate", type=float, default=1e-4, help="Learning rate. Default: 1e-4")
    parser.add_argument("--num-train-epochs", type=float, default=3.0, help="Epoch count. Default: 3")
    parser.add_argument("--warmup-ratio", type=float, default=0.03, help="Warmup ratio. Default: 0.03")
    parser.add_argument("--weight-decay", type=float, default=0.01, help="Weight decay. Default: 0.01")
    parser.add_argument("--logging-steps", type=int, default=10, help="Logging interval. Default: 10")
    parser.add_argument("--save-strategy", default="epoch", help="Transformers save strategy. Default: epoch")
    parser.add_argument(
        "--eval-strategy",
        default="epoch",
        choices=["no", "steps", "epoch"],
        help="Transformers eval strategy. Default: epoch",
    )
    parser.add_argument(
        "--save-total-limit",
        type=int,
        default=2,
        help="Maximum number of checkpoints to keep. Default: 2",
    )
    parser.add_argument("--lora-r", type=int, default=16, help="LoRA rank. Default: 16")
    parser.add_argument("--lora-alpha", type=int, default=32, help="LoRA alpha. Default: 32")
    parser.add_argument("--lora-dropout", type=float, default=0.05, help="LoRA dropout. Default: 0.05")
    parser.add_argument(
        "--target-modules",
        nargs="+",
        default=DEFAULT_TARGET_MODULES,
        help="LoRA target modules.",
    )
    parser.add_argument("--random-state", type=int, default=42, help="Random seed. Default: 42")
    parser.add_argument(
        "--report-to",
        default="none",
        help="Transformers reporting backend, for example none, tensorboard, wandb.",
    )
    parser.add_argument(
        "--save-adapter-only",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Save only the adapter instead of a merged model. Default: true",
    )
    return parser.parse_args()


def load_runtime_dependencies() -> tuple[Any, Any, Any, Any, Any]:
    try:
        # Unsloth must be imported before transformers/trl/peft to apply its patches.
        from unsloth import FastLanguageModel, is_bfloat16_supported
        from datasets import load_dataset
        from transformers import TrainingArguments
        from trl import SFTTrainer
    except ImportError as exc:
        raise SystemExit(
            "Missing training dependencies. Run this inside the training container "
            "or install unsloth, datasets, transformers, and trl."
        ) from exc

    return load_dataset, TrainingArguments, SFTTrainer, FastLanguageModel, is_bfloat16_supported


def render_chat(example: dict[str, Any], tokenizer: Any) -> dict[str, str]:
    messages = example.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("Each record must contain a non-empty 'messages' array.")

    text = tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=False,
    )
    return {"text": text}


def save_run_config(args: argparse.Namespace) -> None:
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    run_config_path = output_dir / "run_config.json"
    run_config_path.write_text(json.dumps(vars(args), indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()
    save_run_config(args)

    load_dataset, TrainingArguments, SFTTrainer, FastLanguageModel, is_bfloat16_supported = load_runtime_dependencies()

    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.model_name,
        max_seq_length=args.max_seq_length,
        dtype=None,
        load_in_4bit=args.load_in_4bit,
    )

    model = FastLanguageModel.get_peft_model(
        model,
        r=args.lora_r,
        target_modules=args.target_modules,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        bias="none",
        use_gradient_checkpointing="unsloth",
        random_state=args.random_state,
    )

    data_files: dict[str, str] = {"train": args.train_file}
    if args.valid_file:
        data_files["validation"] = args.valid_file

    dataset = load_dataset("json", data_files=data_files)
    train_dataset = dataset["train"].map(
        lambda row: render_chat(row, tokenizer),
        remove_columns=dataset["train"].column_names,
    )

    eval_dataset = None
    if "validation" in dataset and len(dataset["validation"]) > 0:
        eval_dataset = dataset["validation"].map(
            lambda row: render_chat(row, tokenizer),
            remove_columns=dataset["validation"].column_names,
        )

    bf16_supported = is_bfloat16_supported()
    training_args = TrainingArguments(
        output_dir=args.output_dir,
        per_device_train_batch_size=args.per_device_train_batch_size,
        per_device_eval_batch_size=args.per_device_eval_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        num_train_epochs=args.num_train_epochs,
        warmup_ratio=args.warmup_ratio,
        weight_decay=args.weight_decay,
        logging_steps=args.logging_steps,
        lr_scheduler_type="cosine",
        optim="adamw_8bit",
        fp16=not bf16_supported,
        bf16=bf16_supported,
        save_strategy=args.save_strategy,
        eval_strategy=args.eval_strategy if eval_dataset is not None else "no",
        save_total_limit=args.save_total_limit,
        report_to=args.report_to,
        seed=args.random_state,
    )

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        dataset_text_field="text",
        max_seq_length=args.max_seq_length,
        packing=False,
        args=training_args,
    )

    trainer.train()

    if args.save_adapter_only:
        model.save_pretrained(args.output_dir)
        tokenizer.save_pretrained(args.output_dir)
    else:
        trainer.save_model(args.output_dir)
        tokenizer.save_pretrained(args.output_dir)

    print(f"Saved training artifacts to {args.output_dir}")


if __name__ == "__main__":
    main()