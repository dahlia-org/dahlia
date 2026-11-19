# Hermes Agent port

Source: https://github.com/NousResearch/hermes-agent/tree/fd8a6c41ace59b476193c61002ce6a86d667b18a
License: MIT; see LICENSE. Copyright and attribution are retained verbatim.

`prompts.json` contains the evaluated English string constants from
`agent/background_review.py` (`_MEMORY_REVIEW_PROMPT`, `_SKILL_REVIEW_PROMPT`,
`_COMBINED_REVIEW_PROMPT`, and their three shared blocks),
`agent/curator.py` (`CURATOR_REVIEW_PROMPT` as `curator_review_prompt`),
`agent/prompt_builder.py` (`build_memory_guidance(True, True)`, `SKILLS_GUIDANCE`),
and `cron/scheduler_prompt.py` (`_CRON_HINT`, `_SELF_CONTEXT_INTRO`). These strings are unchanged.

| Review | Unicode scalar count | SHA-256 (UTF-8) |
| --- | ---: | --- |
| memory | 1477 | b5ceb4e4b14d61e4f27ce084b595813c32ced62cb431bc26067c6ec3096f03a2 |
| skill | 9186 | 34339ea685172e604be30e369cdd6fb313b4bbcb34bd5e9bd058d9eebd282038 |
| combined | 8687 | 3582eec1d1736d8501ba99122ad257595328a56fcff477db9d74e8d7163b9c7a |
| curator | 10300 | ffd392b9ac800050ce16587974ba7f4c5f4f3ecf50ba710c4fd00bd7e10d1b62 |

`tools.json` evaluates MEMORY_SCHEMA, SKILLS_LIST_SCHEMA, SKILL_VIEW_SCHEMA,
SKILL_MANAGE_SCHEMA and CRONJOB_SCHEMA from tools/memory_tool.py,
tools/skills_tool.py, tools/skill_manager_tool.py and tools/cronjob_tools.py.
The first four schemas/descriptions are unchanged. Dahlia calls the last tool `cronjob`
(as agreed in the plan; this upstream revision calls it `cronjob_manage`). Its properties
are limited to action, job_id, schedule, prompt, name and skills; actions are restricted
to create/list/update/pause/resume/remove/run. Its descriptions are adapted to advertise only Dahlia's accepted schedule forms and
fields: run uses the saved prompt and returns a schedule record, results appear in the
result Thread, and active runs stop from that Thread. Relative one-shot durations,
five-field cron, transient run prompts, delivery destinations, scripts, model pinning,
cancellation via the tool and other gateway-only fields are unavailable.

`threat_patterns.py` is an unchanged reference copy. `threat-patterns.json` is its evaluated
_PATTERNS and INVISIBLE_CHARS; the app uses Foundation ICU instead of Python re and applies
NFKC and invisible-character detection in Swift. No Python is executed by the app.

Dahlia adapters: Swift/GRDB rows replace the two memory files, usage/state live in
account-local tables, and background patch/remove operations become pinned approval
proposals. All account skill writes go through one actor; raw file tools cannot write
skills. Bundled/package skills require an account copy under a distinct name.
Reviews use a separate Pi process and a complete GRDB snapshot annotated with saved
run provenance; Pi RPC has no supported mixed-origin clone API. Parent prompt/tool
arguments are preserved, but runtime dispatch allows only memory/skill tools.
Scheduled runs have immutable read-only tools approved by name and deliver into a
per-schedule read-only thread. Activation follows Auto review, with user confirmation
on denial/failure and critical actions blocked; Supervised and Full access ask the user. The app supplies the clock and account /
recording gates. Five-field cron expressions are rejected without adding a dependency.

The review suffix preserves upstream's "You can only call memory and skill management
tools…" wording ("skill" when memory is unavailable). The 16-response and aggregate
input budgets are enforced both by native supervision and by Pi's `ctx.abort()` before
another provider request; hook exceptions alone do not stop Pi.
Skill discovery uses Dahlia's enabled account/bundled/package catalog, with no Hermes
category/plugin activation, dependency installation, environment capture or preprocessing.
`linked_files` groups files under references/templates/assets/scripts; the adapter lists
all regular supporting files rather than Hermes's extension filters. Supporting file
reads do not pre-read the entire package. Managed frontmatter accepts scalar and block
descriptions and validates fields inside the YAML fence; it does not implement general YAML.
Memory matching keeps upstream's whole-entry priority and typography-folded fallback;
patches still require a unique exact span, including overlapping occurrences.
Scheduled output classification is recorded before bounding the saved context excerpt
to 8000 characters, so a trailing silence marker is preserved without retaining another
unbounded copy of the response.

