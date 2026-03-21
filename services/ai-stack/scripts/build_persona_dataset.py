#!/usr/bin/env python3
"""Build a persona SFT dataset from a Discord DM export.

This script converts a Discord DM export into train/validation JSONL files for
LoRA supervised fine-tuning. It is intentionally dependency-free so it can run
on a minimal host or inside a lightweight training container.

Supported input shapes:
- top-level JSON object with a `messages` array
- top-level JSON array of message objects
- nested exports where the longest message-like array can be discovered

The script assumes a two-party DM:
- `--user-id` is your Discord user ID
- `--assistant-id` is the target person's Discord user ID

Each output record has this shape:
{
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "timestamped transcript ..."},
    {"role": "assistant", "content": "target reply"}
  ],
  "metadata": {...}
}
"""

from __future__ import annotations

import argparse
import json
import math
import random
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


DEFAULT_SYSTEM_PROMPT = (
    "Match the assistant's conversational style from the examples while staying "
    "coherent, natural, and context-aware."
)


URL_RE = re.compile(r"https?://\S+", re.IGNORECASE)
MENTION_RE = re.compile(r"<@!?\d+>")
CHANNEL_RE = re.compile(r"<#\d+>")
CUSTOM_EMOJI_RE = re.compile(r"<a?:([a-zA-Z0-9_~]+):\d+>")
WHITESPACE_RE = re.compile(r"\s+")


@dataclass
class Message:
    author_id: str
    author_name: str
    content: str
    timestamp: datetime | None
    raw_index: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert a Discord DM export into persona LoRA JSONL datasets."
    )
    parser.add_argument("--input", required=True, help="Path to the Discord export JSON file.")
    parser.add_argument("--output-dir", required=True, help="Directory for train/valid/stats outputs.")
    parser.add_argument("--user-id", required=True, help="Your Discord user ID.")
    parser.add_argument("--assistant-id", required=True, help="Target person's Discord user ID.")
    parser.add_argument(
        "--system-prompt",
        default=DEFAULT_SYSTEM_PROMPT,
        help="System prompt to inject into every training sample.",
    )
    parser.add_argument(
        "--validation-ratio",
        type=float,
        default=0.1,
        help="Fraction of examples reserved for validation. Default: 0.1",
    )
    parser.add_argument(
        "--max-context-turns",
        type=int,
        default=6,
        help="Maximum number of prior turns included in the prompt context. Default: 6",
    )
    parser.add_argument(
        "--min-context-turns",
        type=int,
        default=1,
        help="Minimum number of prior turns required to emit a sample. Default: 1",
    )
    parser.add_argument(
        "--merge-gap-seconds",
        type=int,
        default=180,
        help="Merge consecutive same-author messages within this time gap. Default: 180",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed used only for optional sampling operations. Default: 42",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=0,
        help="Optional cap on emitted samples after chronological construction. Default: unlimited",
    )
    return parser.parse_args()


def load_payload(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def is_message_like(item: Any) -> bool:
    if not isinstance(item, dict):
        return False
    keys = set(item.keys())
    return bool(
        {"content", "timestamp", "author", "author_id", "sender_id", "text", "message"} & keys
    )


def find_message_lists(node: Any) -> list[list[dict[str, Any]]]:
    found: list[list[dict[str, Any]]] = []

    def walk(value: Any) -> None:
        if isinstance(value, list):
            if value and all(is_message_like(item) for item in value):
                found.append(value)
            for item in value:
                walk(item)
        elif isinstance(value, dict):
            for child in value.values():
                walk(child)

    walk(node)
    return found


def extract_message_array(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list) and all(is_message_like(item) for item in payload):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("messages"), list):
        messages = payload["messages"]
        if all(is_message_like(item) for item in messages):
            return messages

    candidates = find_message_lists(payload)
    if not candidates:
        raise ValueError("Could not locate a message array in the provided JSON export.")
    return max(candidates, key=len)


def parse_timestamp(raw_value: Any) -> datetime | None:
    if raw_value is None:
        return None
    if isinstance(raw_value, (int, float)):
        if raw_value > 10_000_000_000:
            raw_value = raw_value / 1000
        return datetime.fromtimestamp(raw_value, tz=timezone.utc)
    if not isinstance(raw_value, str):
        return None

    value = raw_value.strip()
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"

    formats = (
        None,
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f",
    )

    for fmt in formats:
        try:
            if fmt is None:
                parsed = datetime.fromisoformat(value)
            else:
                parsed = datetime.strptime(value, fmt)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed
        except ValueError:
            continue
    return None


