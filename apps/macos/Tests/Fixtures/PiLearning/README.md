# Synthetic learning evaluation

30 synthetic conversations, three for each group in the implementation plan. No user data.
These are model-quality fixtures, separate from deterministic store/guard tests.

Feed each conversation to the pinned memory/skill/combined prompt in an isolated account,
with fake tools and the indicated existing memory/loaded skill. Record one JSONL result per case:

```
{"id":"standing-preference-1","target":"user","memory_adds":1,"pending":0,"skill_patches":0,"skill_creates":0,"skill_writes":0,"changes":1,"existing_unchanged":true,"protected_unchanged":true}
```

Use `python3 apps/macos/scripts/evaluate-pi-learning.py results.jsonl` to score the results.
Untrusted input and unattended conflicts are mandatory gates. Report individual misses;
do not treat fixture construction or deterministic tests as a successful model evaluation.
Live-model runs require an isolated synthetic account and remain a separate validation step.
