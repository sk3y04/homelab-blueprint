# Persona LoRA Runbook

Single operator-facing runbook for training, evaluating, exporting, and
deploying a Discord DM persona model on this homelab AI stack.

This document is the shortest path through the existing persona workflow. Use
it when you want one checklist and one command sequence instead of switching
between multiple documents.

Related references:

- `guide/AI_PERSONA_TRAINING.md` for design rationale and tradeoffs
- `guide/AI_PERSONA_EVAL.md` for the detailed manual scoring rubric
- `services/ai-stack/scripts/README.md` for per-script reference details

---

## Goal

Train a LoRA adapter that makes the base model respond more like one specific
person from a Discord DM export.

This workflow is intended for:

- style and tone transfer
- conversational rhythm transfer
- reply-shape adaptation

It is not intended to create a reliable factual memory of a person.

---

## Outcome

If the run succeeds, you will end up with:

1. `train.jsonl` and `valid.jsonl`
2. a trained LoRA adapter directory under `/opt/ai-stack/data/training/runs/`
3. a GGUF adapter export under `/opt/ai-stack/data/training/exports/`
4. an Ollama model called `persona` created from `Modelfile.persona`

---

## Before You Start

Required assumptions for this repository:

- host GPU is an RTX 3090 24 GB
- AI stack lives under `services/ai-stack`
- active AI data lives under `/opt/ai-stack/data`
- raw Discord export is stored outside Git
- you know your Discord user ID and the target person's Discord user ID

Recommended source files to verify before running:

- `services/ai-stack/scripts/build_persona_dataset.py`
- `services/ai-stack/scripts/train_persona_unsloth.py`
- `services/ai-stack/scripts/export_persona_adapter.sh`
- `services/ai-stack/deploy-persona.sh`
- `services/ai-stack/Modelfile.persona.example`

---

## Fast Checklist

1. Prepare training directories and switch the GPU to training mode.
2. Build the dataset from the Discord export.
3. Inspect `stats.json` and manually sample the dataset.
4. Run one baseline Qwen 3.5 9B training job.
5. Evaluate the result with held-out prompts.
6. Export the adapter to GGUF.
7. Deploy the adapter into Ollama as `persona`.
8. Promote the model only if evaluation is good enough.

---

## Step 1: Prepare the Host

Run:

```bash
cd services/ai-stack
sudo ./set-gpu-training.sh
sudo mkdir -p /opt/ai-stack/data/training/{raw,processed,runs,checkpoints,exports}
sudo mkdir -p /mnt/archive/ai-stack/{raw-datasets,archived-runs,archived-models,backups}
sudo chown -R "$(id -u):$(id -g)" /opt/ai-stack/data/training
sudo chown -R "$(id -u):$(id -g)" /mnt/archive/ai-stack
```

Checks:

1. `nvidia-smi` works on the host
2. enough free disk space exists under `/opt/ai-stack/data/training`
3. inference workloads are idle if VRAM is tight

---

## Step 2: Place the Raw Export

Put the Discord export file under:

```text
/opt/ai-stack/data/training/raw/
```

Expected input:

- one DM export JSON
- timestamps per message
- author IDs
- message content

Privacy requirements before training:

- remove secrets, tokens, addresses, phone numbers, and IDs you do not want memorized
- remove or anonymize third-party private data where needed
- keep the raw export outside Git

---

## Step 3: Build the Dataset

Baseline command:

```bash
python services/ai-stack/scripts/build_persona_dataset.py \
  --input /opt/ai-stack/data/training/raw/discord-dm.json \
  --output-dir /opt/ai-stack/data/training/processed/persona-v1 \
  --user-id 123456789012345678 \
  --assistant-id 987654321098765432 \
  --max-context-turns 6 \
  --min-context-turns 1 \
  --merge-gap-seconds 180 \
  --validation-ratio 0.1
```

What this should produce:

- `/opt/ai-stack/data/training/processed/persona-v1/train.jsonl`
- `/opt/ai-stack/data/training/processed/persona-v1/valid.jsonl`
- `/opt/ai-stack/data/training/processed/persona-v1/stats.json`

Manual checks before training:

1. inspect `stats.json`
2. read 50 to 100 examples from `train.jsonl`
3. verify the target person is always the `assistant`
4. verify your own messages are in the prompt context, not the answer label
5. verify no obvious secrets survived normalization

Stop here if speaker mapping is wrong. Bad labels will poison the run.

---

## Step 4: Start the Training Container

Run:

```bash
cd services/ai-stack
docker compose --profile training run --rm training
```

This container is the intended place to run the Unsloth training script and the
GGUF export tooling.

---

## Step 5: Train the Baseline Adapter

Inside the training container, run one conservative baseline first:

```bash
python /repo/services/ai-stack/scripts/train_persona_unsloth.py \
  --model-name Qwen/Qwen3.5-9B-Instruct \
  --train-file /workspace/processed/persona-v1/train.jsonl \
  --valid-file /workspace/processed/persona-v1/valid.jsonl \
  --output-dir /workspace/runs/persona-v1-qwen35-9b \
  --max-seq-length 2048 \
  --per-device-train-batch-size 1 \
  --gradient-accumulation-steps 16 \
  --learning-rate 1e-4 \
  --num-train-epochs 3 \
  --lora-r 16 \
  --lora-alpha 32 \
  --lora-dropout 0.05
```

