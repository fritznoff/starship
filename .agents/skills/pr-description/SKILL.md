---
name: pr-description
description: Load whenever writing or editing a pull request (PR) or merge request (MR) title or description.
user-invocable: false
metadata:
  internal: true
---

# Write for the reviewer

Give a human the outcome, reason, and review decision before implementation detail.
Write for a reviewer who knows the repository but not this task's history: say why in problem terms, not only the mechanism, and explain project-internal terms once.
Use this order, not a mandatory set of headings:

1. **Title:** Say specifically what changes, using an imperative verb.
   Use `type(scope): change` when the project uses Conventional Commits for PR titles; do not change commit-message rules.
2. **Opening:** Write one or two standalone sentences explaining the outcome and why it matters.
   Do not repeat the title.
3. **Reviewer needs:** Separate what the reviewer must decide or know before merging from what an operator must do after merging.
   Name each group by its content, not "Review" or "Notes".
   Keep warnings and required approvals visible, never buried in collapsed evidence.
4. **Changes:** If needed, group a few bullets by behavior or area, not by file.
   Explain what the diff cannot explain; do not narrate the diff.
5. **Proof:** State what passed, what failed, and what was not run (and why); never phrase a skipped check as an exception to "pass".
   Put commands, logs, measurements, and supporting evidence in `<details>`; keep the result and important limits visible.
   Use one level of `<details>`; do not wrap existing collapsed sections in another.
   Drop everything else.

## Before publishing

- Read the current description, complete diff, and available test evidence.
  Check the diff for omitted reviewer consequences, such as new manual steps, scope boundaries and permission changes; add only what the diff shows.
  Preserve every risk, warning, test result, qualification, and scope boundary when rewriting.
  Never invent tests, benefits, certainty, or claims of completeness.
  Flag contradictions instead of silently resolving them.
- When shortening, keep each claim's evidence source and hedge ("DNS shows", "should", "expected differences").
  Never turn an observation into a conclusion or a check with expected differences into "pass".
- Explain a necessary unfamiliar term once, or replace it with plain language.
  Delete empty praise, process narration, generic checklists, repeated summaries, and headings with no useful content.
  Ask of every sentence: would the reviewer act or judge differently without it?
- Follow required repository templates and preserve machine-generated attestations and appendices verbatim.
  Never move or edit a required marker just to improve the layout.
- When editing an existing request, save the original and compare it again immediately before updating.
  Stop if another writer changed it; do not overwrite their work.
- Read back the published title and description to confirm the text and evidence survived.

## Example

`fix: keep uploads resumable after a connection drops`

An interrupted upload can now continue from its last saved chunk instead of starting over, avoiding duplicate work on slow connections.

- Existing upload links remain valid; expired links still require a new upload.
- Server restart recovery is not included.

Resume and expired-link tests pass; production storage service tests were not run (no service access).

<details>
<summary>Test evidence</summary>

`pytest tests/test_upload_resume.py`: 6 passed.

</details>
