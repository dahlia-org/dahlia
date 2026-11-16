# Hermes Agent port

Source: https://github.com/NousResearch/hermes-agent/tree/fd8a6c41ace59b476193c61002ce6a86d667b18a
License: MIT; see LICENSE. Copyright and attribution are retained verbatim.

`prompts.json` contains the evaluated English string constants from
`agent/background_review.py` (`_MEMORY_REVIEW_PROMPT`, `_SKILL_REVIEW_PROMPT`,
`_COMBINED_REVIEW_PROMPT`, and their three shared blocks),
`agent/prompt_builder.py` (`build_memory_guidance(True, True)`, `SKILLS_GUIDANCE`),
and `cron/scheduler_prompt.py` (`_CRON_HINT`, `_SELF_CONTEXT_INTRO`). These strings are unchanged.

| Review | Unicode scalar count | SHA-256 (UTF-8) |
| --- | ---: | --- |
| memory | 1477 | b5ceb4e4b14d61e4f27ce084b595813c32ced62cb431bc26067c6ec3096f03a2 |
| skill | 9186 | 34339ea685172e604be30e369cdd6fb313b4bbcb34bd5e9bd058d9eebd282038 |
| combined | 8687 | 3582eec1d1736d8501ba99122ad257595328a56fcff477db9d74e8d7163b9c7a |

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
