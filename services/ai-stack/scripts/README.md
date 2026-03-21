# AI Stack Script Usage

Operator reference for the persona LoRA workflow scripts in `services/ai-stack`.

This README covers:

- dataset preparation
- baseline Unsloth training
- `llama.cpp` bootstrap for GGUF export
- adapter export
- Ollama deployment
- promoting the persona model into default service configuration

For the broader design and training rationale, see:

- `guide/AI_PERSONA_TRAINING.md`
- `guide/AI_PERSONA_EVAL.md`
- `guide/AI_STACK.md`

---

## Directory Layout

Scripts in this directory:

- `build_persona_dataset.py`
- `train_persona_unsloth.py`
- `bootstrap_llama_cpp.sh`
- `export_persona_adapter.sh`

Related operator helpers in the parent directory:

- `../deploy-persona.sh`
- `../promote-persona-defaults.sh`

---

## Assumptions

This workflow assumes:

- host GPU: NVIDIA RTX 3090 24 GB
- active AI data stored under `/opt/ai-stack/data`
- archive / cold storage available under `/mnt/archive/ai-stack`
- training data stored outside Git under `/opt/ai-stack/data/training`
- live adapters stored under `/opt/ai-stack/data/lora-adapters`
- the AI stack is managed from `services/ai-stack`
- the target persona model is created in Ollama using `Modelfile.persona.example`

Recommended host preparation before training:

```bash
cd services/ai-stack
sudo ./set-gpu-training.sh
sudo mkdir -p /opt/ai-stack/data/training/{raw,processed,runs,checkpoints,exports}
sudo mkdir -p /mnt/archive/ai-stack/{raw-datasets,archived-runs,archived-models,backups}
sudo chown -R "$(id -u):$(id -g)" /opt/ai-stack/data/training
sudo chown -R "$(id -u):$(id -g)" /mnt/archive/ai-stack
```

### Storage recommendation

You can store models and training data on HDD RAID. SSD is not required.

Practical guidance:

- **SSD preferred** for active training data, checkpoints, and frequently switched models
- **HDD RAID fine** for raw exports, archived runs, old adapters, and bulk model storage

The updated compose file uses this split directly:

- active AI paths from `$AI_ACTIVE_DATA_DIR`
- archive storage mounted into the training container at `/archive`

If your active Ollama model store is on HDD RAID, expect slower startup and
model switching, but normal inference speed once the model is already loaded.

---

## End-to-End Flow

The normal order is:

1. build dataset with `build_persona_dataset.py`
2. run LoRA training with `train_persona_unsloth.py`
3. bootstrap `llama.cpp` with `bootstrap_llama_cpp.sh`
4. export the adapter with `export_persona_adapter.sh`
5. deploy the adapter with `../deploy-persona.sh`
6. optionally promote the persona model with `../promote-persona-defaults.sh`

---

## 1. Build Persona Dataset

Script:

- `build_persona_dataset.py`

Purpose:

- convert a Discord DM export into `train.jsonl`, `valid.jsonl`, and `stats.json`

What it expects:

- a Discord export JSON file
- your Discord user ID
- the target person's Discord user ID

What it does:

- locates the message array in the export
- normalizes links, mentions, channels, and custom emoji
- filters the conversation to the two DM participants
- merges consecutive same-author messages within a time gap
- creates context windows where the target person's next reply is the label
- writes chronologically split train and validation files

Basic usage:

```bash
python services/ai-stack/scripts/build_persona_dataset.py \
  --input /opt/ai-stack/data/training/raw/discord-dm.json \
  --output-dir /opt/ai-stack/data/training/processed/persona-v1 \
  --user-id 123456789012345678 \
  --assistant-id 987654321098765432
```

Recommended first run:

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

Outputs:

- `train.jsonl`
- `valid.jsonl`
- `stats.json`

Important flags:

