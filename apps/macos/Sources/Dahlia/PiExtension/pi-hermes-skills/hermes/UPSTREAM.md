# Upstream sources

## Hermes Agent

Source: https://github.com/NousResearch/hermes-agent/tree/fd8a6c41ace59b476193c61002ce6a86d667b18a (MIT; see LICENSE).

`prompts.json` contains, unchanged, the evaluated English string constants `_SKILL_REVIEW_PROMPT` from
`agent/background_review.py` (as `skill_review_prompt`), `CURATOR_REVIEW_PROMPT` from `agent/curator.py` (as
`curator_review_prompt`) and `SKILLS_GUIDANCE` from `agent/prompt_builder.py` (as `skills_guidance`).

| Prompt | Unicode scalar count | SHA-256 (UTF-8) |
| --- | ---: | --- |
| skill review | 9186 | 34339ea685172e604be30e369cdd6fb313b4bbcb34bd5e9bd058d9eebd282038 |
| curator | 10300 | ffd392b9ac800050ce16587974ba7f4c5f4f3ecf50ba710c4fd00bd7e10d1b62 |

`tools.json` evaluates SKILLS_LIST_SCHEMA, SKILL_VIEW_SCHEMA and SKILL_MANAGE_SCHEMA from `tools/skills_tool.py` and
`tools/skill_manager_tool.py`, unchanged. `threat_patterns.py` is an unchanged reference copy of `tools/threat_patterns.py`;
`threat-patterns.json` is its evaluated `_PATTERNS` and `INVISIBLE_CHARS`. `guard.ts` applies them with JavaScript regular
expressions (all 36 compile unchanged without the `u` flag), after NFKC and whitespace folding, and allows the RGI
subdivision flags whose tag characters would otherwise count as invisible. No Python runs.

### Skill index and usage

`skill-index.ts` follows `agent/prompt_builder.py`'s one-line `- name: description` index without categories.
Descriptions stay in full while the listing fits 1% of the context window; over that budget, the least recently used are
clipped to `SKILL_PROMPT_DESC_LIMIT` (60) and then listed by name only, which upstream does not do.

`usage.ts` keeps `tools/skill_usage.py`'s `.usage.json`: one JSON object keyed by skill name, with the record fields
`created_by`, `use_count`, `view_count`, `patch_count`, `last_used_at`, `last_viewed_at`, `last_patched_at`,
`created_at`, `state`, `pinned`, `archived_at` and `locked`. A change is read, edited and renamed into place while holding
a lock file, in place of upstream's `flock`; a damaged file raises instead of being reset, as upstream's strict read does.
A `/skill:` command, a successful `read` of a listed skill file, or `skill_view` counts as a use. The `patch_generation`
counters and the lifecycle hooks are not ported. `scheduled` is an addition: a host marks the skills its scheduled tasks
load, which upstream protects by rewriting cron references instead.

### Skill tools

`tools.ts` implements the three tools over Pi's account skills directory (`skills/` in the agent directory). Skills that
Pi lists from elsewhere are read-only, like upstream's bundled and hub skills. `skill_manage` validates every operation
before replacing any package, rechecks for external edits just before the swap, keeps unchanged files and their
permissions, and restores already replaced packages if a later one fails. `create` records `created_by` as `agent` in a
background pass and `learn` otherwise. `linked_files` lists every regular file under
references/templates/assets/scripts rather than upstream's extension filters. Frontmatter parsing accepts scalar and
block descriptions inside the YAML fence; it is not general YAML.

In a background pass (`PI_HERMES_SKILLS_ROLE`, or a host's `role`) the guards of `tools/skill_manager_guards.py` apply: a
file is changed only after `skill_view` read it in this process, deletion needs an existing `absorbed_into` umbrella and
an agent-created skill, and becomes an archive. The Curator changes only unprotected agent-created skills, and its own
`skill_view` calls do not count as use.

### Background reviews

`index.ts` counts responses that called tools, resets on a successful `skill_manage`, and after
`review.interval` (upstream `skills.creation_nudge_interval`, 10) starts a review when the run ends. Like upstream's
forked review agent, the review is a separate Pi process with the session's history (`--fork`, into a scratch directory
removed when it exits), the session's model or `review.model`, only the skill tools, and `skill_review_prompt` with
upstream's "You can only call … management tools" suffix. It stops after 16 responses, when its input reaches 75% of the
context window (at most 600000 tokens, 120000 when unknown), or after 10 minutes. Memory reviews are not part of this
package.

### Curator

