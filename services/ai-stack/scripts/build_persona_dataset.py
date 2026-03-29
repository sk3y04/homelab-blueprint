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
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


DEFAULT_SYSTEM_PROMPT = (
    "Reply like the target person in the examples. Keep the tone natural, "
    "specific, casual, and DM-like. Prefer short direct replies over formal "
    "assistant answers. Do not sound like a generic AI assistant, do not add "
    "capability disclaimers, and stay in the same language and vibe as the "
    "conversation unless the context clearly requires otherwise. Match the "
    "writing habits from the dataset, including lack of punctuation and lack "
    "of Polish diacritics when that is how the target person writes. If the "
    "examples show fragmented burst messaging, keep that fragmented message "
    "shape instead of rewriting it into polished prose."
)


URL_RE = re.compile(r"https?://\S+", re.IGNORECASE)
MENTION_RE = re.compile(r"<@!?\d+>")
CHANNEL_RE = re.compile(r"<#\d+>")
CUSTOM_EMOJI_RE = re.compile(r"<a?:([a-zA-Z0-9_~]+):\d+>")
WHITESPACE_RE = re.compile(r"\s+")
PUNCT_RE = re.compile(r"[!\"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~…„”’‘—–]+")
POLISH_DIACRITICS_RE = re.compile(r"[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]")
TERMINAL_PUNCTUATION_RE = re.compile(r"[.!?,:;…]+$")
QUESTION_BURST_RE = re.compile(r"\?{2,}")
REPEATED_CHARACTER_RE = re.compile(r"(.)\1{2,}", re.IGNORECASE)
UPPERCASE_LETTER_RE = re.compile(r"[A-ZĄĆĘŁŃÓŚŹŻ]")
STYLE_TOKEN_RE = re.compile(r"[0-9A-Za-ząćęłńóśźżĄĆĘŁŃÓŚŹŻ?!.]+")
CHAOTIC_DM_MARKERS = (
    "xd",
    "xddd",
    "nw",
    "nwm",
    "wgl",
    "serio",
    "boze",
    "kirwa",
    "kurde",
    "czekajta",
)


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
        "--user-merge-gap-seconds",
        type=int,
        default=None,
        help="Optional merge gap override for user-side messages. Defaults to --merge-gap-seconds.",
    )
    parser.add_argument(
        "--assistant-merge-gap-seconds",
        type=int,
        default=None,
        help="Optional merge gap override for assistant-side messages. Set to 0 to keep one target message per label.",
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
    parser.add_argument(
        "--assistant-strip-diacritics",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Strip Polish diacritics from assistant-side messages. Default: true",
    )
    parser.add_argument(
        "--assistant-strip-punctuation",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Strip punctuation from assistant-side messages. Default: true",
    )
    parser.add_argument(
        "--assistant-keep-question-marks",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Keep question marks when stripping assistant-side punctuation. Default: false",
    )
    parser.add_argument(
        "--assistant-keep-exclamation-marks",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Keep exclamation marks when stripping assistant-side punctuation. Default: false",
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


def strip_diacritics(text: str) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    return "".join(char for char in normalized if not unicodedata.combining(char))


def strip_punctuation(
    text: str,
    *,
    keep_question_marks: bool,
    keep_exclamation_marks: bool,
) -> str:
    stripped_lines: list[str] = []
    for line in text.split("\n"):
        chars: list[str] = []
        for char in line:
            if PUNCT_RE.fullmatch(char):
                if char == "?" and keep_question_marks:
                    chars.append(char)
                elif char == "!" and keep_exclamation_marks:
                    chars.append(char)
                else:
                    chars.append(" ")
            else:
                chars.append(char)
        without_punct = "".join(chars)
        without_punct = WHITESPACE_RE.sub(" ", without_punct).strip()
        if without_punct:
            stripped_lines.append(without_punct)
    return "\n".join(stripped_lines)


def apply_assistant_style(
    text: str,
    *,
    strip_assistant_diacritics: bool,
    strip_assistant_punctuation: bool,
    keep_question_marks: bool,
    keep_exclamation_marks: bool,
) -> str:
    styled = text
    if strip_assistant_diacritics:
        styled = strip_diacritics(styled)
    if strip_assistant_punctuation:
        styled = strip_punctuation(
            styled,
            keep_question_marks=keep_question_marks,
            keep_exclamation_marks=keep_exclamation_marks,
        )
    return normalize_content(styled)


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


def merge_consecutive_messages(
    messages: list[Message],
    *,
    default_gap_seconds: int,
    user_id: str,
    assistant_id: str,
    user_gap_seconds: int | None,
    assistant_gap_seconds: int | None,
) -> list[Message]:
    if not messages:
        return []

    merged: list[Message] = [messages[0]]
    for message in messages[1:]:
        previous = merged[-1]
        same_author = previous.author_id == message.author_id
        within_gap = False
        if previous.timestamp and message.timestamp:
            gap_seconds = default_gap_seconds
            if message.author_id == user_id and user_gap_seconds is not None:
                gap_seconds = user_gap_seconds
            elif message.author_id == assistant_id and assistant_gap_seconds is not None:
                gap_seconds = assistant_gap_seconds
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
    strip_assistant_diacritics: bool,
    strip_assistant_punctuation: bool,
    keep_question_marks: bool,
    keep_exclamation_marks: bool,
) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []

    styled_messages: list[Message] = []
    for message in messages:
        if message.author_id == assistant_id:
            styled_messages.append(
                Message(
                    author_id=message.author_id,
                    author_name=message.author_name,
                    content=apply_assistant_style(
                        message.content,
                        strip_assistant_diacritics=strip_assistant_diacritics,
                        strip_assistant_punctuation=strip_assistant_punctuation,
                        keep_question_marks=keep_question_marks,
                        keep_exclamation_marks=keep_exclamation_marks,
                    ),
                    timestamp=message.timestamp,
                    raw_index=message.raw_index,
                )
            )
        else:
            styled_messages.append(message)

    for index, message in enumerate(styled_messages):
        if message.author_id != assistant_id:
            continue

        context = styled_messages[max(0, index - max_context_turns):index]
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


def extract_style_tokens(text: str) -> list[str]:
    return [token.lower() for token in STYLE_TOKEN_RE.findall(text)]


def compute_style_stats(samples: list[dict[str, Any]]) -> dict[str, Any]:
    assistant_messages = [
        record["messages"][-1]["content"]
        for record in samples
        if record.get("messages") and record["messages"][-1].get("role") == "assistant"
    ]
    if not assistant_messages:
        return {
            "assistant_message_count": 0,
            "average_chars": 0.0,
            "average_lines": 0.0,
            "fraction_without_polish_diacritics": 0.0,
            "fraction_without_terminal_punctuation": 0.0,
            "fraction_short_messages_le_12_chars": 0.0,
            "fraction_multiline_messages": 0.0,
            "fraction_lowercase_only": 0.0,
            "fraction_with_question_burst": 0.0,
            "fraction_with_repeated_characters_3plus": 0.0,
            "fraction_with_chaotic_dm_marker": 0.0,
            "marker_counts": {marker: 0 for marker in CHAOTIC_DM_MARKERS},
        }

    message_count = len(assistant_messages)
    char_lengths = [len(message) for message in assistant_messages]
    line_counts = [len(message.splitlines()) for message in assistant_messages]
    no_diacritics = sum(1 for message in assistant_messages if not POLISH_DIACRITICS_RE.search(message))
    no_terminal_punctuation = sum(
        1 for message in assistant_messages if not TERMINAL_PUNCTUATION_RE.search(message.rstrip())
    )
    short_messages = sum(1 for message in assistant_messages if len(message) <= 12)
    multiline_messages = sum(1 for message in assistant_messages if "\n" in message)
    lowercase_only = sum(1 for message in assistant_messages if not UPPERCASE_LETTER_RE.search(message))
    question_bursts = sum(1 for message in assistant_messages if QUESTION_BURST_RE.search(message))
    repeated_characters = sum(1 for message in assistant_messages if REPEATED_CHARACTER_RE.search(message))
    marker_counts = {marker: 0 for marker in CHAOTIC_DM_MARKERS}
    marker_messages = 0

    for message in assistant_messages:
        tokens = extract_style_tokens(message)
        message_markers = set()
        for marker in CHAOTIC_DM_MARKERS:
            hits = tokens.count(marker)
            if hits:
                marker_counts[marker] += hits
                message_markers.add(marker)
        if message_markers:
            marker_messages += 1

    return {
        "assistant_message_count": message_count,
        "average_chars": round(sum(char_lengths) / message_count, 2),
        "average_lines": round(sum(line_counts) / message_count, 2),
        "fraction_without_polish_diacritics": round(no_diacritics / message_count, 4),
        "fraction_without_terminal_punctuation": round(no_terminal_punctuation / message_count, 4),
        "fraction_short_messages_le_12_chars": round(short_messages / message_count, 4),
        "fraction_multiline_messages": round(multiline_messages / message_count, 4),
        "fraction_lowercase_only": round(lowercase_only / message_count, 4),
        "fraction_with_question_burst": round(question_bursts / message_count, 4),
        "fraction_with_repeated_characters_3plus": round(repeated_characters / message_count, 4),
        "fraction_with_chaotic_dm_marker": round(marker_messages / message_count, 4),
        "marker_counts": marker_counts,
    }


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
    style_stats: dict[str, Any],
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
        "style_stats": style_stats,
        "config": {
            "user_id": args.user_id,
            "assistant_id": args.assistant_id,
            "validation_ratio": args.validation_ratio,
            "max_context_turns": args.max_context_turns,
            "min_context_turns": args.min_context_turns,
            "merge_gap_seconds": args.merge_gap_seconds,
            "user_merge_gap_seconds": args.user_merge_gap_seconds,
            "assistant_merge_gap_seconds": args.assistant_merge_gap_seconds,
            "max_samples": args.max_samples,
            "assistant_strip_diacritics": args.assistant_strip_diacritics,
            "assistant_strip_punctuation": args.assistant_strip_punctuation,
            "assistant_keep_question_marks": args.assistant_keep_question_marks,
            "assistant_keep_exclamation_marks": args.assistant_keep_exclamation_marks,
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

    merged_messages = merge_consecutive_messages(
        filtered_messages,
        default_gap_seconds=args.merge_gap_seconds,
        user_id=args.user_id,
        assistant_id=args.assistant_id,
        user_gap_seconds=args.user_merge_gap_seconds,
        assistant_gap_seconds=args.assistant_merge_gap_seconds,
    )
    samples = build_samples(
        merged_messages,
        user_id=args.user_id,
        assistant_id=args.assistant_id,
        system_prompt=args.system_prompt,
        min_context_turns=args.min_context_turns,
        max_context_turns=args.max_context_turns,
        strip_assistant_diacritics=args.assistant_strip_diacritics,
        strip_assistant_punctuation=args.assistant_strip_punctuation,
        keep_question_marks=args.assistant_keep_question_marks,
        keep_exclamation_marks=args.assistant_keep_exclamation_marks,
    )

    if args.max_samples > 0:
        samples = samples[: args.max_samples]

    train_samples, valid_samples = split_samples(samples, args.validation_ratio)
    style_stats = compute_style_stats(samples)

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
        style_stats=style_stats,
        args=args,
    )

    print(f"Wrote {len(train_samples)} training samples to {output_dir / 'train.jsonl'}")
    print(f"Wrote {len(valid_samples)} validation samples to {output_dir / 'valid.jsonl'}")
    print(f"Wrote dataset stats to {output_dir / 'stats.json'}")


if __name__ == "__main__":
    main()