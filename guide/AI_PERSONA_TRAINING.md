# Persona LoRA Training Plan — Discord DM Dataset

Comprehensive training plan for building a persona adapter from Discord DM
history on the existing homelab AI stack.

This guide assumes the hardware and stack documented in
`guide/AI_STACK.md`:

- **Host OS**: Rocky Linux 10.x
- **GPU**: NVIDIA RTX 3090 24 GB
- **RAM**: 64 GB ECC
- **Inference stack**: Ollama + Open WebUI + OpenClaw + OpenCode
- **Target runtime**: Ollama custom model using a GGUF LoRA adapter

---

## Table of Contents

1. [Goal](#goal)
2. [Reality Check](#reality-check)
3. [Best Base Model for This Setup](#best-base-model-for-this-setup)
4. [Recommended Tooling](#recommended-tooling)
5. [Data Ownership and Privacy](#data-ownership-and-privacy)
6. [Training Architecture](#training-architecture)
7. [Dataset Preparation Plan](#dataset-preparation-plan)
8. [Dataset Format](#dataset-format)
9. [Training Hyperparameters](#training-hyperparameters)
10. [Training Procedure](#training-procedure)
11. [Evaluation Plan](#evaluation-plan)
12. [Export and Deployment](#export-and-deployment)
13. [Operational Runbook](#operational-runbook)
14. [Failure Modes](#failure-modes)
15. [Recommended Directory Layout](#recommended-directory-layout)
16. [Command Sequence](#command-sequence)
17. [What to Build Next in This Repo](#what-to-build-next-in-this-repo)

---

## Goal

Train a **LoRA persona adapter** from a Discord DM conversation so a Qwen-based
assistant can respond in a way that resembles one specific person's:

- tone
- phrasing
- reply length
- slang and emoji habits
- conversational pacing
- common response patterns

This is a **style and response-shape adaptation** task, not full personality
reconstruction.

The intended final path for this repository is:

1. Export Discord DM history
2. Convert it into supervised chat examples
3. Train a LoRA adapter in a GPU container
4. Export the adapter to GGUF
5. Create an Ollama custom model from the base model plus adapter
6. Use that custom model from Open WebUI or OpenClaw

---

## Reality Check

For a dataset of about **4,000 messages**, the main constraint is not just GPU
capacity. The bigger constraint is that this is still a relatively small corpus.

What a dataset this size can do well:

- teach writing style
- teach short-form conversational rhythm
- bias the model toward specific word choices and recurring expressions
- improve realism on familiar chat situations

What it usually cannot do reliably on its own:

- produce a faithful simulation of a real person's full beliefs or knowledge
- remain consistent on subjects not present in the dataset
- preserve stable long-term persona facts without prompting support
- replace retrieval or system prompts for factual grounding

The correct target is therefore:

- **strong style transfer**
- **moderate conversational behavior shaping**
- **limited factual persona grounding**

---

## Best Base Model for This Setup

### Recommendation

Use **Qwen 3.5 9B Instruct** as the primary LoRA training base on this host.

Optional second pass:

- try **Qwen 3.5 14B Instruct** only if the 9B result is clearly insufficient
- keep **Qwen 3.5 27B** as an inference model, not the first fine-tuning target

### Short answer on 9B vs 14B

No, I am **not absolutely sure** that 9B will beat 14B in final quality.

What I am confident about is this:

- **9B is the better first experiment on your current hardware**
- **14B is the better second experiment if 9B underfits**
- **27B is not the right starting point for this dataset and GPU**

That distinction matters. There is a difference between:

- the model most likely to produce the best final quality in a perfect run
- the model most likely to produce the best outcome per hour of effort on a 3090

For your setup, 9B wins the second category clearly. 14B may or may not win the
first category, but not by enough margin to justify starting there.

### 9B vs 14B decision table

| Factor | Qwen 3.5 9B Instruct | Qwen 3.5 14B Instruct |
|--------|-----------------------|------------------------|
| QLoRA fit on RTX 3090 24 GB | Comfortable | Tighter but plausible |
| Training speed | Faster | Slower |
| Iteration cost | Lower | Higher |
| Risk of VRAM-related friction | Lower | Higher |
| Tolerance for longer context and experiments | Better | Worse |
| Potential style ceiling | Good | Potentially higher |
| Best use in this project | First baseline | Second-pass experiment |

### When 14B is the better choice

Move to 14B after a 9B run if:

- the 9B model stays too generic after the dataset is cleaned up
- your evaluation set shows underfitting rather than overfitting
- the 9B model misses style markers consistently across held-out prompts
- you are satisfied with the dataset format and want to spend more GPU time on one better run

Do not move to 14B just because it is larger. Move only after 9B tells you that
the bottleneck is model capacity rather than data quality.

### Why I still recommend starting with 9B

For persona LoRA on a relatively small DM corpus, the biggest quality drivers are:

1. correct speaker mapping
2. good context-window construction
3. duplicate removal
4. avoiding privacy-leaking memorization
5. evaluation on held-out prompts

Those are much easier to iterate on with 9B than 14B.

In other words: if the first run is wrong, it is more likely that the data
pipeline is wrong than that 9B is too small.

### Why 9B is the right first choice on a 3090

1. **24 GB VRAM is enough for comfortable QLoRA on 9B**.
2. **Training is faster**, so iteration on formatting and hyperparameters is realistic.
3. **4,000 messages is small enough that data quality dominates model size early**.
4. Persona fine-tuning quality depends heavily on dataset shape, and 9B lets you
   iterate on the data pipeline instead of fighting memory limits.
5. **If 9B underfits after a clean run, 14B remains available as the next test**.

### Recommended experiment order

Use this order on your homelab:

1. run **Qwen 3.5 9B Instruct** as the baseline persona LoRA
2. evaluate it with the checklist in `guide/AI_PERSONA_EVAL.md`
3. move to **Qwen 3.5 14B Instruct** only if the evidence points to underfitting
4. keep the better of the two based on held-out style evaluation, not intuition

This is the correct engineering sequence. It minimizes wasted GPU time while
still giving you a path to test whether 14B actually earns its cost.

### Why not start with 27B

On this hardware, 27B QLoRA is the wrong first move for this task:

- memory headroom is tight
- throughput is much worse
- the dataset is small for a model that large
- debugging formatting mistakes becomes expensive
- gains over a well-trained 9B adapter are unlikely to justify the cost

If later you move training to a 48 GB to 80 GB GPU host, 27B becomes more
reasonable. On the current homelab box, 9B is the practical choice.

---

## Recommended Tooling

### Primary trainer

Use **Unsloth** for the first implementation.

Why:

- good fit for single-GPU QLoRA workflows
- simpler bring-up than a heavier distributed training stack
- strong community usage for small and medium SFT jobs
- good match for fast iteration on persona data formatting

### Alternative

Use **Axolotl** if you later want:

- more configurable training recipes
- more standardized YAML-driven experiment management
- easier transition to more advanced fine-tuning setups

For this repository and this training goal, **Unsloth first** is the better plan.

### Supporting tools

- **Python**: dataset conversion and validation
- **llama.cpp tools**: export LoRA adapter to GGUF
- **Ollama**: create the final persona model
- **Prometheus + Grafana**: observe GPU thermals and utilization during runs

---

## Data Ownership and Privacy

Before training, treat the Discord export as sensitive data.

Required safeguards:

- remove secrets, tokens, API keys, addresses, phone numbers, and unique IDs
- remove or anonymize third-party private data
- avoid training on content without clear consent if it represents a real person
- store raw exports outside the Git repository
- keep cleaned datasets in a dedicated training directory with restricted permissions

Recommended substitutions during preprocessing:

- links -> `[LINK]`
- user mentions -> `[USER]`
- channel references -> `[CHANNEL]`
- images and attachments -> `[ATTACHMENT]`
- custom emoji IDs -> normalized emoji text or `[EMOJI]`

Do not rely on LoRA alone to forget sensitive information. Small persona datasets
can be memorized surprisingly easily.

---

## Training Architecture

This homelab already has the right separation of concerns:

- **training** happens in a dedicated GPU container
- **inference** stays in Ollama
- **serving** stays in Open WebUI / OpenClaw / OpenCode
- **adapter artifacts** live under the AI data directory and are backed up separately

Recommended flow:

```text
Discord export
  -> cleaning + normalization
  -> conversation window builder
  -> JSONL / chat dataset
  -> Unsloth QLoRA training
  -> LoRA adapter
  -> GGUF export
  -> Ollama custom model
  -> OpenClaw / Open WebUI inference
```

### Why training must be isolated from inference

During LoRA runs you want:

- maximum VRAM headroom
- full 350 W GPU power limit
- no model eviction conflicts from Ollama
- clear logs and reproducibility

Do not train while the main inference stack is actively serving users.

---

## Dataset Preparation Plan

### Input assumption

You have a Discord DM export containing:

- a timestamp per message
- message author ID
- message content

You also know:

- **your Discord user ID**
- **the target person's Discord user ID**

### Training objective

Train the model to predict the **target person's next reply** from the recent
conversation context.

That means:

- the target person becomes the **assistant** in the training examples
- all previous turns become the prompt context
- only messages written by the target person are used as labels

### Correct sample construction

Good sample:

```text
User: are you still awake
Assistant: yeah
User: server died again
Assistant: of course it did, give me five minutes
```

Bad sample:

```text
Assistant: of course it did, give me five minutes
```

The model needs the preceding turns to learn when that kind of reply is used.

### Windowing strategy

Build training examples using a rolling context window:

- previous **3 to 12 turns** as input
- target person's next message as output
- start with **6 turns max** for the first dataset version

This balances:

- enough context for natural replies
- manageable sequence length on a 3090

### Filtering rules

Keep:

- normal conversational messages
- stylistically important short replies if they are common
- emoji and punctuation habits when they matter for style

Drop or separately tag:

- reactions with no text
- pure attachment messages unless converted to placeholders
- obvious spam or accidental duplicates
- bot messages
- quoted logs or pasted dumps unless those are central to the persona

### Normalize carefully

Normalize platform noise, not the person's style.

Normalize:

- URLs
- mentions
- attachment URLs
- Discord-specific metadata

Preserve:

- casing habits
- spelling quirks
- punctuation habits
- repeated letters
- emoji use
- common abbreviations and slang

### Dataset split

Use a **chronological split**, not random message-level splitting.

Recommended:

- first 85 to 90 percent -> training
- last 10 to 15 percent -> validation

Why:

- random splitting leaks nearby context into validation
- chronological splitting better reflects future usage

---

## Dataset Format

For this project, use a simple JSONL chat format that can be mapped cleanly into
the target model's chat template.

Recommended shape per line:

```json
{"messages":[
  {"role":"system","content":"Match the assistant's conversational style from the examples while staying coherent and helpful."},
  {"role":"user","content":"[2025-12-01 22:01] me: are you still awake\n[2025-12-01 22:02] them: yeah\n[2025-12-01 22:03] me: server died again"},
  {"role":"assistant","content":"of course it did, give me five minutes"}
]}
```

Notes:

- Keep the system prompt generic and short.
- Do not bake highly specific biography claims into every sample.
- The user block can be a compact transcript string.
- The assistant block must be only the target person's reply.

### Multi-message target replies

If the target person sends two or more consecutive messages that are really one
reply, merge them into one assistant target when they occur within a short time
window, for example **under 2 to 5 minutes** and with no interleaving message.

This usually improves realism.

---

## Training Hyperparameters

Start conservative. Small persona datasets overfit quickly.

### Baseline recipe for Qwen 3.5 9B Instruct

- load in **4-bit**
- use **QLoRA**
- LoRA rank: **16** or **32**
- LoRA alpha: **32** or **64**
- LoRA dropout: **0.05**
- target modules:
  - `q_proj`
  - `k_proj`
  - `v_proj`
  - `o_proj`
  - `gate_proj`
  - `up_proj`
  - `down_proj`
- max sequence length: **2048** to start
- micro batch size: **1 to 2**
- gradient accumulation: **8 to 32**
- effective epochs: **2 to 4**
- learning rate: **1e-4** or **2e-4**
- warmup ratio: **0.03 to 0.05**
- optimizer: **adamw_8bit**
- scheduler: **cosine** or **linear**

### Starting point I would actually use

- rank: `16`
- alpha: `32`
- dropout: `0.05`
- seq length: `2048`
- lr: `1e-4`
- epochs: `3`

This is a safer first run for a small conversational style dataset.

### When to increase model capacity or LoRA rank

Only increase complexity if the first model clearly underfits.

Signals of underfitting:

- replies are too generic
- the tone is still mostly base-model tone
- style markers from the target person rarely appear

Signals of overfitting:

- repeated phrases across unrelated prompts
- verbatim copying from the training set
- unnatural stubborn tone even in contexts where it does not fit

---

## Training Procedure

### Phase 1: Prepare the host

1. Set the GPU to training mode:

   ```bash
   cd services/ai-stack
   sudo ./set-gpu-training.sh
   ```

2. Ensure the inference stack is idle or stopped if VRAM pressure becomes an issue.

3. Create persistent training directories outside Git:

   ```bash
   sudo mkdir -p /opt/ai-stack/data/training/{raw,processed,runs,checkpoints,exports}
   sudo chown -R "$(id -u):$(id -g)" /opt/ai-stack/data/training
   ```

### Phase 2: Clean and build the dataset

1. Place the raw Discord export under:

   ```text
   /opt/ai-stack/data/training/raw/
   ```

2. Run a preprocessing script that:

- loads the Discord export
- sorts messages chronologically
- filters to a single DM conversation
- maps your messages to `user`
- maps the target person's messages to `assistant`
- builds rolling context windows
- normalizes Discord-specific artifacts
- writes `train.jsonl` and `valid.jsonl`

The repository now includes a baseline converter script:

For the full operator reference covering all helper scripts in one place, see
`services/ai-stack/scripts/README.md`.

```bash
python services/ai-stack/scripts/build_persona_dataset.py \
   --input /opt/ai-stack/data/training/raw/discord-dm.json \
   --output-dir /opt/ai-stack/data/training/processed/persona-v1 \
   --user-id 123456789012345678 \
   --assistant-id 987654321098765432 \
   --max-context-turns 6 \
   --min-context-turns 1 \
   --merge-gap-seconds 180
```

Outputs:

- `train.jsonl`
- `valid.jsonl`
- `stats.json`

3. Validate the processed dataset manually before training:

- inspect 50 to 100 random samples
- verify speaker roles are correct
- confirm the assistant target is always the target person
- verify no secrets remain

### Phase 3: Train the adapter

1. Launch the dedicated training container.

   ```bash
   cd services/ai-stack
   docker compose --profile training run --rm training
   ```

   The training service now starts as `root` and auto-normalizes
   `transformers` to `5.2.0` for the `Qwen/Qwen3.5-9B` workflow before dropping
   you into a shell.

2. Mount:

- processed dataset directory
- run output directory
- export directory

3. Train one baseline experiment first.
4. Do not start by sweeping many hyperparameters.

The repository now includes a baseline Unsloth training script:

```bash
python /repo/services/ai-stack/scripts/train_persona_unsloth.py \
   --model-name Qwen/Qwen3.5-9B \
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

If you need to do the dependency adjustment manually, the equivalent commands are:

```bash
pip uninstall -y transformers
pip install --no-cache-dir "transformers==5.2.0"
```

This can leave the bundled `vllm` package version-mismatched inside the training
container, which is acceptable for a training-only session.

### Phase 4: Evaluate the result

1. Run held-out prompts manually.
2. Compare outputs against real validation replies.
3. Look for style match, not just coherence.

Use the dedicated checklist in `guide/AI_PERSONA_EVAL.md` for scoring and
promotion decisions.

### Phase 5: Export and deploy

1. Convert the adapter to GGUF.
2. Deploy it into the live `lora-adapters` path.
3. Create the Ollama custom model.
4. Switch OpenClaw or Open WebUI to the new model.

---

## Evaluation Plan

Do not trust training loss alone. Persona work needs human evaluation.

Create a held-out prompt set with about **50 to 100 prompts** covering:

- greetings
- casual chatting
- planning
- tech troubleshooting
- teasing or humor
- disagreement or frustration
- short-response situations
- long-response situations

Score each output on:

1. **Style match**
2. **Naturalness**
3. **Context fit**
4. **Overfitting / memorization risk**
5. **Stability across unseen topics**

### Success criteria

The model is good enough to keep if it:

- sounds recognizably closer to the target person than the base model
- does not constantly quote exact training lines
- remains coherent on held-out prompts
- does not collapse into one repeated tone pattern

### Failure criteria

Retrain or adjust if it:

- memorizes exact lines from private chats
- responds with the same stock phrases too often
- ignores context and defaults to style mimicry only
- becomes much worse than the base model on basic coherence

---

## Export and Deployment

The repository already expects an exported GGUF LoRA adapter and an Ollama
Modelfile.

Reference:

- `services/ai-stack/Modelfile.persona.example`

Expected deployment flow:

1. Export the adapter to GGUF using llama.cpp tooling.
2. Place it under:

   ```text
   /opt/ai-stack/data/lora-adapters/persona-adapter.gguf
   ```

3. Mount the adapter directory and Modelfile into the Ollama container.
4. Create the custom model:

   ```bash
   docker exec ai-ollama ollama create persona -f /models/Modelfile.persona
   ```

5. Test the model in Ollama directly.
6. Point OpenClaw or Open WebUI to `persona:latest`.

The repository now includes:

- `services/ai-stack/scripts/export_persona_adapter.sh` for GGUF export
- `services/ai-stack/deploy-persona.sh` for copying the adapter and creating the Ollama model

Example export command:

```bash
cd services/ai-stack
./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp

cd services/ai-stack
./scripts/export_persona_adapter.sh \
   --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
   --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
   --base-model Qwen/Qwen3.5-9B \
   --llama-cpp-dir /opt/llama.cpp
```

Example deployment command:

```bash
cd services/ai-stack
./deploy-persona.sh --model-name persona --force
```

After promoting a successful persona run, you can also switch client defaults:

- set `OPENCLAW_DEFAULT_MODEL=persona` in `.env`
- set `OPENCODE_MODEL=ollama/persona` in `.env`
- recreate the affected services with `docker compose up -d openclaw opencode`

The repository also includes a helper for this:

```bash
cd services/ai-stack
./promote-persona-defaults.sh --model-name persona --recreate
```

---

## Operational Runbook

### Before each training run

- verify host `nvidia-smi`
- switch GPU to 350 W mode
- confirm enough free disk space in `/opt/ai-stack/data/training`
- ensure processed dataset version is recorded
- record the exact base model and hyperparameters

### During training

- watch GPU memory usage
- watch GPU temperature and power draw
- save trainer logs per run
- checkpoint periodically if the trainer supports it

### After training

- archive config, logs, and metrics with the run output
- score the run before starting another one
- only change one or two variables per next experiment
- switch the GPU back to inference mode if training is complete

---

## Failure Modes

### 1. The model sounds generic

Likely causes:

- too little context in the prompt windows
- dataset too noisy
- learning rate too low
- not enough training steps

Try:

- cleaner windows
- better assistant-target alignment
- one more epoch
- higher LoRA rank only after data issues are ruled out

### 2. The model copies exact lines

Likely causes:

- too many epochs
- dataset too small or too repetitive
- too much near-duplicate text

Try:

- lower epochs
- deduplicate more aggressively
- hold out repeated catchphrases from training if needed

### 3. Training runs out of memory

Likely causes:

- sequence length too high
- batch size too high
- inference containers still using VRAM

Try:

- reduce seq length to `1536` or `1024`
- reduce micro batch size to `1`
- stop inference workloads during training

### 4. Replies match style but make up facts

This is expected. LoRA is not a reliable long-term memory mechanism.

Use:

- a system prompt for persona boundaries
- retrieval for fixed profile facts
- explicit inference-time instructions for tone and behavior

---

## Recommended Directory Layout

Use host storage, not Git, for raw and processed training data:

```text
/opt/ai-stack/data/
├── ollama/
├── open-webui/
├── openclaw/
├── opencode/
├── lora-adapters/
└── training/
    ├── raw/
    ├── processed/
    ├── runs/
    ├── checkpoints/
   └── exports/

/mnt/archive/ai-stack/
├── raw-datasets/
├── archived-runs/
├── archived-models/
└── backups/
```

Recommended contents:

- `raw-datasets/` -> long-term raw dataset archive on HDD RAID
- `archived-runs/` -> completed runs moved off SSD
- `raw/` -> active copy of the original Discord export during preprocessing
- `processed/` -> cleaned `train.jsonl` and `valid.jsonl`
- `runs/` -> logs, config snapshots, metrics
- `checkpoints/` -> trainer checkpoints
- `exports/` -> final adapter exports before copying to `lora-adapters/`

### Storage recommendation for this workflow

For persona LoRA work, storage class matters for convenience more than raw model
quality.

Recommended split:

- **SSD strongly preferred**: `/opt/ai-stack/data/training/processed`, `/opt/ai-stack/data/training/runs`, `/opt/ai-stack/data/training/checkpoints`, active export workspace
- **HDD RAID acceptable**: `/opt/ai-stack/data/training/raw`, archived runs, exported adapters after deployment, bulk model archive

If `ollama/` lives on HDD RAID, inference will still work correctly. The main
cost is slower model loading and slower model switching.

In the split layout used by the updated compose file:

- `$AI_ACTIVE_DATA_DIR` is the SSD-backed working set
- `$AI_ARCHIVE_DATA_DIR` is mounted into the training container at `/archive`
- move cold artifacts from `/workspace` to `/archive` after evaluation is complete

---

## Command Sequence

This is the intended end-to-end operator sequence on this homelab.

```bash
# 1. Prepare the GPU for training
cd services/ai-stack
sudo ./set-gpu-training.sh

# 2. Create the training workspace
sudo mkdir -p /opt/ai-stack/data/training/{raw,processed,runs,checkpoints,exports}
sudo chown -R "$(id -u):$(id -g)" /opt/ai-stack/data/training

# 3. Put the raw Discord export under:
#    /opt/ai-stack/data/training/raw/

# 4. Run preprocessing
python services/ai-stack/scripts/build_persona_dataset.py \
   --input /opt/ai-stack/data/training/raw/discord-dm.json \
   --output-dir /opt/ai-stack/data/training/processed/persona-v1 \
   --user-id 123456789012345678 \
   --assistant-id 987654321098765432

# 5. Start the training container
cd services/ai-stack
docker compose --profile training run --rm training

# 6. Run baseline training inside the container
python /repo/services/ai-stack/scripts/train_persona_unsloth.py \
   --model-name Qwen/Qwen3.5-9B \
   --train-file /workspace/processed/persona-v1/train.jsonl \
   --valid-file /workspace/processed/persona-v1/valid.jsonl \
   --output-dir /workspace/runs/persona-v1-qwen35-9b

# 7. Export the trained adapter to GGUF
cd services/ai-stack
./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
./scripts/export_persona_adapter.sh \
  --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
  --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
   --base-model Qwen/Qwen3.5-9B \
  --llama-cpp-dir /opt/llama.cpp

# 8. Copy it into the live adapter path
cd services/ai-stack
./deploy-persona.sh --model-name persona --force

# 9. Create the Ollama model
#    handled by deploy-persona.sh

# 10. Test the resulting model
docker exec ai-ollama ollama run persona "hey, what's up?"

# 11. Return the GPU to inference mode after training
sudo ./set-gpu-inference.sh
```

---

## What to Build Next in This Repo

This guide is the plan. The following implementation pieces are still the next
concrete steps:

1. add a model smoke-test script for post-deploy validation

Suggested implementation order:

1. post-deploy smoke tests

That sequence minimizes wasted training time by making the dataset pipeline
correct before spending GPU hours.