- `--max-context-turns`: upper bound on prior turns included in the prompt
- `--min-context-turns`: minimum prior context required before a sample is emitted
- `--merge-gap-seconds`: merge nearby same-author messages into a single turn
- `--validation-ratio`: chronological holdout percentage
- `--system-prompt`: override the default training-time system prompt
- `--max-samples`: cap sample count for debugging runs

Recommended checks after running:

1. inspect `stats.json`
2. manually read 50 to 100 samples from `train.jsonl`
3. verify the assistant message always belongs to the target person
4. confirm private secrets were not preserved in raw form

---

## 2. Train Persona LoRA

Script:

- `train_persona_unsloth.py`

Purpose:

- run a baseline single-GPU QLoRA fine-tuning job with Unsloth

Runtime requirements:

- `unsloth`
- `datasets`
- `transformers`
- `trl`

The intended place to run this is the training container:

```bash
cd services/ai-stack
docker compose --profile training run --rm training
```

Inside that container, a baseline 9B run looks like this:

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

Key flags:

- `--model-name`: Hugging Face model ID to fine-tune
- `--train-file`: training JSONL path
- `--valid-file`: optional validation JSONL path
- `--output-dir`: where adapter files and `run_config.json` are written
- `--max-seq-length`: start with `2048` on this host
- `--load-in-4bit`: enabled by default
- `--gradient-accumulation-steps`: use this to trade throughput for memory safety
- `--lora-r`, `--lora-alpha`, `--lora-dropout`: primary LoRA tuning controls
- `--target-modules`: defaults target the standard attention and MLP projections

Output directory contents usually include:

- adapter weights
- tokenizer files
- `run_config.json`
- trainer checkpoints if enabled by the trainer settings

Recommended experiment order:

1. run Qwen 3.5 9B first
2. evaluate it with the persona checklist
3. move to 14B only if 9B is still too generic after a clean run

---

## 3. Bootstrap llama.cpp

Script:

- `bootstrap_llama_cpp.sh`

Purpose:

- clone or update `llama.cpp`
- install conversion dependencies
- build the conversion tools with CUDA enabled

Usage:

```bash
cd services/ai-stack
./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
```

Optional flags:

- `--install-dir`: where `llama.cpp` should live
- `--repo-ref`: branch or tag to check out

Requirements on the machine where you run it:

- `git`
- `cmake`
- `python`
- a working compiler toolchain

What it produces:

- a `llama.cpp` checkout
- built tools under the `build` directory
- a working `convert_lora_to_gguf.py`

---

## 4. Export Adapter to GGUF

Script:

- `export_persona_adapter.sh`

Purpose:

- convert the trained LoRA adapter into a GGUF adapter that Ollama can consume

Usage:

```bash
cd services/ai-stack
./scripts/export_persona_adapter.sh \
  --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
  --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
  --base-model Qwen/Qwen3.5-9B-Instruct \
  --llama-cpp-dir /opt/llama.cpp
```

Important flags:

- `--adapter-dir`: directory containing the trained PEFT adapter
- `--output-file`: output GGUF adapter path
- `--base-model`: base model identifier passed to the converter
- `--llama-cpp-dir`: path containing `convert_lora_to_gguf.py`

Common failure causes:

- wrong `--base-model`
- missing `convert_lora_to_gguf.py`
- adapter directory does not contain the expected LoRA files

---

## 5. Deploy Persona Model to Ollama

Script:

- `../deploy-persona.sh`

Purpose:

- copy the exported GGUF adapter into the live adapter directory
- recreate `ollama`
- create the custom persona model from `/models/Modelfile.persona`

Usage:

```bash
cd services/ai-stack
./deploy-persona.sh --model-name persona --force
```

Alternative usage with an explicit export path:

```bash
cd services/ai-stack
./deploy-persona.sh \
  --adapter-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
  --model-name persona-dev \
  --force
```

Flags:

- `--adapter-file`: exported adapter to deploy
- `--model-name`: Ollama model name to create
- `--force`: remove the existing Ollama model first if it already exists

What it assumes:

- `.env` exists or defaults are acceptable
- the Ollama service mounts `/lora-adapters` and `/models/Modelfile.persona`
- `ai-ollama` is the container name

