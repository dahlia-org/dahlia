# Hermes Agent port

Source: https://github.com/NousResearch/hermes-agent/tree/fd8a6c41ace59b476193c61002ce6a86d667b18a
License: MIT; see LICENSE. Copyright and attribution are retained verbatim.

Skill features come from the `pi-hermes-skills` package (`PiExtension/pi-hermes-skills`). Its `hermes/` holds the skill
review, Curator and skills guidance prompts, the skill tool schemas and the threat patterns, with their provenance in
its `UPSTREAM.md`. This directory keeps the memory and schedule parts.

`prompts.json` contains the evaluated English string constants from
`agent/background_review.py` (`_MEMORY_REVIEW_PROMPT`, `_COMBINED_REVIEW_PROMPT`, and their three shared blocks),
`agent/prompt_builder.py` (`build_memory_guidance(True, True)`),
and `cron/scheduler_prompt.py` (`_CRON_HINT`, `_SELF_CONTEXT_INTRO`). These strings are unchanged.

| Review | Unicode scalar count | SHA-256 (UTF-8) |
| --- | ---: | --- |
| memory | 1477 | b5ceb4e4b14d61e4f27ce084b595813c32ced62cb431bc26067c6ec3096f03a2 |
| combined | 8687 | 3582eec1d1736d8501ba99122ad257595328a56fcff477db9d74e8d7163b9c7a |

`tools.json` evaluates MEMORY_SCHEMA and CRONJOB_SCHEMA from tools/memory_tool.py and tools/cronjob_tools.py.
The memory schema and description are unchanged. Dahlia calls the cron tool `cronjob`
(as agreed in the plan; this upstream revision calls it `cronjob_manage`). Its properties
are limited to action, job_id, schedule, prompt, name and skills; actions are restricted
to create/list/update/pause/resume/remove/run. Its descriptions are adapted to advertise only Dahlia's accepted schedule forms and
fields: run uses the saved prompt and returns a schedule record, results appear in the
result Thread, and active runs stop from that Thread. Relative one-shot durations,
five-field cron, transient run prompts, delivery destinations, scripts, model pinning,
cancellation via the tool and other gateway-only fields are unavailable.

The app checks memory and skill content against the package's `threat-patterns.json` with Foundation ICU instead of
Python re, and applies NFKC and invisible-character detection in Swift. No Python is executed by the app.

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
input budgets are enforced both by native supervision and by the package's role budget, which calls Pi's `ctx.abort()`
before another provider request; hook exceptions alone do not stop Pi.
Dahlia hands the package its own implementations: the skill tools run in `AgentSkillService` through the bridge, usage
and Curator state live in `agent_skill_states`, the index order is computed at launch, and Dahlia schedules reviews and
consolidation itself. Skill discovery uses Dahlia's enabled account/bundled/package catalog, with no Hermes
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
`agent_skill_states` and rows of `agent_system_runs`. The package's `/hermes-curator` applies the transition rules,
first-run record seeding and never-used grace, and renders the candidate list, in a Pi process Dahlia starts for each
run; each change goes through the `skillStore` bridge, where `AgentSkillService` checks the Curator's permissions again.
The `absorbed_into` requirement, pin semantics and archive layout (`skills/.archive/<name>`, timestamp suffix on
collision) are upstream's. Adapters: `bundled` is Dahlia's preset skills, `hub` becomes `package` (Pi
packages) and provenance `agent` becomes `account`; the candidate list keeps upstream's
`provenance=agent` text. Records from before the migration become `createdBy='user'` and are
not curated; `user` also stands for upstream's unset `created_by`. Settings → Skills adopts an account skill
(upstream `adopt`, `createdBy='agent'`) or takes it back (`user`, clearing its pin). `prune_builtins`, whole-tree backups/rollback, reports on disk and cron
reference rewriting are not ported, so schedule-referenced skills are never archived by any
background path. The consolidation pass's own `skill_view` calls do not bump usage. Its
fork has a 100-response ceiling and a 30-minute timeout instead of `max_iterations=9999`.

## Skill optimization and `/learn` in Dahlia

The package ports both (see its `UPSTREAM.md`). Dahlia's adapters: `skill_optimize` optimizes unlocked account skills
only, mines this account's other conversations (user requests and the replies after them, excluding scheduled threads,
with the context Dahlia attaches to a message removed), and stages a better-scoring result as a pending skill change that
the user approves in Settings → Skills. `/learn` names `Dahlia` as the author and lists Dahlia's tools, including
`cronjob` and `memory`; the skill is saved with Dahlia's `skill_manage`.

Background-review model adaptation: Dahlia stores independent account-local model and reasoning settings for memory and
skill reviews instead of inheriting the conversation or sharing Hermes's auxiliary slot. It selects and saves an available
own-provider model initially (Haiku, then Luna, then another available model), with medium reasoning. Existing explicit
shared settings seed both; previously queued combined reviews are split without discarding their conversation snapshot.
