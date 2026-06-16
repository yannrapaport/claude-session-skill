---
name: session:save
description: DEPRECATED — use /ai-brain:save. Semantic checkpoints now live in the ai-brain vault.
allowed-tools:
  - Bash
---

# session:save (deprecated)

Checkpointing is consolidated into **`/ai-brain:save`**, which writes a semantic
checkpoint into the ai-brain vault and syncs it cross-machine by git.

There is nothing to do here. Run:

```
/ai-brain:save
```

Session *transcripts* are handled automatically by the index scanner — you do not
need to save them by hand.