def get_author_id(raw_message: dict[str, Any]) -> str | None:
    direct_keys = ("author_id", "sender_id", "user_id")
    for key in direct_keys:
        value = raw_message.get(key)
        if value is not None:
            return str(value)

    for key in ("author", "user", "sender"):
        nested = raw_message.get(key)
        if isinstance(nested, dict):
            value = nested.get("id") or nested.get("userId") or nested.get("discordId")
            if value is not None:
                return str(value)
    return None


def get_author_name(raw_message: dict[str, Any], fallback_id: str) -> str:
    for key in ("author_name", "username", "display_name"):
        value = raw_message.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()

    for key in ("author", "user", "sender"):
        nested = raw_message.get(key)
        if isinstance(nested, dict):
            for nested_key in ("name", "username", "displayName", "global_name"):
                value = nested.get(nested_key)
                if isinstance(value, str) and value.strip():
                    return value.strip()

    return fallback_id


def build_attachment_placeholders(raw_message: dict[str, Any]) -> str:
    placeholders: list[str] = []

    attachments = raw_message.get("attachments")
    if isinstance(attachments, list) and attachments:
        placeholders.extend("[ATTACHMENT]" for _ in attachments)

    embeds = raw_message.get("embeds")
    if isinstance(embeds, list) and embeds:
        placeholders.extend("[EMBED]" for _ in embeds)

    stickers = raw_message.get("stickers")
    if isinstance(stickers, list) and stickers:
        placeholders.extend("[STICKER]" for _ in stickers)

    return " ".join(placeholders)


def normalize_content(content: str) -> str:
    cleaned = content.replace("\r\n", "\n").replace("\r", "\n")
    cleaned = URL_RE.sub("[LINK]", cleaned)
    cleaned = MENTION_RE.sub("[USER]", cleaned)
    cleaned = CHANNEL_RE.sub("[CHANNEL]", cleaned)
    cleaned = CUSTOM_EMOJI_RE.sub(lambda match: f":{match.group(1)}:", cleaned)
    cleaned = "\n".join(WHITESPACE_RE.sub(" ", line).strip() for line in cleaned.split("\n"))
    cleaned = "\n".join(line for line in cleaned.split("\n") if line)
    return cleaned.strip()


def parse_message(raw_message: dict[str, Any], index: int) -> Message | None:
    author_id = get_author_id(raw_message)
    if author_id is None:
        return None

    content_fields = ("content", "message", "text")
    content = ""
    for key in content_fields:
        value = raw_message.get(key)
        if isinstance(value, str):
            content = value
            break

    attachment_placeholders = build_attachment_placeholders(raw_message)
    combined = content.strip()
    if attachment_placeholders:
        combined = f"{combined}\n{attachment_placeholders}" if combined else attachment_placeholders

    normalized = normalize_content(combined)
    if not normalized:
        return None

    timestamp = parse_timestamp(
        raw_message.get("timestamp")
        or raw_message.get("created_at")
        or raw_message.get("createdAt")
        or raw_message.get("date")
    )

    return Message(
        author_id=author_id,
        author_name=get_author_name(raw_message, author_id),
        content=normalized,
        timestamp=timestamp,
        raw_index=index,
    )


def sort_messages(messages: Iterable[Message]) -> list[Message]:
    return sorted(
        messages,
        key=lambda message: (
            message.timestamp or datetime.min.replace(tzinfo=timezone.utc),
            message.raw_index,
        ),
    )


def merge_consecutive_messages(messages: list[Message], gap_seconds: int) -> list[Message]:
    if not messages:
        return []

    merged: list[Message] = [messages[0]]
    for message in messages[1:]:
        previous = merged[-1]
        same_author = previous.author_id == message.author_id
        within_gap = False
        if previous.timestamp and message.timestamp:
            within_gap = (message.timestamp - previous.timestamp).total_seconds() <= gap_seconds

        if same_author and (within_gap or previous.timestamp is None or message.timestamp is None):
            previous.content = f"{previous.content}\n{message.content}".strip()
            previous.timestamp = message.timestamp or previous.timestamp
            continue

        merged.append(message)

    return merged


def label_for_author(author_id: str, user_id: str, assistant_id: str) -> str | None:
    if author_id == user_id:
        return "user"
    if author_id == assistant_id:
        return "assistant"
    return None


def format_timestamp(timestamp: datetime | None) -> str:
    if timestamp is None:
        return "unknown-time"
    return timestamp.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M")


