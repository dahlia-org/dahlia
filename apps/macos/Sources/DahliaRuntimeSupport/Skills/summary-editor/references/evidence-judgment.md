# Weighing the user, the transcript, and screenshots

A summary is generated from the transcript, so its errors usually come from the transcript. Treat the confirmed
transcript as strong evidence of what was discussed and weak evidence of exact spelling and figures.

## How reliable each source is

| Source | Reliable for | Often wrong about |
| --- | --- | --- |
| The user's explicit correction | Names, spelling, roles, internal terms, what was meant or agreed, anything the user knows firsthand | Exact wording of what someone else said, when the user recalls from memory |
| Screenshot text (`detected_text`, the image) | Spelling of names and products, numbers, dates, and terms shown on slides or screens | Whether the shown content was agreed or only presented; captions are interpretations |
| Confirmed transcript | That a topic came up, the order of discussion, the gist of positions | Proper nouns, acronyms, homophones, numbers, negations, and who spoke |
| Existing summary | The structure the user has already seen | Anything inherited from transcript errors |

Speakers: `mic` is the user's side and `system` is the remote side. System audio can hold several people, so never
attribute a `system` statement to one named participant from the transcript alone.

## When the user's correction conflicts with the transcript

Follow the user without asking when the correction concerns:

- How a name, product, company, or term is written, or what an acronym means. Recognition mangles these routinely.
- A number, date, or negation that the transcript could have misheard, unless a screenshot shows otherwise.
- Who someone is, their role, or which organization they belong to.
- What the user meant, decided, or committed to.
- Wording, tone, emphasis, or what to leave out.

Ask once before writing when the correction:

- Contradicts a screenshot that clearly shows the opposite (a different figure on a slide, a different spelling on a
  title card).
- Contradicts the transcript in several independent places, not one garbled phrase.
- Changes a decision, an owner, a deadline, or a commitment by another participant, rather than how it is worded.
- Adds a fact that no source supports.

When you ask, quote the conflicting evidence with its timestamp or screenshot and propose both versions. If the user
confirms, apply their version: the user is the authority on the record of their own Meeting. Never resolve the
question by default, by timeout, or by your own preference.

## When you find an error yourself (pattern B)

- Change the summary on your own evidence only when a screenshot shows it directly, or the transcript states it clearly
  and consistently across several segments.
- A single odd word or name in the transcript is more likely a recognition error than a fact; prefer the spelling that
  appears on screen, in the Project description, or elsewhere in the Workspace; `query_meetings` with `attendee`
  confirms whether a name is on the Meeting's calendar invite.
- When the evidence is unclear, keep the existing text and list the doubt in your report instead of guessing.
- Never let a transcript reading override something the user corrected earlier in the conversation.