Quick validation after deployment:

```bash
docker exec ai-ollama ollama list
docker exec ai-ollama ollama run persona "hey, what's up?"
```

---

## 6. Promote Persona as the Default Model

Script:

- `../promote-persona-defaults.sh`

Purpose:

- update `.env` to make the persona model the default for OpenClaw and OpenCode
- optionally recreate those services immediately

Usage:

```bash
cd services/ai-stack
./promote-persona-defaults.sh --model-name persona --recreate
```

Flags:

- `--env-file`: alternate env file
- `--model-name`: deployed persona model name
- `--recreate`: run `docker compose up -d openclaw opencode` after updating `.env`

What it changes:

- `OPENCLAW_DEFAULT_MODEL=persona`
- `OPENCODE_MODEL=ollama/persona`

Safety behavior:

- creates a timestamped backup of the target env file before editing

---

## Full Example

This is the shortest sensible operator sequence for a first run:

```bash
# Prepare training storage and GPU mode
cd services/ai-stack
sudo ./set-gpu-training.sh
sudo mkdir -p /opt/ai-stack/data/training/{raw,processed,runs,checkpoints,exports}
sudo chown -R "$(id -u):$(id -g)" /opt/ai-stack/data/training

# Build dataset
python services/ai-stack/scripts/build_persona_dataset.py \
  --input /opt/ai-stack/data/training/raw/discord-dm.json \
  --output-dir /opt/ai-stack/data/training/processed/persona-v1 \
  --user-id 123456789012345678 \
  --assistant-id 987654321098765432 \
  --max-context-turns 6 \
  --merge-gap-seconds 180

# Enter training container
cd services/ai-stack
docker compose --profile training run --rm training

# Train adapter inside the container
python /repo/services/ai-stack/scripts/train_persona_unsloth.py \
  --model-name Qwen/Qwen3.5-9B-Instruct \
  --train-file /workspace/processed/persona-v1/train.jsonl \
  --valid-file /workspace/processed/persona-v1/valid.jsonl \
  --output-dir /workspace/runs/persona-v1-qwen35-9b

# Leave the container, then bootstrap conversion tooling on the host
cd services/ai-stack
./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp

# Export GGUF adapter
./scripts/export_persona_adapter.sh \
  --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
  --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
  --base-model Qwen/Qwen3.5-9B-Instruct \
  --llama-cpp-dir /opt/llama.cpp

# Deploy and promote
./deploy-persona.sh --model-name persona --force
./promote-persona-defaults.sh --model-name persona --recreate

# Return GPU to normal inference mode
sudo ./set-gpu-inference.sh
```

---

## Troubleshooting

### Dataset builder emits too few samples

Check:

- the `--user-id` and `--assistant-id` values
- whether the export actually contains only one DM thread
- whether too many messages were removed during normalization

Try:

- reducing `--min-context-turns`
- increasing `--merge-gap-seconds`
- inspecting `stats.json`

### Training is too slow or runs out of memory

Try:

- lowering `--max-seq-length`
- lowering `--per-device-train-batch-size`
- increasing `--gradient-accumulation-steps`
- stopping inference services during training
- using 9B before attempting 14B

### Export fails

Check:

- `bootstrap_llama_cpp.sh` completed successfully
- `--llama-cpp-dir` points at the correct checkout
- `--base-model` matches the base used for training

### Deployment succeeds but the model is missing

Check:

- `docker exec ai-ollama ollama list`
- the live adapter file exists under `/opt/ai-stack/data/lora-adapters`
- `docker compose up -d ollama` completed successfully

### Promotion changes `.env` but services still use the old model

Recreate the affected services:

```bash
cd services/ai-stack
docker compose up -d openclaw opencode
```

---

## Recommended Operator Habit

For each training run, keep these together:

- dataset version name
- base model name
- exact training command
- export command
- evaluation notes
- promotion decision

That is the minimum you need to compare 9B and 14B runs properly instead of
guessing from memory.