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
- assistant-only loss masking by default so the adapter learns reply style more than prompt reconstruction
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
    parser.add_argument(
        "--train-on-assistant-messages-only",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Mask loss to the final assistant reply only. Default: true",
    )
    return parser.parse_args()


def load_runtime_dependencies() -> tuple[Any, Any, Any, Any, Any, Any]:
    try:
        # Unsloth must be imported before transformers/trl/peft to apply its patches.
        from unsloth import FastLanguageModel, is_bfloat16_supported
        from datasets import load_dataset
        from transformers import DataCollatorForSeq2Seq, Trainer, TrainingArguments
    except ImportError as exc:
        raise SystemExit(
            "Missing training dependencies. Run this inside the training container "
            "or install unsloth, datasets, and transformers."
        ) from exc

    return load_dataset, TrainingArguments, Trainer, DataCollatorForSeq2Seq, FastLanguageModel, is_bfloat16_supported


def render_chat(
    example: dict[str, Any],
    tokenizer: Any,
    *,
    train_on_assistant_messages_only: bool,
) -> dict[str, str]:
    messages = example.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("Each record must contain a non-empty 'messages' array.")

    if train_on_assistant_messages_only:
        if len(messages) < 2 or messages[-1].get("role") != "assistant":
            raise ValueError(
                "Assistant-only loss masking requires the final message in each record to be the assistant reply."
            )

    text = tokenizer.apply_chat_template(
        messages,
        tokenize=False,
        add_generation_prompt=False,
    )

    rendered = {"text": text}
    if train_on_assistant_messages_only:
        prompt_text = tokenizer.apply_chat_template(
            messages[:-1],
            tokenize=False,
            add_generation_prompt=True,
        )
        rendered["prompt_text"] = prompt_text
    return rendered


def tokenize_chat(
    example: dict[str, str],
    tokenizer: Any,
    max_seq_length: int,
    *,
    train_on_assistant_messages_only: bool,
) -> dict[str, Any]:
    text = example.get("text")
    if not isinstance(text, str) or not text:
        raise ValueError("Each rendered record must contain a non-empty 'text' field.")

    text_tokenizer = getattr(tokenizer, "tokenizer", tokenizer)

    tokens = text_tokenizer(
        text=text,
        truncation=True,
        max_length=max_seq_length,
        padding=False,
    )
    labels = list(tokens["input_ids"])

    if train_on_assistant_messages_only:
        prompt_text = example.get("prompt_text")
        if not isinstance(prompt_text, str):
            raise ValueError("Assistant-only loss masking requires a rendered 'prompt_text' field.")

        prompt_tokens = text_tokenizer(
            text=prompt_text,
            truncation=True,
            max_length=max_seq_length,
            padding=False,
        )
        prompt_length = min(len(prompt_tokens["input_ids"]), len(labels))
        for index in range(prompt_length):
            labels[index] = -100

    loss_token_count = sum(1 for token in labels if token != -100)
    return {
        "input_ids": tokens["input_ids"],
        "attention_mask": tokens["attention_mask"],
        "labels": labels,
        "loss_token_count": loss_token_count,
    }


def save_run_config(args: argparse.Namespace) -> None:
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    run_config_path = output_dir / "run_config.json"
    run_config_path.write_text(json.dumps(vars(args), indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()
    save_run_config(args)

    load_dataset, TrainingArguments, Trainer, DataCollatorForSeq2Seq, FastLanguageModel, is_bfloat16_supported = load_runtime_dependencies()

    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.model_name,
        max_seq_length=args.max_seq_length,
        dtype=None,
        load_in_4bit=args.load_in_4bit,
    )
    text_tokenizer = getattr(tokenizer, "tokenizer", tokenizer)

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
        lambda row: render_chat(
            row,
            tokenizer,
            train_on_assistant_messages_only=args.train_on_assistant_messages_only,
        ),
        remove_columns=dataset["train"].column_names,
    )
    train_dataset = train_dataset.map(
        lambda row: tokenize_chat(
            row,
            tokenizer,
            args.max_seq_length,
            train_on_assistant_messages_only=args.train_on_assistant_messages_only,
        ),
        remove_columns=train_dataset.column_names,
    )
    train_before_filter = len(train_dataset)
    train_dataset = train_dataset.filter(lambda row: row["loss_token_count"] > 0)
    train_dropped = train_before_filter - len(train_dataset)
    train_dataset = train_dataset.remove_columns(["loss_token_count"])

    eval_dataset = None
    if "validation" in dataset and len(dataset["validation"]) > 0:
        eval_dataset = dataset["validation"].map(
            lambda row: render_chat(
                row,
                tokenizer,
                train_on_assistant_messages_only=args.train_on_assistant_messages_only,
            ),
            remove_columns=dataset["validation"].column_names,
        )
        eval_dataset = eval_dataset.map(
            lambda row: tokenize_chat(
                row,
                tokenizer,
                args.max_seq_length,
                train_on_assistant_messages_only=args.train_on_assistant_messages_only,
            ),
            remove_columns=eval_dataset.column_names,
        )
        eval_before_filter = len(eval_dataset)
        eval_dataset = eval_dataset.filter(lambda row: row["loss_token_count"] > 0)
        eval_dropped = eval_before_filter - len(eval_dataset)
        eval_dataset = eval_dataset.remove_columns(["loss_token_count"])
    else:
        eval_dropped = 0

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

    data_collator = DataCollatorForSeq2Seq(
        tokenizer=text_tokenizer,
        padding=True,
        label_pad_token_id=-100,
    )

    trainer = Trainer(
        model=model,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        data_collator=data_collator,
        args=training_args,
    )

    trainer.train()

    if args.save_adapter_only:
        model.save_pretrained(args.output_dir)
        tokenizer.save_pretrained(args.output_dir)
    else:
        trainer.save_model(args.output_dir)
        tokenizer.save_pretrained(args.output_dir)

    if train_dropped:
        print(f"Dropped {train_dropped} training samples with no assistant loss tokens after truncation.")
    if eval_dropped:
        print(f"Dropped {eval_dropped} validation samples with no assistant loss tokens after truncation.")
    print(f"Saved training artifacts to {args.output_dir}")


if __name__ == "__main__":
    main()