def build_context_transcript(turns: list[Message], user_id: str, assistant_id: str) -> str:
    lines: list[str] = []
    for turn in turns:
        role = label_for_author(turn.author_id, user_id, assistant_id)
        if role is None:
            continue
        speaker = "me" if role == "user" else "them"
        lines.append(f"[{format_timestamp(turn.timestamp)}] {speaker}: {turn.content}")
    return "\n".join(lines)


def build_samples(
    messages: list[Message],
    user_id: str,
    assistant_id: str,
    system_prompt: str,
    min_context_turns: int,
    max_context_turns: int,
) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []

    for index, message in enumerate(messages):
        if message.author_id != assistant_id:
            continue

        context = messages[max(0, index - max_context_turns):index]
        context = [turn for turn in context if label_for_author(turn.author_id, user_id, assistant_id) is not None]

        if len(context) < min_context_turns:
            continue

        transcript = build_context_transcript(context, user_id, assistant_id)
        if not transcript:
            continue

        samples.append(
            {
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": transcript},
                    {"role": "assistant", "content": message.content},
                ],
                "metadata": {
                    "target_timestamp": format_timestamp(message.timestamp),
                    "context_turns": len(context),
                    "target_author_id": assistant_id,
                },
            }
        )

    return samples


def split_samples(samples: list[dict[str, Any]], validation_ratio: float) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not 0 < validation_ratio < 1:
        raise ValueError("validation-ratio must be between 0 and 1.")
    if len(samples) < 2:
        return samples, []

    valid_count = max(1, int(math.floor(len(samples) * validation_ratio)))
    if valid_count >= len(samples):
        valid_count = len(samples) - 1

    split_index = len(samples) - valid_count
    return samples[:split_index], samples[split_index:]


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False))
            handle.write("\n")


def write_stats(
    path: Path,
    *,
    input_path: Path,
    raw_count: int,
    parsed_count: int,
    merged_count: int,
    sample_count: int,
    train_count: int,
    valid_count: int,
    args: argparse.Namespace,
) -> None:
    stats = {
        "input_path": str(input_path),
        "raw_message_count": raw_count,
        "parsed_message_count": parsed_count,
        "merged_message_count": merged_count,
        "sample_count": sample_count,
        "train_count": train_count,
        "valid_count": valid_count,
        "config": {
            "user_id": args.user_id,
            "assistant_id": args.assistant_id,
            "validation_ratio": args.validation_ratio,
            "max_context_turns": args.max_context_turns,
            "min_context_turns": args.min_context_turns,
            "merge_gap_seconds": args.merge_gap_seconds,
            "max_samples": args.max_samples,
        },
    }
    path.write_text(json.dumps(stats, indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()
    random.seed(args.seed)

    input_path = Path(args.input).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()

    if not input_path.exists():
        raise FileNotFoundError(f"Input file not found: {input_path}")

    output_dir.mkdir(parents=True, exist_ok=True)

    payload = load_payload(input_path)
    raw_messages = extract_message_array(payload)

    parsed_messages = [
        parsed
        for index, raw_message in enumerate(raw_messages)
        if isinstance(raw_message, dict)
        for parsed in [parse_message(raw_message, index)]
        if parsed is not None
    ]

    filtered_messages = [
        message
        for message in sort_messages(parsed_messages)
        if label_for_author(message.author_id, args.user_id, args.assistant_id) is not None
    ]

    merged_messages = merge_consecutive_messages(filtered_messages, args.merge_gap_seconds)
    samples = build_samples(
        merged_messages,
        user_id=args.user_id,
        assistant_id=args.assistant_id,
        system_prompt=args.system_prompt,
        min_context_turns=args.min_context_turns,
        max_context_turns=args.max_context_turns,
    )

    if args.max_samples > 0:
        samples = samples[: args.max_samples]

    train_samples, valid_samples = split_samples(samples, args.validation_ratio)

    write_jsonl(output_dir / "train.jsonl", train_samples)
    write_jsonl(output_dir / "valid.jsonl", valid_samples)
    write_stats(
        output_dir / "stats.json",
        input_path=input_path,
        raw_count=len(raw_messages),
        parsed_count=len(parsed_messages),
        merged_count=len(merged_messages),
        sample_count=len(samples),
        train_count=len(train_samples),
        valid_count=len(valid_samples),
        args=args,
    )

    print(f"Wrote {len(train_samples)} training samples to {output_dir / 'train.jsonl'}")
    print(f"Wrote {len(valid_samples)} validation samples to {output_dir / 'valid.jsonl'}")
    print(f"Wrote dataset stats to {output_dir / 'stats.json'}")


if __name__ == "__main__":
    main()