`curator.ts` ports `agent/curator.py`'s `apply_automatic_transitions` (stale after `stale_after_days`, archive after
`archive_after_days`, never-used grace, pinned/locked skipped), first-run seeding of a record without `created_at`,
`_render_candidate_list` and `restore_skill`. Archiving moves the package to `skills/.archive/<name>` (a timestamp suffix
on collision); nothing is deleted. Pi has no resident process, so upstream's `maybe_run_curator` (`interval_hours`,
`min_idle_hours`, the first-run seeding of `.curator_state`) is left to whoever schedules `/hermes-curator`, which runs
one pass and adds upstream's `restore`, `pin` and `unpin`. With `consolidate`, the candidate list and `curator_review_prompt` go to a separate Pi process with the skill
tools, a 100-response ceiling and a 30-minute timeout instead of `max_iterations=9999`. `prune_builtins`, backups and
rollback, reports on disk, `adopt` and cron reference rewriting are not ported.

## `/learn` (Hermes Agent)

Source: `agent/learn_prompt.py` at https://github.com/NousResearch/hermes-agent/tree/3371c03df62106a4c93a545787a471e328883d08.
`prompts/learn.md` is `build_learn_prompt` evaluated with the request replaced by Pi's `${@:-<upstream default>}`; its
description is the `learn` CommandDef's. Adapters: the tool names (`read`/`ls`/`bash`, a connected MCP tool for URLs,
the tool framing list, `bash` for scripts), `skill_manage` patch with `content` for a full rewrite (no `edit` action),
no skill categories, and the host's name (`{{agent}}`, default `Pi`) as the author. `learn.ts` inserts the request
verbatim, as upstream does, because Pi's argument substitution rejoins words with spaces. `/journey` is not ported.

## Skill optimization (hermes-agent-self-evolution)

Source: https://github.com/NousResearch/hermes-agent-self-evolution/tree/0a929e3aa20e15cf04dc7c28492a7d41a5139125
(MIT, © 2026 Nous Research, as stated in its README and pyproject; the repository has no LICENSE file) and
https://github.com/gepa-ai/gepa/tree/ce5b0d6e3d6af6c6dbec6de2c54536bbb961d309 (MIT; see GEPA-LICENSE).

`evolution.json` holds, unchanged, the docstrings and field descriptions of the DSPy signatures `SkillModule.TaskWithSkill`
(`evolution/skills/skill_module.py`), `LLMJudge.JudgeSignature` (`evolution/core/fitness.py`),
`SyntheticDatasetBuilder.GenerateTestCases` (`evolution/core/dataset_builder.py`) and `RelevanceFilter.ScoreRelevance`
(`evolution/core/external_importers.py`), their non-string field types, and GEPA's
`InstructionProposalSignature.default_prompt_template` (`src/gepa/strategies/instruction_proposal.py`).
`optimizer.ts` ports `evolve_skill.evolve`, the config defaults, `SECRET_PATTERNS`, `_is_relevant_to_skill`,
`_validate_eval_example`, `_parse_scoring_json`, `_parse_score`, `FitnessScore.composite` with its length penalty, the
size/growth/non-empty constraints, and GEPA's Pareto candidate selection, reflective dataset, proposal parsing, minibatch of 3,
perfect-score skip and strict-improvement acceptance.

Adapters: the run is the chat tool `skill_optimize` instead of a CLI, so it uses the chat's model for both upstream
models, reports progress as tool updates, and stops with the turn; its optional `focus` (the user's requirements) is
appended to each GEPA reflection prompt. Signatures are rendered in DSPy ChatAdapter's `[[ ## field ## ]]` layout, with `ChainOfThought`'s leading
`reasoning`, and sent through Pi's model registry. Upstream's `dspy.GEPA` optimizes the predictor's instructions and then
reads `SkillModule.skill_text`, which it never changes; this port makes the skill body itself GEPA's single component, which is
what upstream describes. Its metric is `LLMJudge` (upstream's metric is a keyword-overlap stand-in that gives GEPA no
feedback). Proposals that break a constraint are dropped before evaluation instead of only at the end. The dataset mixes the
two upstream sources: mined conversations (Pi sessions of the working directory, or the host's, in place of Claude Code,
Copilot and Hermes session files), topped up with synthetic cases below 10 examples. When the holdout split is empty the
validation split is scored. The MIPROv2 fallback, pytest/TBLite gates, golden datasets, saved datasets and output files,
and PR creation are not ported. Upstream never commits an evolved skill without review: the result is confirmed by the
user, saved next to the skill as a proposal, or handed to the host.