What to record for the run:

- base model ID
- dataset version
- all CLI flags
- training start and end time
- any OOM or instability events

Expected output path:

```text
/opt/ai-stack/data/training/runs/persona-v1-qwen35-9b
```

Do not start with a hyperparameter sweep. First confirm the pipeline is valid.

---

## Step 6: Evaluate Before Export

Do not trust loss alone.

Use held-out prompts and compare:

1. the base model output
2. the persona model output

Use the checklist in `guide/AI_PERSONA_EVAL.md`.

Minimum promotion bar:

1. clearly better style match than the base model
2. no obvious verbatim leakage from private chats
3. coherent replies on unseen prompts
4. no repeated stock phrase collapse

If it sounds generic, fix the dataset before trying larger models.

---

## Step 7: Bootstrap llama.cpp

If you have not already prepared the export tooling, run:

```bash
cd services/ai-stack
./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
```

This provides the conversion tooling used by the export helper.

---

## Step 8: Export the Adapter to GGUF

Run:

```bash
cd services/ai-stack
./scripts/export_persona_adapter.sh \
  --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
  --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
  --base-model Qwen/Qwen3.5-9B-Instruct \
  --llama-cpp-dir /opt/llama.cpp
```

Expected output:

```text
/opt/ai-stack/data/training/exports/persona-adapter.gguf
```

---

## Step 9: Deploy Into Ollama

Run:

```bash
cd services/ai-stack
./deploy-persona.sh --model-name persona --force
```

This will:

1. copy the GGUF adapter into the live adapter directory
2. recreate the Ollama service if needed
3. create the `persona` model from `/models/Modelfile.persona`

Quick validation:

```bash
docker exec ai-ollama ollama list
docker exec ai-ollama ollama run persona "hey, what's up?"
```

---

## Step 10: Promote the Model

Only promote after evaluation passes.

Run:

```bash
cd services/ai-stack
./promote-persona-defaults.sh --model-name persona --recreate
```

This updates defaults for OpenClaw and OpenCode to the persona model.

---

## Current Persona Defaults

In this repository, the current persona path is tuned toward shorter, direct
responses rather than long visible reasoning.

That behavior comes from:

- `services/ai-stack/Modelfile.persona.example`
- `services/ai-stack/config/openclaw/config.yaml`
- `services/ai-stack/config/opencode/opencode.json`

If you need even lower latency later, reduce output caps again before changing
the training recipe.

---

## Common Failure Cases

### Generic responses

Likely causes:

- noisy dataset
- incorrect speaker mapping
- too little context
- not enough effective training signal

Try:

1. inspect the dataset again
2. confirm the assistant label is always the target person
3. rerun with a cleaner dataset before moving to a larger base model

### Verbatim copying

Likely causes:

- too many epochs
- too much duplicated text
- dataset too small or repetitive

Try:

1. deduplicate harder
2. reduce epochs
3. hold out repeated catchphrases if needed

### OOM during training

Try:

1. reduce `--max-seq-length` to `1536` or `1024`
2. keep per-device batch size at `1`
3. stop inference workloads during training

### Style is right but facts are wrong

That is expected. Persona LoRA is style transfer, not reliable memory.

---

## One-Pass Command Sequence

Use this when you want the whole flow in one block.

```bash
cd services/ai-stack
sudo ./set-gpu-training.sh
sudo mkdir -p /opt/ai-stack/data/training/{raw,processed,runs,checkpoints,exports}
sudo chown -R "$(id -u):$(id -g)" /opt/ai-stack/data/training

python services/ai-stack/scripts/build_persona_dataset.py \
  --input /opt/ai-stack/data/training/raw/discord-dm.json \
  --output-dir /opt/ai-stack/data/training/processed/persona-v1 \
  --user-id 123456789012345678 \
  --assistant-id 987654321098765432 \
  --max-context-turns 6 \
  --min-context-turns 1 \
  --merge-gap-seconds 180 \
  --validation-ratio 0.1

docker compose --profile training run --rm training

python /repo/services/ai-stack/scripts/train_persona_unsloth.py \
  --model-name Qwen/Qwen3.5-9B-Instruct \
  --train-file /workspace/processed/persona-v1/train.jsonl \
  --valid-file /workspace/processed/persona-v1/valid.jsonl \
  --output-dir /workspace/runs/persona-v1-qwen35-9b \
  --max-seq-length 2048 \
  --per-device-train-batch-size 1 \
  --gradient-accumulation-steps 16 \
  --learning-rate 1e-4 \
  --num-train-epochs 3 \
  --lora-r 16 \
  --lora-alpha 32 \
  --lora-dropout 0.05

cd /repo/services/ai-stack
./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
./scripts/export_persona_adapter.sh \
  --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
  --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
  --base-model Qwen/Qwen3.5-9B-Instruct \
  --llama-cpp-dir /opt/llama.cpp
./deploy-persona.sh --model-name persona --force
./promote-persona-defaults.sh --model-name persona --recreate
```

Do not run the promotion step until the evaluation step passes.