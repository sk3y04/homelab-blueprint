# Persona Reset and Clean Rebuild Guide

Operator guide for fully removing leftovers from an older broken persona model
and rebuilding a new one with the current repository defaults.

This guide assumes the current repository state where:

- the most reliable Ollama deployment path is a merged full GGUF model
- the recommended deployment artifact is a quantized merged GGUF, not `f16`
- the persona Modelfiles now include an explicit Qwen-style ChatML template

Use this guide when any of the following happened:

- the previous `persona` model answers like a generic assistant
- the model emits raw tokens such as `<|im_start|>` or `<|endoftext|>`
- the model is too slow because the deployed merged model is too heavy
- you want to retrain from scratch without stale deployment artifacts

Related references:

- `guide/AI_PERSONA_RUNBOOK.md`
- `guide/AI_PERSONA_TRAINING.md`
- `guide/AI_PERSONA_EVAL.md`
- `services/ai-stack/scripts/README.md`

---

## What "clean rebuild" means here

For this repository, a clean rebuild means:

1. remove the old Ollama `persona` model entry
2. remove or archive the old live merged GGUF and old live adapter file
3. do not reuse the old broken deployment artifact
4. build a fresh dataset version in a new output directory
5. train a fresh adapter run in a new run directory
6. export a fresh merged GGUF as a quantized artifact
7. recreate the Ollama model from the updated Modelfile
8. only promote the model after evaluation against held-out prompts and dataset style statistics

Do not overwrite old runs blindly. Keep versioned directories so you can tell
which dataset and training run produced which final model.

---

## Recommended deployment choice

For the current stack, prefer:

- training target: `Qwen/Qwen3.5-9B`
- deployment path: merged model
- final Ollama artifact: quantized merged GGUF
- first quantization to test: `q8_0`

Do not treat `ADAPTER` runtime loading in Ollama as the primary path unless you
have personally validated it on your exact Ollama build.

Do not deploy the merged model as `f16` unless you have a specific reason. For
this RTX 3090 host, `f16` is heavier than necessary and is more likely to cause
slow inference and cold-start pain.

---

## Step 1: Stop using the old persona

If `persona` is configured as the default model anywhere, revert that first so
you stop testing against a known bad model.

Check `.env` under `services/ai-stack` and set safe defaults such as:

```bash
OPENCLAW_DEFAULT_MODEL=qwen3.5:27b
OPENCODE_MODEL=ollama/qwen3-coder-next
OPENCODE_SMALL_MODEL=ollama/qwen3.5:9b
```

If you use those services, recreate them after the `.env` change:

```bash
cd services/ai-stack
docker compose up -d openclaw opencode
```

If you are not using them, you can skip the recreate.

---

## Step 2: Remove the old Ollama model entry

List current models:

```bash
docker exec ai-ollama ollama list
```

Remove the old deployed persona model:

```bash
docker exec ai-ollama ollama rm persona || true
docker exec ai-ollama ollama rm persona-dev || true
```

This removes the Ollama model entry. It does not remove the underlying GGUF
files you copied into the active data directory.

---

## Step 3: Remove or archive old live artifacts

The live deployment artifacts are normally here:

```text
/opt/ai-stack/data/lora-adapters/persona-adapter.gguf
/opt/ai-stack/data/merged-models/persona-merged.gguf
```

Recommended approach:

1. move old artifacts into an archive folder if you may want to inspect them later
2. otherwise remove them explicitly

Example archive flow:

```bash
mkdir -p /mnt/archive/ai-stack/archived-models/persona-broken-$(date +%Y%m%d-%H%M%S)
mv /opt/ai-stack/data/lora-adapters/persona-adapter.gguf \
  /mnt/archive/ai-stack/archived-models/persona-broken-$(date +%Y%m%d-%H%M%S)/ 2>/dev/null || true
mv /opt/ai-stack/data/merged-models/persona-merged.gguf \
  /mnt/archive/ai-stack/archived-models/persona-broken-$(date +%Y%m%d-%H%M%S)/ 2>/dev/null || true
```

Example delete flow:

```bash
rm -f /opt/ai-stack/data/lora-adapters/persona-adapter.gguf
rm -f /opt/ai-stack/data/merged-models/persona-merged.gguf
```

