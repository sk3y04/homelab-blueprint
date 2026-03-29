# Persona Model Evaluation Checklist

Manual evaluation checklist for a Discord DM persona LoRA trained on the
homelab AI stack.

Use this after each training run before promoting a persona model into regular
use in Ollama, Open WebUI, or OpenClaw.

---

## Goal

Check whether the model:

- sounds recognizably like the target person
- stays coherent outside memorized examples
- avoids verbatim leakage from private conversations
- handles short and long replies naturally

---

## Test Setup

Before evaluating:

1. Use held-out prompts not included in the training set.
2. Compare outputs from the base model and the persona model.
3. Keep temperature, top_p, and top_k fixed during comparison.
4. Log the prompt, output, and score for each test case.
5. Keep `stats.json` from the dataset run nearby and compare generations against `style_stats`, not just against your intuition.

Recommended sample size:

- **50 to 100 prompts** for a serious run review
- **10 to 20 prompts** for a quick smoke test

---

## Prompt Categories

### 1. Casual Check-ins

- `hey, you awake?`
- `what are you up to?`
- `how's your day going?`

### 2. Planning / Coordination

- `can you do tonight instead of tomorrow?`
- `what time should we leave?`
- `did you already handle that?`

### 3. Humor / Teasing

- `be honest, how badly did I break it this time?`
- `you know this is somehow your fault, right?`

### 4. Friction / Disagreement

- `that makes no sense`
- `you said you'd do it already`
- `why are you being weird about this?`

### 5. Tech / Problem Solving

- `the server is down again`
- `I think Docker broke after the update`
- `why is the GPU running hot?`

### 6. Longer Reflective Replies

- `what do you actually think we should do here?`
- `can you explain why that bothered you?`

---

## Scoring Rubric

Score each response from **1 to 5**.

### Style Match

- `1` = does not resemble the target person
- `3` = somewhat similar in tone but generic
- `5` = clearly recognizable style match

### Naturalness

- `1` = awkward or obviously synthetic
- `3` = acceptable but uneven
- `5` = reads like a real DM reply

### Chaotic DM Style Match

- `1` = too polished, too grammatical, or too paragraph-like
- `3` = some casual markers appear but the output still feels cleaned up
- `5` = message length, segmentation, lowercase habits, and roughness match the target's DM style

### Context Fit

- `1` = ignores the prompt context
- `3` = partially fits
- `5` = fits the situation naturally

### Memorization Risk

- `1` = appears to copy private lines directly
- `3` = maybe echoes a few phrases
- `5` = no obvious verbatim leakage

### Generalization

- `1` = collapses outside seen topics
- `3` = mixed performance
- `5` = stable tone even on unseen prompts

---

## Failure Flags

Reject or retrain the model if you observe any of these repeatedly:

- exact reuse of private chat lines
- strong repetition across unrelated prompts
- tone that is too exaggerated compared with the real person
- reduced coherence compared with the base model
- inability to answer simple held-out prompts naturally
- outputs that are consistently too polished compared with dataset `style_stats`
- outputs that collapse fragmented DM bursts into one neat sentence every time

---

## Review Sheet Template

| Prompt | Base Model Notes | Persona Output Notes | Style | Naturalness | Context | Leakage | Generalization |
|--------|------------------|----------------------|-------|-------------|---------|---------|----------------|
| `hey, you awake?` | generic | closer to target tone | 4 | 4 | 5 | 5 | 4 |

Suggested pass threshold:

- average **Style Match >= 4.0**
- average **Naturalness >= 4.0**
- average **Memorization Risk >= 4.5**

For chaotic Polish DM targets, also compare the held-out generations against
dataset `style_stats` for:

- short-message frequency
- lowercase-only frequency
- no-diacritic frequency
- `??` burst frequency
- repeated-character frequency
- marker counts like `xd`, `xddd`, `nw`, `serio`, `kirwa`

If style improves but leakage risk drops, do not promote the model.

---

## Promotion Decision

Promote the persona model only if:

1. it clearly beats the base model on style
2. it does not leak private lines
3. it remains coherent on held-out prompts
4. it is stable across at least two separate evaluation passes