Curator (`agent/curator.py`, `tools/skill_usage.py`, the delete guards in
`tools/skill_manager_guards.py`): `.usage.json` and `.curator_state` become columns on
`agent_skill_states` and rows of `agent_system_runs`. The transition rules, first-run
seeding, never-used grace, `absorbed_into` requirement, pin semantics, archive layout
(`skills/.archive/<name>`, timestamp suffix on collision) and candidate-list format are
upstream's. Adapters: `bundled` is Dahlia's preset skills, `hub` becomes `package` (Pi
packages) and provenance `agent` becomes `account`; the candidate list keeps upstream's
`provenance=agent` text. Records from before the migration become `createdBy='user'` and are
not curated; `user` also stands for upstream's unset `created_by`. Settings → Skills adopts an account skill
(upstream `adopt`, `createdBy='agent'`) or takes it back (`user`, clearing its pin). `prune_builtins`, whole-tree backups/rollback, reports on disk and cron
reference rewriting are not ported, so schedule-referenced skills are never archived by any
background path. The consolidation pass's own `skill_view` calls do not bump usage. Its
fork has a 100-response ceiling and a 30-minute timeout instead of `max_iterations=9999`.

## Skill optimization (hermes-agent-self-evolution)

Source: https://github.com/NousResearch/hermes-agent-self-evolution/tree/0a929e3aa20e15cf04dc7c28492a7d41a5139125
(MIT, © 2026 Nous Research, as stated in its README and pyproject; the repository has no LICENSE file) and
https://github.com/gepa-ai/gepa/tree/ce5b0d6e3d6af6c6dbec6de2c54536bbb961d309 (MIT; see GEPA-LICENSE).

`evolution.json` holds, unchanged, the docstrings and field descriptions of the DSPy signatures `SkillModule.TaskWithSkill`
(`evolution/skills/skill_module.py`), `LLMJudge.JudgeSignature` (`evolution/core/fitness.py`),
`SyntheticDatasetBuilder.GenerateTestCases` (`evolution/core/dataset_builder.py`) and `RelevanceFilter.ScoreRelevance`
(`evolution/core/external_importers.py`), their non-string field types, and GEPA's
`InstructionProposalSignature.default_prompt_template` (`src/gepa/strategies/instruction_proposal.py`).
`skill-evolution.ts` ports `evolve_skill.evolve`, the config defaults, `SECRET_PATTERNS`, `_is_relevant_to_skill`,
`_validate_eval_example`, `_parse_scoring_json`, `_parse_score`, `FitnessScore.composite` with its length penalty, the
size/growth/non-empty constraints, and GEPA's Pareto candidate selection, reflective dataset, proposal parsing, minibatch of 3,
perfect-score skip and strict-improvement acceptance.

Adapters: the run is the chat tool `skill_optimize` instead of a CLI, so it uses the chat's model for both upstream
models, reports progress as tool updates, and stops with the turn; its optional `focus` (the user's requirements) is
appended to each GEPA reflection prompt. Signatures are rendered in DSPy ChatAdapter's `[[ ## field ## ]]` layout, with `ChainOfThought`'s leading
`reasoning`, and sent through Pi's model registry. Upstream's `dspy.GEPA` optimizes the predictor's instructions and then
reads `SkillModule.skill_text`, which it never changes; Dahlia makes the skill body itself GEPA's single component, which is
what upstream describes. Its metric is `LLMJudge` (upstream's metric is a keyword-overlap stand-in that gives GEPA no
feedback). Proposals that break a constraint are dropped before evaluation instead of only at the end. The dataset mixes the
two upstream sources: mined Dahlia conversations (in place of Claude Code, Copilot and Hermes session files), topped up with
synthetic cases below 10 examples. When the holdout split is empty the validation split is scored. The MIPROv2 fallback,
pytest/TBLite gates, golden datasets, saved datasets and output files, and PR creation are not ported; the result becomes
a pending skill change that the user approves.

## `/learn`

Source: `agent/learn_prompt.py` at https://github.com/NousResearch/hermes-agent/tree/3371c03df62106a4c93a545787a471e328883d08.
`prompts/learn.md` is `build_learn_prompt` evaluated with the request replaced by Pi's `${@:-<upstream default>}`; its
description is the `learn` CommandDef's. Adapters: the tool names (`read`/`ls`/`bash`, a connected MCP tool for URLs,
the Dahlia-tool framing list, `bash` for scripts), `skill_manage` patch with `content` for a full rewrite (Dahlia has no
`edit` action), no skill categories, and `Dahlia` as the author. `learn.ts` inserts the request verbatim, as upstream
does, because Pi's argument substitution rejoins words with spaces. `/journey` is not ported.

Background-review model adaptation: Dahlia stores independent account-local model and reasoning settings for memory and
skill reviews instead of inheriting the conversation or sharing Hermes's auxiliary slot. It selects and saves an available
own-provider model initially (Haiku, then Luna, then another available model), with medium reasoning. Existing explicit
shared settings seed both; previously queued combined reviews are split without discarding their conversation snapshot.