After that, recreate `ollama` so its mounts are definitely refreshed:

```bash
cd services/ai-stack
docker compose up -d ollama
```

---

## Step 4: Do not reuse the old run directories blindly

Keep old training outputs for reference, but do not write the new run into the
same directory names.

Instead of reusing:

- `/opt/ai-stack/data/training/processed/persona-v1`
- `/opt/ai-stack/data/training/runs/persona-v1-qwen35-9b`
- `/opt/ai-stack/data/training/merged/persona-v1-qwen35-9b`

create a new version, for example:

- `/opt/ai-stack/data/training/processed/persona-v2`
- `/opt/ai-stack/data/training/runs/persona-v2-qwen35-9b`
- `/opt/ai-stack/data/training/merged/persona-v2-qwen35-9b`

That is the easiest way to avoid mixing a bad old artifact into a new deploy.

---

## Step 5: Rebuild the dataset with the correct style shape

For a chaotic Polish DM target, the current repository defaults are close to
what you want if you use assistant-side burst preservation.

Recommended command:

```bash
python services/ai-stack/scripts/build_persona_dataset.py \
  --input /opt/ai-stack/data/training/raw/discord-dm.json \
  --output-dir /opt/ai-stack/data/training/processed/persona-v2 \
  --user-id 123456789012345678 \
  --assistant-id 987654321098765432 \
  --max-context-turns 6 \
  --min-context-turns 1 \
  --user-merge-gap-seconds 180 \
  --assistant-merge-gap-seconds 0 \
  --assistant-strip-diacritics \
  --assistant-strip-punctuation \
  --assistant-keep-question-marks \
  --validation-ratio 0.1
```

Why this shape is currently the right default:

- user-side nearby messages can still be merged into readable context
- assistant-side short bursts stay as one message per label
- missing Polish diacritics are preserved as a style bias
- `??` can survive normalization when that is part of the target style

---

## Step 6: Validate the dataset before you train anything

This is the highest-leverage step in the whole pipeline.

Open:

- `train.jsonl`
- `valid.jsonl`
- `stats.json`

Do these checks manually:

1. the target person is always the `assistant`
2. your own messages are only in the context, never as labels
3. short fragmented replies remain fragmented in the assistant target
4. there are no secrets or identifying data you do not want memorized
5. `style_stats` matches the real message distribution you want

For this particular style target, pay attention to:

- `fraction_short_messages_le_12_chars`
- `fraction_lowercase_only`
- `fraction_without_polish_diacritics`
- `fraction_with_question_burst`
- `fraction_with_repeated_characters_3plus`
- `fraction_with_chaotic_dm_marker`
- `marker_counts`

If these are clearly wrong, do not train yet. Fix the dataset shape first.

---

## Step 7: Train a fresh baseline adapter

Run training in a new output directory.

Start the container:

```bash
cd services/ai-stack
docker compose --profile training run --rm training
```

Inside the container, run:

```bash
python /repo/services/ai-stack/scripts/train_persona_unsloth.py \
  --model-name Qwen/Qwen3.5-9B \
  --train-file /workspace/processed/persona-v2/train.jsonl \
  --valid-file /workspace/processed/persona-v2/valid.jsonl \
  --output-dir /workspace/runs/persona-v2-qwen35-9b \
  --max-seq-length 2048 \
  --per-device-train-batch-size 1 \
  --gradient-accumulation-steps 16 \
  --learning-rate 1e-4 \
  --num-train-epochs 3 \
  --lora-r 16 \
  --lora-alpha 32 \
  --lora-dropout 0.05
```

The current trainer keeps assistant-only loss masking enabled by default. That
is correct for this task and should not be turned off for the first clean run.

---

## Step 8: Evaluate before export

Do not export or deploy just because the training run completed.

Use held-out prompts that sound like realistic DM openings, for example:

- `hej`
- `co robisz`
- `spisz?`
- `na kiedy to jest`
- `serio??`

Compare the base model and the freshly trained run against the checklist in
`guide/AI_PERSONA_EVAL.md`.

Reject the run before export if you see any of the following repeatedly:

- the model answers like a generic polite assistant
- the model gives long formatted bullet lists for tiny prompts
- the model loses the fragmented short-message rhythm
- the model copies private lines exactly
- the model cannot beat the base model on style at all

If the run fails here, go back to the dataset. Do not try to save it with deployment changes.

---

## Step 9: Export a quantized merged GGUF

For your current stack, this is the deployment path to prefer.

Inside the training container:

```bash
python /repo/services/ai-stack/scripts/export_persona_merged_gguf.sh \
  --adapter-dir /workspace/runs/persona-v2-qwen35-9b \
  --merged-dir /workspace/merged/persona-v2-qwen35-9b \
  --output-file /workspace/exports/persona-v2-q8_0.gguf \
  --llama-cpp-dir /opt/llama.cpp \
  --outtype q8_0
```

Why `q8_0` first:

- it is much more practical than `f16` on this host
- it is still a conservative quality-first quantization
- it reduces the risk of the slow heavy merged model you saw before

If `q8_0` is still too slow, the next sensible step is `q5_k_m`, not `f16`.

---

## Step 10: Recreate the persona model from the updated Modelfile

The current repository Modelfiles already contain an explicit Qwen-style ChatML
template. That matters because older or mismatched prompting can cause the
model to emit raw tokens such as `<|im_start|>` or continue into `Human:` text.

Deploy the merged model:

```bash
cd services/ai-stack
./deploy-persona-merged.sh \
  --model-file /opt/ai-stack/data/training/exports/persona-v2-q8_0.gguf \
  --model-name persona \
  --force
```

The `--force` matters. It ensures the old `persona` model entry is removed and
rebuilt from the updated Modelfile instead of silently reusing a stale model definition.

---

## Step 11: Smoke-test the new deployment before promotion

Run the shortest possible tests first:

```bash
docker exec ai-ollama ollama run qwen3.5:9b "hej"
docker exec ai-ollama ollama run persona "hej"
docker exec ai-ollama ollama run persona "co robisz"
docker exec ai-ollama ollama run persona "spisz?"
```

Expected behavior from a good run:

- the base model stays generic and assistant-like
- `persona` is noticeably shorter, rougher, and less polished
- `persona` does not emit raw tokens like `<|im_start|>`
- `persona` does not answer with long tutorial-style paragraphs to a one-word prompt

If the new `persona` still responds like a polished assistant, stop there. Do
not promote it into OpenClaw or OpenCode.

---

## Step 12: Promote only after it passes the smoke test

If the direct Ollama tests are good, then you can promote the model into other
services:

```bash
cd services/ai-stack
./promote-persona-defaults.sh --model-name persona --recreate
```

Do not promote first and debug later. Always validate the raw Ollama model first.

---

## What is consistent in the repository now

After the recent fixes, the main path is internally consistent in these areas:

1. dataset builder can preserve fragmented assistant-side DM bursts
2. dataset stats include style metrics relevant to chaotic Polish DM behavior
3. trainer uses assistant-only loss masking by default
4. merged deployment is documented as the reliable Ollama path
5. persona Modelfiles now use an explicit Qwen-style ChatML template
6. merged export script defaults to `q8_0`, which is the right first deployment target for this host

---

## What still cannot be guaranteed

Even with the current pipeline, no one can honestly guarantee that the model
will always sound exactly like the real person.

What this repository can realistically give you when the data is good:

- strong style transfer
- good short-message rhythm transfer
- better slang and reply-shape matching
- much less generic assistant behavior than the base model

What still depends on your data quality and evaluation discipline:

- how often the model keeps the chaotic Polish DM style without drifting back to the base model
- whether the style stays stable outside seen situations
- whether the model avoids overfitting or memorization

That is why `stats.json`, held-out prompt evaluation, and direct `ollama run persona ...` smoke tests all matter.

---

## Go / No-Go rule

Treat the new persona as acceptable only if all of the following are true:

1. direct Ollama prompts work without raw special tokens
2. short prompts get short DM-like answers instead of tutorials or disclaimers
3. the model beats the base model on style for held-out prompts
4. the model does not leak private lines
5. the deployment artifact is a fresh quantized merged GGUF, not the old broken one

If any of those fail, do not promote the model. Fix the dataset, export, or deployment step first.