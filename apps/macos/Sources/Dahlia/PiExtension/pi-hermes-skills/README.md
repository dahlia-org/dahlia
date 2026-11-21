# pi-hermes-skills

Hermes Agent's skill features for [Pi](https://pi.dev). Skills are kept up to date from your conversations, curated
when unused, and improved on request.

> **Model calls in the background.** After every 10 responses that used tools, a skill review starts a separate Pi process
> with the session's model and history, and may create or edit skills. Set `hermesSkills.review.enabled` to `false` to
> turn this off. Everything else runs only when you or your scheduler ask.

- **Skill index**: Pi's skill listing becomes one `- name: description` line per skill within 1% of the context window.
  Over budget, the least recently used skills are shortened first; every name stays listed.
- **Skill tools**: `skills_list`, `skill_view` and `skill_manage` over `skills/` in Pi's agent directory. Skills Pi lists
  from elsewhere are read-only. Content is scanned for prompt injection before it is saved.
- **Usage records**: `skill_view`, a `/skill:` command, or a `read` of a listed skill file counts as a use, in
  `skills/.usage.json` (the format of Hermes Agent's `.usage.json`). The index orders skills by these records.
- **Skill reviews**: the background review above. It only creates, edits or archives skills; it stops after 16
  responses, 75% of the context window, or 10 minutes.
- **Curator**: `/hermes-curator` marks agent-created skills stale after 14 days unused and archives them after 30
  (`skills/.archive/`, never deleted). Pinned and locked skills, and skills you wrote, are left alone.
  `/hermes-curator restore <name>`, `pin <name>` and `unpin <name>` undo or protect.
- **`skill_optimize`**: improves one unlocked account skill with GEPA (hermes-agent-self-evolution) from this directory's other sessions,
  with hundreds of model calls; the model starts it only when you ask. The result replaces the skill only after you
  confirm; without a UI it is saved as `SKILL.md.optimized`.
- **`/learn`**: writes a skill from what you point it at (a directory, a URL, notes, or this conversation).

## Scheduling the Curator

Pi has no resident process, so run the Curator from a scheduler, for example weekly with cron:

```sh
0 9 * * 1 cd ~/project && pi -p --no-session "/hermes-curator"
```

Run it when you are not in the middle of a session; Hermes Agent waits for 2 idle hours.

## Settings

In Pi's `settings.json`:

```json
{
  "hermesSkills": {
    "index": { "budget": null },
    "review": { "enabled": true, "interval": 10, "model": null },
    "curator": { "enabled": true, "staleAfterDays": 14, "archiveAfterDays": 30, "consolidate": false, "model": null },
    "optimizer": { "enabled": true }
  }
}
```

- `index.budget`: characters for the listing. `null` uses 1% of the context window (4 characters per token).
- `review.interval`: tool-calling responses between reviews; `0` or `enabled: false` turns reviews off. `model` is
  `provider/id`; `null` uses the session's model.
- `curator.consolidate`: also merge overlapping agent-created skills with a model, in a separate Pi process (up to 100
  responses or 30 minutes).
- `optimizer.enabled`: `false` removes `skill_optimize`.

`PI_SKILL_INDEX_BUDGET` and `PI_SKILL_INDEX_RANK` (comma-separated names, most recent first) override the budget and the
order from records.

## Embedding

`registerHermesSkills(pi, host)` lets another extension keep records in its own store (`host.store`), run the skill tools
itself (`host.tools`), supply the order (`host.rank`), schedule reviews and consolidation itself (`host.review`,
`host.curator`), and run the optimizer on its own data and approval flow (`host.optimizer`). `false` leaves a part out.

## License

MIT. The upstream prompts, schemas, patterns and their licenses are in `hermes/`; see `hermes/UPSTREAM.md`.
